# 07 — AAP consumes a CDRO ZeroTrust JWT (EC-AnsibleTower hand-off)

> **Scope:** the **consumer side** of [`03-cdro-zerotrust-jwt.md`](03-cdro-zerotrust-jwt.md) §6
> (Pattern B). A CDRO pipeline mints a ZeroTrust JWT, the **EC-AnsibleTower** plugin launches an
> **AAP job template** and passes the JWT as an extra variable, and the **AAP job** logs in to Vault
> **itself** to fetch KV **and dynamic** secrets. CDRO never sees the secret.
>
> **Why hand off at all?** The in-CDRO ZeroTrust procedures (Pattern A) are **KV v2 read-only**.
> Dynamic engines (DB creds, SSH signing, PKI) are reached on the **consumer** — so AAP does its own
> Vault exchange with a JWT that CDRO mints for it.
>
> **Deployment target:** AAP **2.4** (automation controller **4.5.25**); the EC-AnsibleTower plugin
> (`1.7.0.2026070354`) supports AAP controller **≤ 4.8 / core ≤ 2.7**. Native AAP OIDC is a **2.7 Tech
> Preview** — not used here; the JWT→Vault exchange is done **inside the playbook**, so it works on 2.4.
>
> **Working examples:**
> [`examples/aap-vault-jwt.yml`](examples/aap-vault-jwt.yml) (collection),
> [`examples/aap-vault-jwt-nocollection.yml`](examples/aap-vault-jwt-nocollection.yml) (airgap / REST),
> [`examples/cdro-ansibletower-jwt.dsl`](examples/cdro-ansibletower-jwt.dsl) (CDRO side).
>
> **New to this? The copy-paste beginner walkthrough is**
> [`../getting-started/04a-aap-jwt-from-cdro.md`](../getting-started/04a-aap-jwt-from-cdro.md).

---

## 1. End-to-end flow

```
┌──────────────────────── CloudBees CD/RO pipeline ────────────────────────┐
│  Task 1  ZeroTrust plugin: IssueJwtAndStoreInProperty                     │
│          mints JWT  { iss:ZeroTrust, sub:aap_job, aud:vault-aap, ... }    │
│          → stores in SECURE property /myPipelineRuntime/jwtToken          │
│                                                                          │
│  Task 2  EC-AnsibleTower plugin: "Launch a Job Template"                  │
│          jobTemplateParams = { "extra_vars": { "vault_jwt": "<prop>" }}   │
└───────────────────────────────────┬──────────────────────────────────────┘
                                     │ REST launch (Bearer/Basic) + extra_vars
                                     ▼
┌──────────────────────────── AAP job template ─────────────────────────────┐
│  runs aap-vault-jwt.yml with extra_var vault_jwt                          │
│   1. POST /v1/auth/jwt-cdro/login  { role:aap-consumer, jwt:<vault_jwt> } │
│   2. GET  /v1/secret/data/cdr/<release>/db        (KV v2, release-scoped)  │
│   3. GET  /v1/database/creds/app-readonly         (dynamic DB creds)       │
│   4. use secrets in the deploy; revoke-self at the end                     │
└───────────────────────────────────┬──────────────────────────────────────┘
                                     │ static-pubkey JWT validation (no JWKS)
                                     ▼
                        Vault Enterprise (ns AUT), mount jwt-cdro
```

Trust root is the ZeroTrust plugin's **locally-signed** JWT, validated by Vault against a **static
public key** (`jwt_validation_pubkeys`) + `bound_issuer=ZeroTrust`. There is **no OIDC discovery / no
Vault→AAP or Vault→CDRO flow**. Firewall additions: **CDRO→AAP:443** (launch) and **AAP→Vault:8200**
(login + reads).

---

## 2. The EC-AnsibleTower plugin (what you actually configure)

**Plugin ID** `EC-AnsibleTower` · **Tier** CloudBees · integrates Ansible Tower / AWX / AAP.
**Supported:** AAP controller **≤ 4.8**, AAP core **≤ 2.7**.

### 2.1 Configuration parameters (Plugin Management → Plugin configurations)

| Parameter | Notes for this integration |
|---|---|
| **Name** | e.g. `aap-prod` — referenced by every procedure. |
| **Ansible Tower Server** | REST API endpoint, e.g. `https://aap.corp.example.com/api/controller/v2`. |
| **Auth scheme** | `Bearer token` (recommended) or `Basic Auth`. This authenticates **CDRO→AAP** only — it is **unrelated** to the JWT the job uses for Vault. |
| **Basic Auth Credential** | username/password (if Auth scheme = Basic). |
| **Bearer token** | AAP OAuth2 token (if Auth scheme = Bearer). Prefer a least-privilege AAP service account that may only *launch* the one job template. |
| **Ignore SSL issues** | Off in prod; on only for self-signed lab certs. |
| **Ansible Automation Platform (AAP) version** | selects the correct API path — set to your version (e.g. `2.4`). |
| **Check connection resource** | optional resource used for the connection test. |
| **HTTP proxy / Proxy authorization** | if CDRO reaches AAP via a proxy. |
| **Debug level** | **Info** in production. *Debug/Trace prints request bodies — which include the JWT.* |

### 2.2 Procedures used here

| Procedure (display name) | Purpose | Key inputs |
|---|---|---|
| **Launch a Job Template** | run a job template | *Configuration name*, *Job template name/ID*, *Job template parameters* = `{ "extra_vars": {...} }` |
| **Launch A Workflow Job Template** | run a workflow template | same three, params: `{ "extra_vars": {...} }` |
| **Retrieve a Job Template** / **List Workflow Job Templates** / **List Inventories / Projects** | discovery / IDs | *Configuration name* (+ *Search* / *name/ID*) |

> The **entire JWT hand-off rides in one field**: **Job template parameters**. Everything else is
> plumbing. The plugin forwards that JSON to the AAP `/launch` endpoint, so any launch-time field AAP
> accepts (`extra_vars`, `limit`, `job_tags`, `inventory`) can go there.

---

## 3. Vault: a dedicated JWT role for the AAP consumer

Reuse the `jwt-cdro` mount from guide 03 (same ZeroTrust pubkey validates the token). Add a **separate
role** bound to a **distinct audience** (`vault-aap`) so the AAP path and the in-CDRO KV path can't be
used interchangeably.

**CLI:**
```bash
export VAULT_NAMESPACE=AUT
vault write auth/jwt-cdro/role/aap-consumer \
    role_type="jwt" user_claim="sub" \
    bound_audiences="vault-aap" \
    bound_claims_type="glob" bound_claims='{"sub":"aap_job","job_name":"*"}' \
    claim_mappings='{"job_name":"release"}' \
    token_policies="aap-consumer" \
    token_ttl="15m" token_max_ttl="15m"
```

**Terraform (1.13.1):**
```hcl
resource "vault_jwt_auth_backend_role" "aap_consumer" {
  namespace         = "AUT"
  backend           = "jwt-cdro"          # existing mount from guide 03
  role_name         = "aap-consumer"
  role_type         = "jwt"
  user_claim        = "sub"
  bound_audiences   = ["vault-aap"]       # == aud set in the ZeroTrust customClaims
  bound_claims_type = "glob"
  bound_claims      = { sub = "aap_job", job_name = "*" }
  claim_mappings    = { job_name = "release" }
  token_policies    = ["aap-consumer"]
  token_ttl         = 900
  token_max_ttl     = 900
}
```

- `bound_audiences=["vault-aap"]` **must equal** the `aud` the ZeroTrust config puts in `customClaims`.
- `claim_mappings` copies `job_name` → alias metadata `release`, so the policy can template on it.
- Replace `job_name:"*"` with an explicit release allow-list to reject unknown releases at auth time.

---

## 4. Vault policy — KV (release-scoped) + dynamic secrets

```hcl
# aap-consumer.hcl
# 4.1 KV v2, templated to this run's release (same convention as guide 03)
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}

# 4.2 Dynamic DB credentials (the reason for the hand-off) — scope to the roles AAP may use
path "database/creds/app-readonly" {
  capabilities = ["read"]
}

# 4.3 (optional) SSH cert signing / PKI issue — add only what this job needs
# path "ssh-client-signer/sign/aap-role" { capabilities = ["update"] }
```

Substitute the real accessor for `<jwt-cdro-accessor>` (`vault auth list -detailed`). Grant **only** the
dynamic paths this job template actually calls — least privilege per template.

---

## 5. CDRO: mint the JWT with an AAP-targeted audience

ZeroTrust plugin Configuration `vault-aut-aap` (or override per task), key fields:

| Field | Value |
|---|---|
| `Issuer` | `ZeroTrust` |
| `Algorithm` | asymmetric (deployment default **RS256**) |
| `Token lifetime` | `900` (keep tight) |
| `customClaims` | `{"sub":"aap_job","aud":"vault-aap","job_name":"$[/myRelease/name]"}` |

`aud=vault-aap` is what the `aap-consumer` role binds on; `job_name` becomes the `release` that scopes
the KV policy. Store the minted token in a **secure/masked** property
(`/myPipelineRuntime/jwtToken`) via `IssueJwtAndStoreInProperty` — see
[`examples/cdro-ansibletower-jwt.dsl`](examples/cdro-ansibletower-jwt.dsl).

---

## 6. AAP: the job template + the playbook

### 6.1 Job template setup (one-time, in AAP)
1. Project pointing at the repo that holds `aap-vault-jwt.yml`.
2. Job template **`vault-jwt-consumer`** → that playbook, on a suitable inventory/EE.
3. **Variables → check "Prompt on launch"** *(ask_variables_on_launch)*. **Required** — without it (or a
   Survey), AAP **silently ignores** extra_vars sent by the plugin. This is the #1 gotcha.
4. Execution environment: use one that ships **`community.hashi_vault`** for
   [`aap-vault-jwt.yml`](examples/aap-vault-jwt.yml); if airgapped without it, use
   [`aap-vault-jwt-nocollection.yml`](examples/aap-vault-jwt-nocollection.yml) (pure `uri`, zero deps).

### 6.2 What the playbook does (the "working AAP job")
1. **Assert** `vault_jwt` was passed (fail fast with a clear message).
2. **`POST /v1/auth/jwt-cdro/login`** `{role: aap-consumer, jwt: <vault_jwt>}` → client token (one login).
3. **KV v2 read** `secret/data/cdr/<release>/db` (release-scoped by the templated policy).
4. **Dynamic DB creds** `database/creds/app-readonly` (short-lived, lease-revoked).
5. **Use** the secrets (env vars into the deploy step) — with `no_log: true`.
6. **Revoke-self** at the end; the short TTL is the backstop.

Every credential-bearing task sets **`no_log: true`**. Keep it — Debug/Trace job output would otherwise
leak the JWT and secret values.

---

## 7. The various ways to use it

| # | Way | How | When |
|---|---|---|---|
| **A** | **KV only** | Delete the dynamic-creds task; keep step 3. | AAP just needs a static secret CDRO could also read — but you want the read attributed to the AAP run and kept off the CDRO server. |
| **B** | **Dynamic secrets** *(primary reason to hand off)* | Keep step 4 (`database/creds/*`, add `ssh-client-signer/sign/*`, `pki/issue/*` to §4). | AAP needs DB creds / SSH certs / PKI that the KV-only in-CDRO path can't produce. |
| **C** | **Collection vs. dependency-free** | `aap-vault-jwt.yml` (community.hashi_vault) **or** `aap-vault-jwt-nocollection.yml` (raw `uri`). | Airgapped EEs without the collection → use the REST version. |
| **D** | **Job vs. workflow template** | "Launch a Job Template" (`RunJobTemplate`) **or** "Launch A Workflow Job Template" (`RunWorkflowJobTemplate`); same `{"extra_vars":{...}}`. | Multi-node AAP workflows. |
| **E** | **extra_vars vs. Survey** | Prompt-on-launch `extra_vars` (shown here) **or** define a Survey field `vault_jwt`. | Survey avoids enabling arbitrary extra_vars; more locked-down. |
| **F** | **Extra launch fields** | Add `limit`, `job_tags`, `inventory` alongside `extra_vars` in the same JSON. | Target a subset of hosts / tags at launch. |
| **G** | **One JWT, several reads** | The playbook logs in once and reuses the token for N reads (already structured this way). | Multiple secrets in one job — avoids N logins. |

> **Contrast with Pattern A (in-CDRO):** if you *don't* need dynamic secrets and don't need AAP,
> read KV directly in CDRO via the ZeroTrust procedures — see
> [`examples/cdro-zerotrust-native.dsl`](examples/cdro-zerotrust-native.dsl). Hand off to AAP only when
> the work (and the dynamic-secret need) lives in AAP.

---

## 8. Security safeguards (all required)

- [ ] ZeroTrust `customClaims.aud` == role `bound_audiences` (`vault-aap`); `job_name` set to the release.
- [ ] Vault role `aap-consumer` on `jwt-cdro`; `user_claim=sub`; `bound_claims` scoped; `token_ttl ≤ 900 s`.
- [ ] Policy templated to `cdr/<release>/*` for KV; dynamic paths limited to the exact roles this job uses.
- [ ] CDRO property `/myPipelineRuntime/jwtToken` marked **secure/masked**; never echoed.
- [ ] EC-AnsibleTower **Debug level = Info** (Debug/Trace prints the JWT in request bodies).
- [ ] Playbook: `no_log: true` on every JWT/token/secret task; **revoke-self** at the end.
- [ ] AAP launch credential (Bearer/Basic) is least-privilege — may only launch this template.
- [ ] Job template uses Prompt-on-launch **or** a Survey; nothing else consumes the passed vars.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `vault_jwt` undefined in the job | Job template lacks **Prompt on launch** for Variables (extra_vars dropped). | Enable it, or add a Survey field. §6.1. |
| Vault login `400 invalid audience` | `customClaims.aud` ≠ role `bound_audiences`. | Align both to `vault-aap`. §3, §5. |
| Vault login `400 no key to validate` / `invalid signature` | Wrong/old public key on the mount, or alg mismatch. | Confirm `jwt_validation_pubkeys` matches the ZeroTrust private key + `Algorithm`. See 03 §2, §7. |
| Login OK, read `403` | Policy not templated to this release, or dynamic path not granted. | Fix `aap-consumer.hcl` (§4); check accessor. |
| Login `403` mount not found | `mount_point`/URL mount ≠ `jwt-cdro`. | Match the mount in playbook vars. |
| JWT visible in AAP job output | Debug/Trace, or a task missing `no_log`. | Info level; restore `no_log: true`. |
| `community.hashi_vault` not found | Airgapped EE without the collection. | Use `aap-vault-jwt-nocollection.yml`. |

---

## 10. Verification

```bash
export VAULT_NAMESPACE=AUT
vault read auth/jwt-cdro/role/aap-consumer     # bound_audiences=vault-aap, user_claim=sub, claim_mappings
vault policy read aap-consumer                 # templated cdr/<release>/* + only the dynamic paths needed
python3 ../../tools/inspect_jwt_claims.py < token.jwt   # iss=ZeroTrust, aud=vault-aap, sub=aap_job, job_name
```

- A `payments-app` release run reads `secret/data/cdr/payments-app/*`; a token minted for another
  release is **403** on that path (release scoping).
- SIEM shows the KV read and the `database/creds/app-readonly` issue under the **AAP job's** JWT
  identity, tied to the release — not a CI broker, not the CDRO server.
- No JWT or secret value appears in the CDRO pipeline log, the CDRO property (masked), or the AAP job
  output.
- Dynamic DB lease appears in `vault list sys/leases/lookup/database/creds/app-readonly` during the run
  and is gone after the job's revoke-self / lease TTL.
```
