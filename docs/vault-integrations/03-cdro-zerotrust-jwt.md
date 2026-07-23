# 03 — CDRO → Vault (ZeroTrust JWT plugin)

> **Trust root:** CDRO's **own locally-signed JWT**, minted inside a procedure step by the custom
> **ZeroTrust** plugin (`v1.0`). **Deployment:** airgapped VMs, CDRO `2024.09.0.176472` (protocol 2.3).
> **Scope:** direct CDRO→Vault authentication for **KV v2 reads**, plus a mint-and-hand-off path for
> external consumers (AAP) that need dynamic secrets. Vault auth method: `auth/jwt-cdro` (JWT),
> validated by **static public key** — **no** OIDC discovery/JWKS.
>
> **Supersedes the former CI-broker premise.** Earlier docs assumed CDRO had *no* way to prove its
> identity to Vault and routed KV reads through a CI broker. The ZeroTrust plugin mints usable JWTs
> directly, so CDRO authenticates on its own; the CI broker is retained here only as a **fallback**
> (§10). See the decision record in [`00-architecture-overview.md`](00-architecture-overview.md#8-decision-record-why-these-choices) §8.
>
> **Visual, end-user version:** an infographic-first, multi-skill-level guide series covering this
> plugin and a full release across every use case lives in
> [`../cdro-user-guides/`](../cdro-user-guides/). This file remains the architect reference.

---

## 1. How the ZeroTrust plugin works (verified against a decoded token)

The ZeroTrust plugin is a CDRO **plugin package** (source + docs in a private GitHub repo), installed
by CDRO admins and exposed to CDRO end users. Its job: mint a short-lived JWT from within a procedure
step and present it to Vault.

**Signing & validation (the crux).**
- The plugin **signs the JWT locally** using a key from its configuration's **Credential** field, with
  a configurable **Algorithm** and a fixed **`Issuer = ZeroTrust`**.
- Vault validates it with **static public keys** on the mount (`jwt_validation_pubkeys`) plus
  `bound_issuer = "ZeroTrust"`. **There is no JWKS / OIDC-discovery endpoint** — so
  `oidc_discovery_url` is never set and [`../../tools/check_oidc_discovery.py`](../../tools/check_oidc_discovery.py)
  (a CI-only firewall-flow-#1 check) **does not apply** to CDRO. There is likewise **no Vault→CDRO
  network flow**.
- **Key distribution is manual/admin-managed:** the private signing key lives in the CDRO Credential;
  an admin pastes the matching **public key** into the Vault mount; **rotation is a coordinated manual
  step** (§7).

**Plugin configuration fields** (Plugin-Management → Configurations → New Configuration): `Name`,
`Project`, `Description`, `Plugin=ZeroTrust`, **`Endpoint`** (Vault URL, referable as `<vault-url>`),
**`Role`** (Vault JWT role), **`Provider`** (JWT auth **mount path**), **`Issuer`** = `ZeroTrust`,
**`customClaims`** (JSON building the JWT payload — **where `aud` and the release claim are set**),
**`Test Connection Claims`**, **`Token lifetime`** (default `900` s), **`Credential`** (private signing
key), **`Algorithm`** (HS/RS/ES/PS/EdDSA — deployment uses an **asymmetric** alg), **`secret_mount_path`**
(KV mount, `secret`), **`Namespace`** (`AUT`), **`debugLevel`** (info/debug/trace).

**Token verification (Phase-1 finding).** Decode one real token from a test run with
`inspect_jwt_claims.py` and confirm: header `alg` = an asymmetric algorithm; `iss = ZeroTrust`;
`aud` = the operator-set audience; `job_name` = `$[/myRelease/name]`; short `exp − iat` (~900 s).

> **Two open items to close from a real token** (default assumptions until confirmed):
> 1. **exact `aud`** placed in `customClaims` → set the role's `bound_audiences` to match
>    (assumed **`vault-AUT`**).
> 2. **exact asymmetric algorithm + public-key PEM** for `jwt_validation_pubkeys`
>    (assumed **RS256**). Confirm the header `alg` and read the plugin config for the PEM.

---

## 2. Vault JWT mount (static pubkey — no discovery)

> **Need the key pair?** Generate `zerotrust-private.pem` (→ CD/RO Credential) and `zerotrust-pub.pem`
> (→ `jwt_validation_pubkeys` below) with `openssl` per the runbook
> [`../getting-started/03a-zerotrust-key-generation.md`](../getting-started/03a-zerotrust-key-generation.md)
> (RS256/RSA default; ES→EC, EdDSA→Ed25519). The PEM below is that public key.

**CLI:**
```bash
export VAULT_NAMESPACE=AUT
vault auth enable -path=jwt-cdro jwt
vault write auth/jwt-cdro/config \
    jwt_validation_pubkeys=@/etc/pki/vault/zerotrust-pub.pem \
    bound_issuer="ZeroTrust"
# NOTE: no oidc_discovery_url / jwks_url — the plugin has no discovery endpoint.
```

**Terraform (1.13.1):**
```hcl
resource "vault_jwt_auth_backend" "jwt_cdro" {
  namespace              = "AUT"
  path                   = "jwt-cdro"
  type                   = "jwt"
  bound_issuer           = "ZeroTrust"
  jwt_validation_pubkeys = [file("/etc/pki/vault/zerotrust-pub.pem")]
  # deliberately no oidc_discovery_url
}
```

**Self-service YAML:**
```yaml
auth_methods:
  - path: jwt-cdro
    type: jwt
    config:
      bound_issuer: "ZeroTrust"
      jwt_validation_pubkeys_file: "zerotrust-pub.pem"   # static key; no discovery url
    roles:
      - { ref: cdro-zerotrust }   # §3
```

> `jwt_validation_pubkeys` accepts **multiple** PEMs — supply old+new during a rotation overlap (§7).

---

## 3. Role — bind to the confirmed `aud` and the release claim

**CLI:**
```bash
vault write auth/jwt-cdro/role/cdro-zerotrust \
    role_type="jwt" user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" bound_claims='{"job_name":"*"}' \
    claim_mappings='{"job_name":"release"}' \
    token_policies="cdro-zerotrust-ro" \
    token_ttl="15m" token_max_ttl="15m"
```

**Terraform (1.13.1):**
```hcl
resource "vault_jwt_auth_backend_role" "cdro_zerotrust" {
  namespace       = "AUT"
  backend         = vault_jwt_auth_backend.jwt_cdro.path
  role_name       = "cdro-zerotrust"
  role_type       = "jwt"
  user_claim      = "sub"
  bound_audiences = ["vault-AUT"]        # == the token's aud (confirm in §1)
  bound_claims_type = "glob"
  bound_claims    = { job_name = "*" }   # claim must be present; policy path confines the run
  claim_mappings  = { job_name = "release" }
  token_policies  = ["cdro-zerotrust-ro"]
  token_ttl       = 900                  # seconds in TF
  token_max_ttl   = 900
}
```

**Self-service YAML:**
```yaml
      - name: cdro-zerotrust
        role_type: jwt
        user_claim: sub
        bound_audiences: ["vault-AUT"]
        bound_claims_type: glob
        bound_claims: { job_name: "*" }
        claim_mappings: { job_name: "release" }
        token_policies: ["cdro-zerotrust-ro"]
        token_ttl: "15m"
        token_max_ttl: "15m"
```

- `claim_mappings` copies `job_name` → entity-alias metadata `release`, interpolated by the policy (§4).
- `bound_claims='{"job_name":"*"}'` requires the claim to exist; **the templated policy path**, not the
  role, confines each run to its own release. Replace `*` with an explicit release allow-list to reject
  unknown releases at the auth layer.
- `user_claim="sub"` makes Vault audit attribute the read to CDRO's own identity.

---

## 4. Policy — KV v2 read-only, release-scoped (templated)

Reuses guide `02` §4.1 / guide `01` §5.1's `claim_mappings` + templated-policy pattern. Substitute the
real mount accessor for `<jwt-cdro-accessor>` (`vault auth list -detailed`):

```hcl
# cdro-zerotrust-ro.hcl  — each token reads only its own release's KV path
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}
```

**No** `create`/`update`/`delete`, **no** SSH, **no** dynamic-secret capabilities — the plugin's own
reads are KV v2 only (Pattern A). Dynamic secrets are reached **externally** via the hand-off (§6),
not by this role.

---

## 5. Usage Pattern A — in-CDRO read (plugin authenticates & reads)

The plugin logs in and pulls the secret from `secret/data/cdr/<release>/…`. Three documented
procedures, and three consumption tiers (curl / native / vault-CLI) — see the beginner guide
[`../getting-started/03-cloudbees-cdro.md`](../getting-started/03-cloudbees-cdro.md) Step 5 and the
tiered templates under [`examples/`](examples/).

- **`UpdateCdroCredentialThroughJwtRequest`** — reads a KV secret and writes it into an existing CDRO
  credential. Mapping: **1 pair** → key=username / value=password; **2 pairs `{username,password}`** →
  mapped directly; **>2 pairs** → the whole secret stored as JSON in the password field.
- **`getCdroCredentialAndRunStep`** — stores the secret (JSON) in the password of a credential
  **always named `zt_credential`**, then runs a shell / `ec-groovy` command that reads it via
  `getFullCredential(credentialName:"zt_credential")`.
- **`getAuthorizedTokenAndRunStep`** — stores the **Vault-authorized token** in `zt_credential`, then
  runs a command that uses it.

---

## 6. Usage Pattern B — mint and hand off (external consumer / dynamic secrets)

CDRO mints a JWT and lets a downstream system do its own Vault exchange. This is how **dynamic**
secrets are reached — the KV-only limit applies to the in-CDRO procedures (Pattern A), not to the
overall capability.

- **`IssueJwtAndStoreInProperty`** — mints a JWT with the given `customClaims` (e.g.
  `{"sub":"aap_job","aap_runner":"ip1,ip2"}`) and stores it in a CDRO **property**
  (e.g. `/myPipelineRuntime/jwtToken`).
- A downstream **AnsibleTower** plugin step passes it as a job parameter
  (`{"jwt":"$[/myPipelineRuntime/jwtToken]"}`); the **AAP agent** performs its own Vault login (its own
  role/mount/policy, including dynamic engines). CDRO never sees the secret.

Treat the property as sensitive: mark it secure/masked, never echo it, and scope the JWT's claims and
`Token lifetime` tightly.

---

## 7. Manual key rotation

No automation — a coordinated, two-place change:
1. Generate a new asymmetric key pair (same alg family) with `openssl` — see the runbook
   [`../getting-started/03a-zerotrust-key-generation.md`](../getting-started/03a-zerotrust-key-generation.md).
2. **Add** the new public key to Vault first (`jwt_validation_pubkeys` = OLD + NEW → dual-trust window).
3. **Swap** the private key in the CDRO Credential (new runs sign with NEW; in-flight OLD tokens still validate).
4. After the overlap (≥ `Token lifetime`, ~900 s), **remove** the OLD public key; destroy the OLD private key.

---

## 8. Reconciliation decision (direct-JWT vs. broker)

- **Direct ZeroTrust JWT is primary** for CDRO KV reads: CDRO proves its own identity, so Vault audit
  attributes the read to **CDRO** (`user_claim=sub`), not a CI broker. This removes the broker's
  accepted audit-attribution tradeoff for the KV case.
- **The CI broker is retained only as a fallback** (§10) — where the plugin isn't installed/approved,
  or as a migration bridge.
- **Secret-path convention is `cdr/<release>`** (e.g. `cdr/$[/myRelease/name]`), authoritative and
  replacing the former `cdro/<app>` convention repo-wide.
- **No Vault→CDRO discovery flow exists** — validation is by static pubkey, not JWKS; the firewall
  matrix gains a CDRO→Vault:8200 **login** flow and drops any discovery expectation.

---

## 9. Limitations, risks & non-functional notes

**Limitations**
- **Concurrency clobber:** two runs from *different* releases/pipelines sharing the *same* CDRO
  credential overwrite each other (last write wins → wrong creds → auth failure). Give each
  release/pipeline its own credential or serialize. Same-source concurrent runs (same secret) are safe.
- **Coarse `sub`:** operator-set free text — real identity enforcement comes from binding on
  `job_name`/release, not `sub`.
- **KV v2 only** for the plugin's own reads (Pattern A). Dynamic secrets only via the hand-off (§6).
- **Manual key rotation** (no automation).

**Risks & mitigations**
- **Signing-key compromise → JWT forgery** (private key sits in a CDRO Credential): least-privilege
  Credential ACLs, restrict who can edit the plugin configuration, short `Token lifetime`, rotate keys (§7).
- **JWT leaked via the property/AAP hand-off (Pattern B):** treat the property as sensitive, avoid
  echoing, scope claims/TTL tightly.
- **`debugLevel=debug/trace` may log the JWT or secret values:** keep `info` in production.
- **Over-broad Vault role** if `bound_claims` isn't scoped on `job_name`/release, or if the policy isn't
  templated per release.

**Non-functional**
- Token lifetime operator-set (default 900 s, no hard cap) → keep the Vault token TTL short (≤ 900 s).
- No separate HA — availability is tied to the CDRO server/agent running the step.
- No known plugin-imposed rate limits (Vault's own limits still apply).
- Operational logging controlled by `debugLevel`.

---

## 10. Fallback: CDRO secrets via the CI broker (interim / where the plugin can't be used)

Retained for environments without the ZeroTrust plugin, or as a migration bridge. Here CDRO has **no
identity of its own**: it triggers a CI **broker** job that logs into Vault with **CI's** OIDC identity,
reads + **response-wraps** the secret (or returns a dynamic lease), and CDRO **unwraps just-in-time**.
**Accepted tradeoff:** Vault audit attributes the access to the **CI broker identity**, not CDRO.

```
CDRO procedure ──(trigger, params: scope=cdr/<release>/db)──► CI broker job
                                                              │ ID token (string cred) → jwt-ci login
                                                              │ read secret / mint dynamic cred
                                                              │ wrap (KV) OR return lease (dynamic)
CDRO ◄──────────────(wrapping token / lease id)──────────────┘
  │ unwrap (single-use) OR use lease → expires
```

**Trigger (CDRO → CI):** a CDRO step calls the controller build API with a scoped CI token, or uses the
native CDRO↔CI integration, passing `SCOPE`, `SECRET_TYPE`, `REQ_ID` (firewall flow #4; return is #5).

**Broker role (bound tightly to the broker job):**
```bash
vault write auth/jwt-ci-ctrlA/role/cdro-broker \
    role_type=jwt user_claim=sub bound_audiences="vault-AUT" \
    bound_claims_type=glob bound_claims='{"job":"AUT/vault-broker"}' \
    token_policies="cdro-broker" token_ttl="5m" token_max_ttl="10m"
```

**Broker policy** (`cdro-broker.hcl`) grants read on `secret/data/cdr/*` (and specific dynamic paths)
only. **CDRO side** unwraps once (`vault unwrap`, tamper-evident single-use) or uses the lease and lets
it expire. Mark any CDRO parameter carrying secrets as password/masked. The CI trigger token only
*starts a build* — it grants no Vault access — and is stored in the CDRO credential store.

> Prefer the direct ZeroTrust flow (§1–§7). Use this broker path only when the plugin is unavailable.

---

## Safeguards (direct ZeroTrust flow — all required)

- [ ] Mount uses **static `jwt_validation_pubkeys` + `bound_issuer=ZeroTrust`**; no discovery URL.
- [ ] Role: `bound_audiences` == token `aud`; `bound_claims` scoped on `job_name`/release; `user_claim=sub`.
- [ ] Policy: **KV v2 read-only**, templated on `cdr/<release>/*`; no write/dynamic/SSH.
- [ ] `Algorithm` asymmetric; `debugLevel=info`; signing Credential ACL locked down.
- [ ] Each release/pipeline uses its own CDRO credential (concurrency-clobber avoidance).
- [ ] Token TTL ≤ 900 s; token revoked or expired after use.
- [ ] Key rotation runbook (§7) rehearsed; old public key removed after overlap.

---

## Verification

```bash
export VAULT_NAMESPACE=AUT
vault read auth/jwt-cdro/config                     # bound_issuer=ZeroTrust, a pubkey, NO discovery url
vault read auth/jwt-cdro/role/cdro-zerotrust        # user_claim=sub, bound_audiences, claim_mappings
vault policy read cdro-zerotrust-ro                 # templated cdr/<metadata.release>/* , read-only
# Decode a real token (test run only):
python3 ../../tools/inspect_jwt_claims.py < token.jwt   # iss=ZeroTrust, asymmetric alg, aud, job_name
```

- A `payments-app` run reads `secret/data/cdr/payments-app/db`; the same role against another release's
  path returns **403** (release scoping).
- SIEM shows the read under the **CDRO** identity with policy `cdro-zerotrust-ro` — not a CI broker.
- No secret value appears in any CDRO job log or property.
- Rotation (§7): during overlap both keys validate; after cleanup an old-key token is rejected.
