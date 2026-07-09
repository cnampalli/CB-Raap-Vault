# Prompt — Document the CloudBees CDRO ⇄ Vault Enterprise integration (custom "ZeroTrust" JWT plugin)

> **How to use this prompt**
> Paste everything below the line into a fresh AI session **opened at the root of this repo**
> (`CloudBees-Vault/`). The AI has read/write access to the repo and network access *only* to what
> an airgapped RHEL 8.10 host would have. If you can, **attach one captured sample JWT** produced by
> the ZeroTrust plugin (a `.jwt`/`.txt` file, or paste the raw `eyJ...` token) — it makes the
> investigation phase concrete. If you cannot yet, the prompt tells the AI how to capture one.
> Do not commit any real token you attach.

---

## ROLE & FRAMING

You are operating inside the **WAT framework** (Workflows / Agents / Tools) described in this repo's
`CLAUDE.md`. Read `CLAUDE.md` first and obey it: probabilistic reasoning is your job, deterministic
execution belongs in `tools/*.py`, and SOPs live in `workflows/`. You are the Agent layer.

You are **extending an existing, mature zero-trust Vault integration suite**, not starting fresh.
The suite already documents CloudBees CI, CDRO, and AAP against HashiCorp Vault Enterprise across two
parallel doc layers. Your output must look and read like it belongs to that suite — same structure,
same tone, same conventions, same reuse of existing tools.

## OBJECTIVE

Produce (by updating and extending existing files) the documentation for **how CloudBees CDRO
authenticates to Vault Enterprise using the organisation's custom, CloudBees-built "ZeroTrust"
plugin, which mints a JWT directly inside CDRO procedure steps** — then uses that JWT to retrieve
secrets from Vault via Vault's JWT auth method.

Deliver two things the end users asked for:
1. **Step-by-step instructions** to configure the CDRO plugin/procedure and the matching Vault
   JWT-auth role, tools, and policies required on both CDRO and Vault Enterprise.
2. **Code templates tiered by the end user's technical experience level** (see §AUDIENCE & TIERING).

### Critical framing: the plugin is a known quantity

CI's JWTs come from the OpenID Connect Provider plugin. **CDRO is different but understood.** The
custom, CloudBees-built **"ZeroTrust"** plugin (v1.0) mints a JWT inside CDRO procedure steps and its
behavior has been documented by the plugin's operators — the **KNOWN FACTS** section below is
**authoritative ground truth**. Build the Vault integration directly on those facts. Your job is to
**verify the facts against a real token, then derive the Vault JWT-auth configuration from them** —
not to reverse-engineer from scratch. Where a fact is marked *open*, and only there, investigate.

## KNOWN FACTS — ZeroTrust CDRO plugin (authoritative)

> Provided by the plugin's operators. Treat as ground truth; confirm the token-level facts by
> decoding one real sample JWT with `tools/inspect_jwt_claims.py`, then build on them.

**Identity & packaging**
- Name **ZeroTrust**, version **v1.0**. A CDRO **plugin package**; source + docs in a **private
  GitHub repo**. Installed by **CDRO admins**, exposed to CDRO end users.

**How it signs & how Vault must validate (the crux)**
- The plugin **signs the JWT locally** using a key from its configuration's **Credential** field,
  with a configurable **Algorithm** and **Issuer = `ZeroTrust`**.
- Validation is via **static public keys in Vault** — the CDRO JWT-auth mount is configured with
  **`jwt_validation_pubkeys`** (asymmetric) + **`bound_issuer = "ZeroTrust"`**. **There is NO
  JWKS/OIDC-discovery endpoint.** ⇒ **Do NOT use `oidc_discovery_url`, and do NOT run
  `check_oidc_discovery.py` for CDRO** — that tool is CI-only. (`inspect_jwt_claims.py` still applies.)
- **Key distribution is manual/admin-managed:** the private signing key lives in the CDRO Credential;
  an admin pastes the matching **public key** into the Vault mount's `jwt_validation_pubkeys`;
  **rotation is a manual, coordinated step.**

**Plugin Configuration** (Plugin-Management → Configurations → New Configuration): `Name`; `Project`;
`Description`; `Plugin=ZeroTrust`; **`Endpoint`** (Vault URL; referable in claims as `<vault-url>`);
**`Role`** (Vault JWT auth role; `<role>`); **`Provider`** (JWT auth **mount path**); **`Issuer`** =
`ZeroTrust`; **`customClaims`** (JSON textarea building the JWT payload, e.g.
`{"sub":"test","job_name":"$[/myRelease/name]"}` — **this is where `aud` is set**);
**`Test Connection Claims`** (JSON); **`Token lifetime`** (default **900**s); **`Credential`** (JWT
signing key); **`Algorithm`** (HS256/384, RS256/384/512, ES256/384/512, PS256/384/512, EdDSA —
deployment uses an **asymmetric** alg for public-key validation); **`secret_mount_path`** (KV mount,
e.g. `secret`); **`Namespace`** (e.g. `aut`; referable as `<namespace>`); **`debugLevel`**
(info/debug/trace).

**Vault-side mapping derived from the above**
- Mount: JWT auth at `Provider` path, `jwt_validation_pubkeys` = plugin public key, `bound_issuer =
  ZeroTrust`, namespace `aut`.
- Role: `bound_audiences` = the operator's `aud` (set via `customClaims`); **`bound_claims` scoped on
  `job_name`/release claims** (e.g. from `$[/myRelease/name]`) so each run reaches only its own path;
  `user_claim = sub`; short token TTL aligned to the 900s lifetime. **Reuse the guide-02 Step 6.5
  `claim_mappings` + templated-policy pattern** so each run reads only `cdr/<release>/*`.
- Policy: **KV v2 read only** (no dynamic-secret or SSH capabilities on the CDRO role).
- **Secret path convention `cdr/<release>`** (e.g. `cdr/$[/myRelease/name]`) is **authoritative** —
  update existing `cdro/<app>` references in the repo to match.

**Two Vault-side usage patterns (document both, distinctly)**
- **A. In-CDRO read (plugin authenticates & reads):**
  - `UpdateCdroCredentialThroughJwtRequest` — reads a KV secret and writes it into an existing CDRO
    credential: **1 kv pair → key=username/value=password; 2 pairs {username,password} → mapped
    directly; >2 pairs → whole secret stored as JSON in the password field.**
  - `getCdroCredentialAndRunStep` — stores the secret (JSON) in the password of a credential
    **always named `zt_credential`**, then runs a shell/`ec-groovy` command that reads it via
    `getFullCredential(credentialName:"zt_credential")`.
  - `getAuthorizedTokenAndRunStep` — stores the **Vault-authorized token** in `zt_credential`, then
    runs a command.
- **B. Mint-and-hand-off (external consumer exchanges the JWT):**
  - `IssueJwtAndStoreInProperty` — mints a JWT with given `customClaims` (e.g.
    `{"sub":"aap_job","aap_runner":"ip1,ip2"}`) and stores it in a CDRO **property** (e.g.
    `/myPipelineRuntime/jwtToken`). A downstream **AnsibleTower** plugin step passes it as a job
    parameter (`{"jwt":"$[/myPipelineRuntime/jwtToken]"}`); the **AAP agent** does its own Vault
    exchange — this is how **dynamic secrets** are reached externally (the KV-only limit is on the
    in-CDRO procedures, not the overall capability).

**Limitations**
- **Concurrency clobber:** two runs from *different* releases/pipelines sharing the *same* CDRO
  credential overwrite each other (last write wins → wrong creds → auth failure). Must be avoided
  operationally. Same-source concurrent runs (same secret) are safe.
- **Coarse `sub`** (operator-set free text) — real identity enforcement must come from binding on
  `job_name`/release claims.
- **KV v2 only** for the plugin's own reads (procs in pattern A).
- **Manual key rotation** (no automation).

**Risks & mitigations to document**
- **Signing-key compromise → JWT forgery** (private key held in a CDRO Credential): least-privilege
  Credential ACLs, restrict who can edit the plugin configuration, short token lifetime, rotate keys.
- **JWT leaked via the property/AAP hand-off** (UC2): treat the property as sensitive; avoid echoing;
  scope the JWT's claims/TTL tightly.
- **`debugLevel=debug/trace` may log the JWT or secret values:** keep `info` in production.
- **Over-broad Vault role** if `bound_claims` isn't scoped on `job_name`/release.

**Non-functional notes**
- Token lifetime operator-set (default 900s, no hard cap) → keep Vault token TTL short.
- No separate HA (availability tied to the CDRO server/agent running the step).
- No known plugin-imposed rate limits (Vault's own limits still apply).
- Operational logging controlled by `debugLevel`.

**Open questions / gaps to investigate (only these)**
- The exact **`aud` string** placed in `customClaims` (operator-defined per configuration) — confirm
  it and set the role's `bound_audiences` to match.
- Confirm the **asymmetric algorithm actually used** (RS/ES/PS/EdDSA) and the exact PEM(s) for
  `jwt_validation_pubkeys`, by decoding a real token header + reading the plugin config.

## LOAD CONTEXT FIRST (read these before writing anything)

- `CLAUDE.md` — the WAT rules you must follow.
- `docs/getting-started/03-cloudbees-cdro.md` and `docs/vault-integrations/03-cdro-ci-broker.md` —
  the **current** CDRO docs. They describe a **CI-broker** pattern on the premise that CDRO has *no
  OIDC issuer*. You will reconcile these against what the ZeroTrust plugin actually does.
- `docs/getting-started/02-cloudbees-ci.md` and `docs/vault-integrations/02-cloudbees-ci-oidc.md` —
  the **working JWT → Vault flow** to mirror (JWT auth mount, role bindings `bound_issuer` /
  `bound_audiences` / `bound_claims` / `user_claim` / `claim_mappings`, three code variants).
- `docs/getting-started/00-before-you-begin.md` §2.1 — the **Requirements & Compatibility matrix**
  and the per-variant agent capability tables. You will add CDRO rows here.
- `docs/vault-integrations/00-architecture-overview.md` — trust roots, firewall matrix, TTL table,
  and the **§8 decision record** you must update when you reconcile direct-JWT vs broker.
- `tools/inspect_jwt_claims.py`, `tools/README.md` — reusable helpers (Python 3.6+, stdlib only,
  airgap-safe) and the tool-authoring conventions. **Reuse `inspect_jwt_claims.py` to confirm the
  token claims.** Note: `tools/check_oidc_discovery.py` is **CI-only and does NOT apply to CDRO**
  (the ZeroTrust plugin has no JWKS/discovery endpoint — see KNOWN FACTS).
- `docs/CHANGELOG.md` — the durable session-continuity trail. You will append an entry.

## PHASE 1 — VERIFY THE KNOWN FACTS & DERIVE THE VAULT CONFIG (do this before designing anything)

The plugin's behavior is given in **KNOWN FACTS**. Do not re-derive it — **verify it against a real
token, then turn it into concrete Vault configuration.** Concretely:

1. **Confirm the token claims.** Capture one sample JWT the plugin emits (from a test-procedure run's
   output — never a production secret) and decode it with
   `python3 tools/inspect_jwt_claims.py <token-or-file>`. Confirm `iss = ZeroTrust`, the signing
   **alg** (asymmetric), `sub`, `exp`/`iat`, and the **`aud`** and **`job_name`/release** claims that
   KNOWN FACTS says are set via `customClaims`. Reconcile any difference from KNOWN FACTS as a
   correction, and resolve the two listed open questions (exact `aud`; exact alg + public key PEM).
2. **Derive the Vault mount & role from the confirmed facts** — do **not** run
   `check_oidc_discovery.py` (no discovery endpoint): configure the JWT auth mount with
   `jwt_validation_pubkeys` (the plugin's public key PEM), `bound_issuer = ZeroTrust`, namespace
   `aut`; build the role with `bound_audiences` = the confirmed `aud`, `bound_claims` scoped on
   `job_name`/release, `user_claim = sub`, short TTL; write a **KV v2 read-only** least-privilege
   policy for `cdr/<release>/*` using the guide-02 Step 6.5 `claim_mappings` + templated-policy
   pattern.
3. **Cover both usage patterns** (A in-CDRO read/credential-update/run-step; B mint-and-hand-off to
   AAP) from KNOWN FACTS — each is a distinct documented flow.
4. **Write it down.** Produce an explicit **"How the ZeroTrust plugin works / how to use it"**
   section grounded in KNOWN FACTS + your token verification. It is a **primary deliverable**. Flag
   any residual unverifiable point as an open question rather than asserting it.

## PHASE 2 — RECONCILE WITH THE EXISTING BROKER DOCS

The current CDRO docs assume no OIDC issuer → CI broker. **KNOWN FACTS supersede that premise for KV
reads:** the ZeroTrust plugin mints usable JWTs directly, so CDRO authenticates to Vault on its own.
**Surface and resolve the conflict** — do not silently contradict existing pages:

- **Lead with the ZeroTrust direct-JWT flow.** Keep the **CI-broker pattern only as a documented
  fallback** (e.g. where the plugin can't be used, or as a migration bridge).
- **Reconcile the secret-path convention:** `cdr/<release>` is authoritative — update existing
  `cdro/<app>` references throughout the repo to match.
- Update the **§8 decision record** in `00-architecture-overview.md`, the CDRO rows in the identity
  table and firewall matrix (note: **no Vault→CDRO discovery flow** exists — validation is by static
  pubkey, not JWKS), and all cross-links between the getting-started and reference layers.

## HARD CONSTRAINTS (non-negotiable)

- **Confirmed environment versions** — treat as the target; call out any command that needs a
  different version:
  Vault Enterprise **1.20.8+ent** (Raft, namespace `AUT`) · vault CLI **1.15.1** · Terraform
  **1.13.1** · Python/pip **3.6.8 / 9.0.3** · curl **7.61.1** · jq **1.6** · CloudBees CDRO
  **2024.09.0.176472 (protocol 2.3)** · awk **4.2.1** · bash/sh **4.4.20 x86_64** · RHEL **8.10**.
- **Airgapped** — no `pip install`, no external downloads, no internet. Everything runs from what
  ships on the RHEL 8.10 image. Private CA everywhere (`--cacert /etc/pki/vault/ca.crt`).
- **Tools** — any new helper goes in `tools/`, is **Python 3.6.8-compatible, stdlib-only** (no PEP
  585/604 syntax, no f-string edge cases that 3.6 rejects), verb-first snake_case, one task per
  script. Prefer reusing `inspect_jwt_claims.py` (do not use `check_oidc_discovery.py` for CDRO — no
  discovery endpoint).
- **Zero-trust rules** — short-lived tokens; least privilege; **narrow `bound_claims`** (never a
  wildcard-all role); audience must match the credential's audience exactly; secret hygiene
  (`set +x` around secrets, pass tokens via **stdin** not argv, self-revoke in cleanup); default
  TTLs as overridable placeholders.

## AUDIENCE & TIERING

The end users **mostly do not know secrets management**, and **only a few can write a script or use
Python**. Write for them:

- **Beginner-first & copy-paste.** Each step states plainly *what it does and why it matters* in one
  or two sentences before the commands. Assume no prior Vault or CDRO knowledge; add a one-line
  glossary pointer where a term first appears.
- **Tier the code by technical experience** (mirror the existing curl / no-CLI / CLI convention):
  - **Tier 1 — Novice, copy-paste (recommended airgap default):** plain `curl` against Vault's REST
    API, token via stdin. No scripting required.
  - **Tier 2 — Intermediate, no external CLI:** a native CDRO step / HTTP-request approach that needs
    no shell binaries beyond what the plugin already provides.
  - **Tier 3 — Advanced, scripted:** `vault` CLI + `jq`, or a small stdlib-only Python helper, for
    users who want automation and can maintain it.
  Label each tier clearly and tell the reader which to pick. Never require Tier 3 to complete the
  basic flow.

## REQUIRED OUTPUT ARTIFACTS (mirror the two-layer structure)

1. **Beginner layer** — update `docs/getting-started/03-cloudbees-cdro.md`: numbered `Step N —`
   sections for the ZeroTrust-plugin direct-JWT flow, covering **both usage patterns** (A: in-CDRO
   read via `UpdateCdroCredentialThroughJwtRequest` / `getCdroCredentialAndRunStep` /
   `getAuthorizedTokenAndRunStep`; B: mint-and-hand-off via `IssueJwtAndStoreInProperty` → AAP),
   plus a **manual key-rotation runbook** step (public key into Vault, private key in the CDRO
   Credential) and the **concurrency-clobber** warning. Each `Step N` ends in a **hardening
   checklist**, a **Verify** block, and a **"Next:"** link. Keep the broker steps as the documented
   fallback.
2. **Reference layer** — update `docs/vault-integrations/03-cdro-*.md` (rename/retitle if it is no
   longer broker-only): design rationale, the Phase-1 "how the plugin works" findings, the Vault
   JWT-auth mount/role/policy config using **static `jwt_validation_pubkeys` + `bound_issuer` +
   `job_name`/release-scoped `bound_claims` + KV-v2-read-only policy for `cdr/<release>/*`** (YAML +
   Terraform 1.13.1 equivalent, matching guide `01`'s style), and the reconciliation decision.
3. **Examples** — tiered CDRO example templates under `docs/vault-integrations/examples/` (one per
   tier), each with an assumptions header and airgap notes (private CA, `set +x`, stdin, self-revoke,
   core steps only — no optional-plugin dependencies).
4. **Matrix & tables** — add CDRO rows to `00-before-you-begin.md` §2.1 (requirements/compatibility)
   and to the verify/troubleshoot tables in `docs/getting-started/05-verify-and-troubleshoot.md` and
   `docs/vault-integrations/05-operations-appendix.md`.
5. **Changelog** — append a dated entry to `docs/CHANGELOG.md` summarising what you investigated,
   decided, and changed, plus any open follow-ups.

## WAT SELF-IMPROVEMENT & EDGE CASES

Per `CLAUDE.md`: when something fails, read the full error, fix the tool, verify, then **update the
relevant `workflows/` SOP** with what you learned (plugin quirks, issuer/JWKS reachability gotchas,
claim-template traps, TTL/rotation constraints). Do not create or overwrite workflows without the
user's go-ahead — but do propose the update. Record every plugin behavior you could not verify as an
explicit open question.

## DEFINITION OF DONE (self-check before you report finished)

- [ ] "How the ZeroTrust plugin works / how to use it" section written from **KNOWN FACTS + a decoded
      real token**; the two open questions (exact `aud`; exact alg + public-key PEM) resolved or
      explicitly flagged.
- [ ] Vault mount uses **static `jwt_validation_pubkeys` + `bound_issuer=ZeroTrust`** — **no**
      `oidc_discovery_url`, and `check_oidc_discovery.py` is **not** invoked for CDRO.
- [ ] Role bindings: `bound_audiences` = confirmed `aud`; **`bound_claims` scoped on
      `job_name`/release**; `user_claim=sub`; **KV-v2-read-only** policy for `cdr/<release>/*`; no
      wildcard-all role.
- [ ] **Both usage patterns** documented (A in-CDRO read/credential-update; B mint-and-hand-off to
      AAP), plus **manual key-rotation runbook** and the **concurrency-clobber** warning.
- [ ] Direct-JWT leads; **CI-broker kept as fallback**; `cdro/<app>` → **`cdr/<release>`** path
      reconciled repo-wide; decision record, identity table, firewall matrix, cross-links consistent.
- [ ] **Three code tiers** present, each airgap-safe, correctly labeled; novice tier requires no
      scripting.
- [ ] **Limitations, Risks & mitigations, Non-functional notes** subsections present (from KNOWN
      FACTS): `debugLevel` secret-leak caution, signing-key-compromise, property/JWT-handoff exposure,
      short token TTL.
- [ ] §2.1 requirements matrix + verify + troubleshoot tables updated with CDRO rows.
- [ ] `docs/CHANGELOG.md` entry appended; open follow-ups captured.
- [ ] Every new Python helper is 3.6.8 stdlib-only; all internal doc links/anchors valid.
