# 00 — Architecture Overview: Zero-Trust Vault Enterprise Integration

> Audience: Automation team (AUT), Vault team, security reviewers.
> Scope: how CloudBees CI, CloudBees CD/RO (CDRO), and Ansible Automation Platform (AAP)
> authenticate to and consume secrets from HashiCorp Vault Enterprise under a zero-trust model.

---

## 1. Goal & principles

Every platform obtains secrets from Vault using **short-lived, workload-bound identity** with
**no static shared secret** stored in the platform. Concretely:

| Principle | How we honor it |
|---|---|
| No static credentials in the client | No AppRole `secret_id`, no long-lived Vault token stored in CI/CDRO/AAP |
| Identity is the workload | CI = per-build OIDC JWT; AAP = hardened per-host AppRole; CDRO = own ZeroTrust-plugin JWT (static-pubkey; CI broker only as fallback) |
| Least privilege | One Vault role + templated policy per platform/app; bound to issuer claims / cert names |
| Short TTLs | Tokens 15–30 min, SSH certs ≤ 2 h, response-wraps 60–90 s (confirm against SLA) |
| Auditable | Every login + secret read recorded to a Vault audit device streamed to SIEM |
| Data-plane secrets are also dynamic | SSH access uses Vault-signed short-lived certs, not static keys |

**Explicitly rejected:** static long-lived tokens as an auth method. AppRole is used for AAP **only in
hardened form** (single-use response-wrapped `secret_id`, short TTL, CIDR-bound to AAP hosts) as the
pragmatic zero-trust-aligned method for AAP 2.4 — see the decision record in §8. SPIRE is **not** being
deployed at this time (revisit if CDRO needs its own identity or AAP stays pre-2.7 long-term).

---

## 2. Per-platform trust roots

| Platform | Deployment | Trust root | Vault auth method | Why |
|---|---|---|---|---|
| **CloudBees CI** | Traditional, VMs, CJOC + 2–10 controllers | Native **OIDC per-build JWT** (OIDC Provider plugin) | `auth/jwt-ci` | Org already runs this pattern successfully; controllers are their own OIDC issuers |
| **CDRO** | Airgapped VMs | **Own locally-signed JWT** (ZeroTrust plugin `v1.0`, `iss=ZeroTrust`) | `auth/jwt-cdro` (JWT, **static-pubkey** validation) | The ZeroTrust plugin mints a signed JWT inside a procedure step; Vault validates it against a static public key (no JWKS/discovery). CI broker retained only as a fallback |
| **AAP** | VMs, controller 4.5.25 = **AAP 2.4** | **hardened AppRole** (native Vault credential plugin) | `auth/approle` | AAP 2.4 has no native OIDC (that is 2.7 Tech Preview); AppRole is supported by the native plugin and avoids the AD CS enrollment-automation blocker. mTLS cert auth remains a documented alternative |

All three converge on Vault namespace **`AUT`**, owned by the Automation team.

---

## 3. End-to-end topology

```
                         Firewall zones (central Vault, systems in separate zones)
   ┌───────────────────────────────────────────────────────────────────────────────┐
   │  Vault Enterprise cluster (VMs, Raft, 1.20.8+ent)   namespace: AUT                │
   │   auth/jwt-ci   auth/approle                                                      │
   │   secret/ (KV v2)   ssh/ (SSH CA)   [pki/ optional]                               │
   │   audit device ── syslog ──► SIEM                                                 │
   └───▲──────────────▲───────────────▲──────────────────────────────▲────────────────┘
       │ JWKS pull     │ AppRole login  │ token+read                   │ token+read
       │ (Vault→CI)    │ (role+secret)  │                              │
   ┌───┴────┐     ┌────┴─────┐     ┌ ─ ─ ─ ─ ─┐                   ┌────┴─────┐
   │ CI      │     │ AAP 2.4   │      CI build  ◄── trigger ──────│ CDRO      │
   │ ctrls   │     │ (VMs)     │      (broker,   (fallback only)  │ (airgap)  │
   │ (OIDC   │     │ AppRole   │       FALLBACK) ─ wrap/lease ─ ─►│ ZeroTrust │
   │  issuer)│     │ + SSH/KV  │     └ ─ ─ ─ ─ ─┘                  │ JWT→Vault │
   └────┬────┘     └────┬──────┘                                  └────┬──────┘
        │                │        CDRO logs in directly:               │ jwt-cdro login
        │                │        auth/jwt-cdro (static pubkey) ◄───────┘ + KV read
        │ signed SSH     │ signed SSH cert (svc-aap)
        │ cert (svc-ci)  ▼
        ▼           ┌─────────────────────────────┐
   ┌─────────────┐  │ Managed nodes                │
   │ deploy tgts │  │ sshd: TrustedUserCAKeys =    │
   │ trust SSH CA│  │ Vault SSH CA (set by AAP     │
   └─────────────┘  │ playbook, ongoing)           │
                    └─────────────────────────────┘
```

**Control plane** (how a platform proves who it is): OIDC JWT (CI), hardened AppRole (AAP),
**own locally-signed ZeroTrust JWT (CDRO)** — validated by a static public key, no JWKS/discovery;
the CI broker remains only as a CDRO fallback.
**Data plane** (how automation logs into managed hosts): Vault SSH secrets engine signs short-lived
certificates; nodes trust the Vault SSH CA via `TrustedUserCAKeys`.

---

## 4. Firewall matrix

Central Vault with systems in separate zones ⇒ every flow below must be explicitly opened.
`<vault-vip>` = Vault cluster VIP/API (8200). `<ci-ctrl-N>` = each CI controller URL (443).

| # | Source | Destination | Port | Purpose | Direction note |
|---|---|---|---|---|---|
| 1 | Vault nodes | each `<ci-ctrl-N>` `/oidc/**` | 443 | Vault pulls CI controller **JWKS/discovery** to validate JWTs | **Vault → CI** (often missed) |
| 2 | CI controllers/agents | `<vault-vip>` | 8200 | JWT login + KV read + SSH sign | CI → Vault |
| 3 | CDRO server/agents | `<vault-vip>` | 8200 | **ZeroTrust JWT login + KV read** (primary) | CDRO → Vault |
| 3b | CI broker build *(fallback)* | `<vault-vip>` | 8200 | Broker login + read + response-wrap | CI → Vault |
| 4 | CDRO server/agents *(fallback)* | `<ci-ctrl>` REST API | 443 | Trigger broker job | CDRO → CI |
| 5 | CI (job result) *(fallback)* | CDRO | 443/8443 | Return wrapping token / lease (callback or polled) | CI → CDRO |
| 6 | CDRO server/agents *(fallback)* | `<vault-vip>` | 8200 | **Unwrap** wrapping token / renew lease only | CDRO → Vault (narrow) |
| 7 | AAP controllers/EEs | `<vault-vip>` | 8200 | AppRole login + SSH sign + KV lookup | AAP → Vault |
| 8 | AAP EEs / CI agents | managed nodes | 22 | SSH using signed certs | data plane |
| 9 | Vault nodes | SIEM/syslog collector | 514/6514 | Audit stream | Vault → SIEM |
| 10 | AAP (node-trust playbook) | `<vault-vip>` `/v1/AUT/ssh/public_key` | 8200 | Fetch SSH CA public key for nodes | AAP → Vault |

> Flow #1 is the classic failure: JWT auth silently fails if Vault cannot reach each controller's
> `/.well-known/openid-configuration` + JWKS. Validate it first (see `05-operations-appendix.md`).
>
> **No Vault→CDRO discovery flow exists.** The ZeroTrust plugin has no JWKS/OIDC-discovery endpoint;
> Vault validates CDRO's JWTs offline against a **static** `jwt_validation_pubkeys`. Flow #3 (direct
> CDRO→Vault login) is the primary path; flows #3b–#6 are needed only if you run the CI-broker fallback.

---

## 5. TTL / rotation defaults

> **Placeholder — confirm against the mandated rotation SLA (numbers pending).** Values below are the
> zero-trust defaults the guides ship with; override once the SLA numbers are provided.

| Artifact | Default TTL | Max TTL | Notes |
|---|---|---|---|
| CI JWT (OIDC id token) | = job duration | job timeout | Issued per build by the OIDC Provider plugin |
| Vault token (all methods) | 15 min | 30 min | `token_ttl` / `token_max_ttl` on the role |
| SSH signed certificate | 1 h | 2 h | `ttl` / `max_ttl` on the SSH role |
| CDRO ZeroTrust JWT | 900 s | 900 s | Plugin `Token lifetime` (operator-set; keep short) |
| CDRO Vault token (ZeroTrust) | 15 min | 15 min | `cdro-zerotrust` role `token_ttl` (≤ JWT lifetime) |
| Response-wrapping token (CDRO broker fallback) | 90 s | 90 s | Single-use; unwrapped immediately by CDRO |
| Dynamic DB/cloud lease | 30 min | 1 h | Where dynamic engines are used |
| AAP AppRole `secret_id` | 10 min | 10 min | Single-use (`secret_id_num_uses=1`), response-wrapped, CIDR-bound to AAP hosts |

---

## 6. Namespace & mount layout (`AUT`)

```
AUT/                              # single namespace, Automation team owns it
├── sys/audit/                    # syslog device → SIEM
├── auth/
│   ├── jwt-ci/                   # one mount; each CI controller registered as an issuer/role
│   ├── jwt-cdro/                 # CDRO ZeroTrust JWT (static pubkey, bound_issuer=ZeroTrust)
│   └── approle/                  # hardened AAP role (single-use secret_id, CIDR-bound)
├── secret/                       # KV v2
│   ├── ci/<app>/…
│   ├── cdr/<release>/…           # CDRO reads its own release path (ZeroTrust direct JWT)
│   └── aap/<app>/…
└── ssh/                          # SSH secrets engine (CA)
    ├── roles/svc-ci              # principal svc-ci, ttl 1h
    └── roles/svc-aap             # principal svc-aap, ttl 1h
```

Separation inside the single namespace is by **auth mount + role + templated policy + secret path**,
not by additional namespaces (per the agreed operating model).

---

## 7. Operating model (who does what)

| Action | Owner | Mechanism |
|---|---|---|
| Create `AUT` namespace | **Vault team** | Their existing CI-OIDC namespace-management pipeline |
| Apply auth methods / secrets engines / policies in `AUT` | **Vault team** | Consume **YAML** submitted by AUT via **pull request** |
| Author the requested YAML | **Automation team (AUT)** | PRs to the Vault self-service repo (schema TBD — shared next) |
| Configure CI (plugin, JCasC, pipelines) | **Automation team** | JCasC + pipeline libraries |
| Configure AAP (credentials, playbooks) | **Automation team** | `ansible.controller` certified collection |
| Configure CDRO (broker trigger + unwrap) | **Automation team** | CDRO DSL/procedures + CI job |
| Deliver/rotate the AAP AppRole `secret_id` | **Automation team** | Response-wrapped `-wrap-ttl`; stored only in AAP's encrypted credential store |

---

## 8. Decision record (why these choices)

- **CI → native OIDC JWT.** The org already operates CI→OIDC→Vault (Vault team uses it for namespace
  management). Extending a proven pattern is lower risk than any alternative. Each controller is an
  OIDC issuer; Vault validates per-build JWTs against the controller JWKS.
- **AAP → hardened AppRole (not OIDC, not cert auth).** AAP 2.4 (controller 4.5.25) has no native OIDC —
  that shipped in 2.7 as Technology Preview. The native HashiCorp Vault credential plugin supports Token,
  AppRole, Kubernetes, and TLS. Kubernetes is OCP-only; Token is static. That leaves **TLS cert auth** and
  **AppRole**. We choose **AppRole**, hardened, because:
  - It avoids the **unsolved AD CS enrollment/renewal automation** that cert auth depends on (previously
    the project's open blocker) — AppRole needs no PKI issuance pipeline, which fits an airgapped, "keep
    it simple" environment.
  - The one bootstrap secret (`secret_id`) is made zero-trust-aligned: **single-use**
    (`secret_id_num_uses=1`), **short-lived** (`secret_id_ttl` ≈ 10 min), **response-wrapped** on delivery
    (`-wrap-ttl`), **CIDR-bound** to AAP hosts (`secret_id_bound_cidrs`/`token_bound_cidrs`), and stored
    only in AAP's encrypted credential store — never in git/playbooks.
  - **Accepted tradeoff vs. cert auth:** a bootstrap secret exists at all (cert auth's identity is the host
    cert). The hardening above bounds its blast radius; the residual is a short-lived, IP-locked,
    single-use value.
  **mTLS cert auth remains a documented alternative** (see `04-...`), and **native OIDC is the planned
  end-state when AAP reaches 2.7.**
- **CDRO → own ZeroTrust JWT (primary); CI broker (fallback).** The custom, CloudBees-built **ZeroTrust**
  plugin (`v1.0`) mints a signed JWT inside a CDRO procedure step (`iss=ZeroTrust`), so CDRO proves its
  **own** identity to Vault via `auth/jwt-cdro`. Vault validates it against a **static public key**
  (`jwt_validation_pubkeys` + `bound_issuer`) — **there is no JWKS/OIDC-discovery endpoint**, so no
  Vault→CDRO flow and no `oidc_discovery_url`. This **supersedes** the earlier no-issuer premise for KV
  reads: audit now attributes the read to **CDRO** (`user_claim=sub`), not a CI broker. Reads are KV v2
  read-only, release-scoped to `secret/data/cdr/<release>/*` via `claim_mappings` + a templated policy.
  Dynamic secrets are reached by **minting a JWT and handing it off** to an external consumer (AAP). The
  **CI broker is retained only as a fallback** where the plugin isn't installed/approved or as a migration
  bridge — with its documented tradeoff that audit attributes access to the CI broker identity.
  **Accepted tradeoffs of the plugin:** the private signing key lives in a CDRO Credential (forge risk →
  tight ACL, short TTL, manual rotation), key rotation is manual, and concurrent runs from different
  releases must not share one CDRO credential (clobber).
- **SPIRE deferred (now largely moot for CDRO).** The ZeroTrust plugin already gives CDRO its own JWT
  identity, so SPIRE is no longer needed for CDRO audit attribution. Revisit only for pre-2.7 AAP if
  priorities change.
- **Single namespace `AUT`.** One team owns all three platforms; per-platform isolation via mounts/roles/
  policies is sufficient and keeps namespace operations simple.
- **SSH signed certificates for the data plane.** Eliminates static SSH keys on managed nodes; certs are
  short-lived and principal-scoped (`svc-ci`, `svc-aap`); nodes trust only the Vault SSH CA.

---

## 9. Guide index

| Guide | Contents |
|---|---|
| `01-vault-foundation-AUT.md` | `AUT` namespace, audit, KV v2, SSH CA, cert auth, jwt auth, policies (PR-ready YAML + Terraform) |
| `02-cloudbees-ci-oidc.md` | OIDC Provider plugin, issuer registration, JWT roles, JCasC, pipeline examples |
| `03-cdro-zerotrust-jwt.md` | ZeroTrust plugin (how it works), `jwt-cdro` mount/role/policy (static pubkey, release-scoped KV-v2 read-only), Pattern A in-CDRO read + Pattern B mint-and-hand-off, key rotation, limitations/risks; CI broker retained as §10 fallback |
| `04-aap-cert-auth-ssh.md` | **AAP auth is now hardened AppRole** (see `../getting-started/04-aap-approle-ssh.md`); this file retains mTLS cert auth as the documented alternative + SSH role, node-trust playbook, 2.7 note |
| `05-operations-appendix.md` | Firewall validation, TTL/SLA table, rotation & DR, troubleshooting, open follow-ups |

> **Beginner step-by-step version:** a task-oriented, copy-paste guide series lives in
> [`../getting-started/`](../getting-started/) (README + 00–05). Use it to *do* the integration; use this
> reference series to understand *why* it is built this way.

---

## 10. Open follow-ups

- **Vault self-service YAML schema** — to be shared; reshape `01` YAML to match.
- **TTL / rotation SLA numbers** — confirm; the guides ship concrete zero-trust defaults (§5) that are
  overridable once a formal SLA is provided.
- **OIDC Provider plugin** — ✅ resolved: on `111.v29fd614b_3617`, which **is** the SECURITY-3574 fix
  (CVE-2025-47884). No security upgrade required; `212.v7657c4d7b_29f` is optional maintenance.
- **AAP `secret_id` rotation** — decide the delivery/rotation mechanism (wrapped one-shot per run vs. a
  longer-lived CIDR-locked `secret_id` in AAP's store rotated on schedule).
- **CI API token** for CDRO→CI triggering — decide scope and storage (**fallback path only**).
- **AAP 2.7 upgrade** — cut AAP over to native OIDC when available (drops AppRole entirely).
- **ZeroTrust plugin — confirm `aud` + algorithm/PEM** — decode a real token to lock the role's
  `bound_audiences` (assumed `vault-AUT`) and the signing algorithm + `jwt_validation_pubkeys` PEM
  (assumed RS256). See `03-cdro-zerotrust-jwt.md` §1.
- **ZeroTrust signing-key rotation** — currently manual (§7 of guide `03`); consider automating the
  public-key push + Credential swap on the mandated SLA.
