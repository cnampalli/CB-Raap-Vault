# 03 — CloudBees CD/RO → Vault (ZeroTrust JWT plugin)

CloudBees CD/RO `2024.09.0.176472` can now prove **its own identity** to Vault. The
org's custom **ZeroTrust** plugin (v1.0) mints a short-lived, signed **JWT inside a
CD/RO procedure step**, and Vault validates it and hands back a token scoped to only
that release's secrets. No CI broker sits in the middle for KV reads anymore.

> **New here? Two words first.** A **JWT** is a short-lived signed token a workload
> creates to prove who it is (see the [glossary](00-before-you-begin.md#5-mini-glossary)).
> The ZeroTrust plugin is the thing that mints it for CD/RO.

**Your versions:** CD/RO `2024.09.0.176472` (protocol 2.3) · ZeroTrust plugin `v1.0` ·
Vault Enterprise `1.20.8+ent`, namespace `AUT`.

Do guide [01](01-vault-setup.md) first (it creates the KV store and namespace). Unlike CI,
CD/RO does **not** need guide 02 — it authenticates directly.

```
CD/RO procedure  ──[ZeroTrust plugin mints & signs a JWT: iss=ZeroTrust, job_name=<release>]
      │  POST /v1/auth/jwt-cdro/login   (jwt + role)
      ▼
Vault (AUT)  ──validates with a STATIC public key (no JWKS/discovery)──►  short-lived token
      │  read secret/data/cdr/<release>/…   (KV v2, read-only, release-scoped)
      ▼
CD/RO uses the secret → token expires
```

> **How Vault trusts this token (the crux).** The plugin signs the JWT **locally** with a
> key held in a CD/RO **Credential**, stamping `Issuer = ZeroTrust`. Vault validates it
> against a **static public key** you paste into the mount (`jwt_validation_pubkeys`) plus
> `bound_issuer = "ZeroTrust"`. **There is no JWKS / OIDC-discovery endpoint** — so, unlike CI,
> you do **not** run [`check_oidc_discovery.py`](../../tools/check_oidc_discovery.py) here, and
> Vault never calls back to CD/RO. Key rotation is a manual, coordinated step (Step 8).

---

## Step 1 — Create the ZeroTrust plugin configuration

This is where a CD/RO admin tells the plugin *which Vault to talk to, which role to use, how to
sign the JWT, and what claims to put in it*. Do it once per environment.

Open **Plugin Management → Configurations → New Configuration**, select **Plugin = ZeroTrust**, and fill in:

| Field | Set it to | Why it matters |
|---|---|---|
| `Name` | e.g. `vault-aut` | The configuration you reference from procedures. |
| `Project` | your CD/RO project | Scopes the configuration. |
| `Endpoint` | `https://<vault-vip>:8200` | Vault's URL. Referable in claims as `<vault-url>`. |
| `Role` | `cdro-zerotrust` | The Vault **JWT auth role** (Step 4). |
| `Provider` | `jwt-cdro` | The Vault JWT auth **mount path** (Step 3). |
| `Issuer` | `ZeroTrust` | **Must** equal the Vault mount's `bound_issuer`. |
| `customClaims` | see below | JSON that builds the JWT payload — **this is where `aud` and the release claim are set.** |
| `Test Connection Claims` | a small JSON, e.g. `{"sub":"test","job_name":"test","aud":"vault-AUT"}` | Used by the config's **Test Connection** button. |
| `Token lifetime` | `900` (default) | JWT validity in seconds — keep it short. |
| `Credential` | a CD/RO credential holding the **private signing key** | The plugin signs with this. Lock its ACL down (Step 8). |
| `Algorithm` | `RS256` *(recommended default)* | Must be an **asymmetric** alg so Vault can validate with a public key. |
| `secret_mount_path` | `secret` | The KV v2 mount secrets live under. |
| `Namespace` | `AUT` | Must equal the Vault namespace. |
| `debugLevel` | `info` | **Keep `info` in production** — `debug`/`trace` can log the JWT or secret values. |

**customClaims** builds the token payload. Put the audience and a **release claim** here — the
release name is what scopes each run to its own secrets:

```json
{
  "sub": "$[/myJob/launchedByUser]",
  "aud": "vault-AUT",
  "job_name": "$[/myRelease/name]"
}
```

- `aud` — a fixed audience string. We use `vault-AUT` to match the rest of the suite; your Vault
  role's `bound_audiences` must equal it **exactly** (Step 4). *(Open item — confirm the real value
  from a decoded token in Step 2.)*
- `job_name` — resolves to the running release's name (`$[/myRelease/name]`), e.g. `payments-app`.
  Vault maps it to the secret path `cdr/<release>/…` so each release reads **only its own** secrets.

> **Glossary:** `$[/myRelease/name]` is CD/RO's property-reference syntax — at run time the plugin
> substitutes the live release name. Anything you can reference in CD/RO you can put in a claim.

**Step 1 — Hardening checklist**

- [ ] `Algorithm` is asymmetric (RS/ES/PS/EdDSA) — never `HS*` (a shared secret can't be validated by a public key).
- [ ] `debugLevel = info` in production.
- [ ] `Credential` (private signing key) has a tight ACL — only this configuration can read it.
- [ ] `Token lifetime` ≤ 900 s.
- [ ] `Namespace = AUT`, `Issuer = ZeroTrust`.

**Step 1 — Verify:** the configuration's **Test Connection** button succeeds against `Endpoint`.
(It will only fully pass once Steps 3–4 exist in Vault.)

Next: capture a token and confirm what's actually inside it.

---

## Step 2 — Capture one token and confirm its claims

Never build a Vault role against assumptions. Emit one real JWT from a **test** procedure and
decode it, so you can set `bound_audiences` and the signing algorithm to what the plugin *actually*
produces.

Run a throwaway procedure step that mints a JWT and writes it to the job log **or** a property
(use `IssueJwtAndStoreInProperty`, see Step 6). Copy the `eyJ…` value, then decode it locally with
the airgap-safe helper (it does **no** network calls and **no** signature check — just shows the claims):

```bash
# Paste the token via stdin so it never lands in your shell history / argv.
python3 tools/inspect_jwt_claims.py <<'EOF'
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.<payload>.<sig>
EOF
```

Confirm in the output:

| You should see | Meaning | Use it for |
|---|---|---|
| header `"alg": "RS256"` (or ES/PS/EdDSA) | the real signing algorithm | pick the matching **public key type** for Step 3 |
| `iss = ZeroTrust` | the issuer | Vault `bound_issuer` |
| `aud = vault-AUT` (or whatever you set) | the audience | Vault role `bound_audiences` |
| `job_name = <release>` | the release claim | Vault role `bound_claims` + `claim_mappings` |
| `sub`, `exp`, `iat` | subject + short expiry | sanity: `exp − iat ≈ 900 s` |

> ⚠️ **Two things to lock down from the real token (open items):**
> 1. the exact **`aud`** string — set the role's `bound_audiences` to match it;
> 2. the exact **algorithm** and the matching **public-key PEM** — you paste that PEM into Vault in Step 3.
> Until you have decoded a real token, treat `RS256` + `aud=vault-AUT` as placeholders.

**Step 2 — Verify:** the decoded header shows an **asymmetric** `alg`, and the payload shows
`iss=ZeroTrust` plus your release in `job_name`. Do not use a real production secret to generate this test token.

Next: teach Vault to trust these tokens.

---

## Step 3 — Configure the Vault JWT mount (static public key)

Vault needs a place to receive CD/RO's logins and the **public** half of the plugin's signing key
so it can check signatures. This is a one-time setup per environment (Vault team applies it).

```bash
export VAULT_ADDR="https://<vault-vip>:8200"
export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"

# 1) Enable a dedicated JWT mount for CD/RO (the plugin's "Provider" path)
vault auth enable -path=jwt-cdro jwt

# 2) Point it at the STATIC public key + the fixed issuer. NO discovery URL.
vault write auth/jwt-cdro/config \
    jwt_validation_pubkeys=@/etc/pki/vault/zerotrust-pub.pem \
    bound_issuer="ZeroTrust"
```

- `zerotrust-pub.pem` is the **public** key matching the plugin's private signing `Credential`
  (PEM, `-----BEGIN PUBLIC KEY-----`). Get it from whoever holds the ZeroTrust private key.
- **No `oidc_discovery_url`** and **no `jwks_url`** — the plugin has no discovery endpoint, so Vault
  validates offline against the pasted key. That's also why no firewall path from Vault → CD/RO exists.

**Expected result:** `Success! Data written to: auth/jwt-cdro/config`.

**Step 3 — Hardening checklist**

- [ ] `jwt_validation_pubkeys` holds only the current public key(s) — no stale keys.
- [ ] `bound_issuer = "ZeroTrust"` (exactly matches the plugin `Issuer`).
- [ ] No `oidc_discovery_url` / `jwks_url` set.

**Step 3 — Verify:**
```bash
vault read auth/jwt-cdro/config    # shows bound_issuer=ZeroTrust, a pubkey, and NO discovery url
```

Next: the role and the least-privilege policy.

---

## Step 4 — Create the Vault role + release-scoped read-only policy

The **role** decides which tokens are accepted and what they may do; the **policy** grants read on
**only** that release's secrets. Together they guarantee a `payments-app` run can never read
`billing-app`'s secrets.

First, the policy — KV v2 **read-only**, path templated by the release claim (this reuses the same
`claim_mappings` + templated-policy pattern as CI's
[Step 6.5](02-cloudbees-ci.md#step-65--advanced-project-scoped-secrets-from-jwt-claims)):

```bash
# cdro-zerotrust-ro : each token reads only secret/data/cdr/<its-own-release>/*
vault policy write cdro-zerotrust-ro - <<'EOF'
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}
EOF
```

> Replace `<jwt-cdro-accessor>` with your mount's accessor (`vault auth list -detailed` shows it).
> No `create`/`update`/`delete`, no SSH, no dynamic-secret paths — the plugin's own reads are **KV v2 only**.

Then the role — bind it to the confirmed `aud`, scope it on the release claim, and map that claim
into the identity metadata the policy reads:

```bash
vault write auth/jwt-cdro/role/cdro-zerotrust \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" \
    bound_claims='{"job_name":"*"}' \
    claim_mappings='{"job_name":"release"}' \
    token_policies="cdro-zerotrust-ro" \
    token_ttl="15m" token_max_ttl="15m"
```

- `bound_audiences="vault-AUT"` — must equal the `aud` you confirmed in Step 2.
- `claim_mappings='{"job_name":"release"}'` — copies the JWT's `job_name` into entity metadata
  `release`, which the policy interpolates into `cdr/<release>/*`.
- `bound_claims='{"job_name":"*"}'` — requires the claim to be **present** (never a wildcard-open
  role on *identity*; the **policy path** is what confines each token to its own release). Tighten to
  an explicit allow-list (e.g. `{"job_name":["payments-app","billing-app"]}`) if you want Vault to
  reject unknown releases outright.
- `token_ttl=15m` — short, aligned to the 900 s JWT lifetime.

**Expected result:** `Success! Data written to: auth/jwt-cdro/role/cdro-zerotrust`.

**Step 4 — Hardening checklist**

- [ ] Policy is **read-only** on `secret/data/cdr/<release>/*` — no write/dynamic/SSH capabilities.
- [ ] `bound_audiences` exactly equals the token's `aud`.
- [ ] Role is scoped on `job_name`/release (never an unbounded catch-all identity).
- [ ] `token_ttl` ≤ the JWT `Token lifetime`.

**Step 4 — Verify:**
```bash
vault read auth/jwt-cdro/role/cdro-zerotrust   # user_claim=sub, bound_audiences, claim_mappings present
vault policy read cdro-zerotrust-ro            # templated path uses metadata.release
```

Next: actually read a secret from a procedure — three ways, by skill level.

---

## Step 5 — Usage Pattern A: read a secret inside CD/RO

This is the everyday case: a CD/RO run needs a secret (a DB password, an API key) that lives at
`secret/data/cdr/<release>/…`. Pick the **one tier** that matches your comfort level. All three end
with the same result and never print the secret.

| Tier | Who it's for | Needs in the procedure | Example template |
|---|---|---|---|
| **1 — curl** *(recommended airgap default)* | Novice, copy-paste | `curl` on the CD/RO agent | [`cdro-zerotrust-curl.sh`](../vault-integrations/examples/cdro-zerotrust-curl.sh) |
| **2 — native plugin** | No scripting at all | *nothing* (the plugin does the HTTP) | [`cdro-zerotrust-native.dsl`](../vault-integrations/examples/cdro-zerotrust-native.dsl) |
| **3 — vault CLI** | Advanced, scripted | `vault` + `jq` on the agent | [`cdro-zerotrust-cli.sh`](../vault-integrations/examples/cdro-zerotrust-cli.sh) |

**Recommended default: Tier 1 (curl).** It needs only `curl`, sends the JWT via stdin (never argv),
and shows every step explicitly. Choose Tier 2 if your users don't script at all; Tier 3 if you want
automation and already run the `vault` CLI. **You never need Tier 3 to complete the basic flow.**

### Tier 1 — curl (recommended airgap default)

Mint a JWT into a property with `IssueJwtAndStoreInProperty` (Step 6 shows the plugin step), then a
shell procedure step logs in and reads:

```bash
# CD/RO procedure step (shell). Assumes the plugin stored the JWT at /myJob/jwtToken.
set -eu
set +x                                   # never trace the token or the secret
export VAULT_ADDR="https://<vault-vip>:8200"
export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"
RELEASE='$[/myRelease/name]'

# 1) Log in with the plugin-minted JWT (sent via stdin, not argv)
VAULT_TOKEN=$(curl -sS --fail --cacert "$VAULT_CACERT" \
    -H "X-Vault-Namespace: $VAULT_NAMESPACE" -X POST --data @- \
    "$VAULT_ADDR/v1/auth/jwt-cdro/login" <<EOF |
{"role":"cdro-zerotrust","jwt":"$[/myJob/jwtToken]"}
EOF
    grep -o '"client_token":"[^"]*"' | head -1 | cut -d'"' -f4)

# 2) Read this release's secret (KV v2)
DB_PASS=$(curl -sS --fail --cacert "$VAULT_CACERT" \
    -H "X-Vault-Namespace: $VAULT_NAMESPACE" -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/cdr/${RELEASE}/db" \
    | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Fetched secret (length=${#DB_PASS}) — value not printed."

# 3) Clean up: revoke our own token
curl -sS --cacert "$VAULT_CACERT" -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
    -H "X-Vault-Token: $VAULT_TOKEN" -X POST \
    "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
```

### Tier 2 — native plugin (no external CLI)

The plugin can log in and read for you — no shell binaries. Three procedures cover it:

- **`UpdateCdroCredentialThroughJwtRequest`** — reads a KV secret and writes it into an existing
  CD/RO credential. Mapping rules:
  - **1 key/value pair** → `key` becomes the username, `value` becomes the password.
  - **2 pairs `{username,password}`** → mapped directly to the credential's username/password.
  - **more than 2 pairs** → the whole secret is stored as JSON in the password field.
- **`getCdroCredentialAndRunStep`** — stores the secret (as JSON) in the password of a credential
  **always named `zt_credential`**, then runs your shell / `ec-groovy` command, which reads it with
  `getFullCredential(credentialName:"zt_credential")`.
- **`getAuthorizedTokenAndRunStep`** — stores the **Vault-authorized token** (not the secret) in
  `zt_credential`, then runs your command (use it when your command calls Vault itself).

See [`cdro-zerotrust-native.dsl`](../vault-integrations/examples/cdro-zerotrust-native.dsl) for the
exact procedure DSL.

### Tier 3 — vault CLI + jq (advanced, scripted)

```bash
set -eu; set +x
export VAULT_ADDR="https://<vault-vip>:8200"; export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"
VAULT_TOKEN=$(vault write -field=token auth/jwt-cdro/login \
              role=cdro-zerotrust jwt="$[/myJob/jwtToken]")
export VAULT_TOKEN
DB_PASS=$(vault kv get -field=password "secret/cdr/$[/myRelease/name]/db")
echo "Fetched secret (length=${#DB_PASS}) — value not printed."
vault token revoke -self || true
```

> ⚠️ **Concurrency clobber (Pattern A limit).** `getCdroCredentialAndRunStep` /
> `UpdateCdroCredentialThroughJwtRequest` write into a **shared** CD/RO credential (e.g.
> `zt_credential`). Two runs from **different** releases/pipelines that share the same credential will
> **overwrite each other** — last write wins, so a run can read the *wrong* secret and fail auth.
> Give each release/pipeline its **own** credential, or serialize with resource locks. Concurrent runs
> of the **same** source (same secret) are safe.

**Step 5 — Hardening checklist**

- [ ] `set +x` around every step that touches the JWT or the secret; secret is never echoed.
- [ ] JWT passed via stdin (Tier 1) — never on the command line.
- [ ] Each release/pipeline uses its **own** CD/RO credential (avoids the clobber above).
- [ ] Token revoked (`revoke-self`) at the end, or left to expire in ≤ 15 min.

**Step 5 — Verify:** a run of release `payments-app` reads `secret/data/cdr/payments-app/db`; the same
role pointed at `secret/data/cdr/billing-app/db` returns **403 permission denied** (proves release scoping).

Next: hand a JWT to an external consumer (AAP) for dynamic secrets.

---

## Step 6 — Usage Pattern B: mint a JWT and hand it off (to AAP)

Sometimes CD/RO shouldn't read the secret itself — it should let a **downstream system** do its own
Vault exchange. The classic case is a dynamic secret (a just-in-time DB credential) that an **AAP**
job needs. CD/RO's KV-only limit is on *its own* reads; handing off the JWT lifts that limit for the
external consumer.

1. **Mint the JWT into a property** with the plugin's `IssueJwtAndStoreInProperty`, giving it the
   claims the consumer needs:

   ```
   IssueJwtAndStoreInProperty:
     configuration : vault-aut
     customClaims  : {"sub":"aap_job","aap_runner":"$[/myPipelineRuntime/runnerIps]"}
     property      : /myPipelineRuntime/jwtToken
   ```

2. **Pass it to AAP.** A downstream **AnsibleTower** plugin step launches the job template with the
   token as a parameter:

   ```
   AnsibleTower → Launch Job Template:
     extraVars : {"jwt":"$[/myPipelineRuntime/jwtToken]"}
   ```

3. **AAP exchanges the JWT itself.** The AAP agent logs in to Vault with that JWT (its own role,
   mount, and policy — including **dynamic** secrets) and uses the result. CD/RO never sees the secret.

> **Treat the property as sensitive.** The JWT is a bearer credential for those claims and TTL.
> Mark `/myPipelineRuntime/jwtToken` as a secure/masked property, never echo it, and scope its
> claims and `Token lifetime` as tightly as the job needs.

**Step 6 — Hardening checklist**

- [ ] The JWT property is marked secure/masked; not printed to logs.
- [ ] `customClaims` for the hand-off carries only what AAP needs (least privilege).
- [ ] `Token lifetime` for the hand-off token is as short as the downstream job allows.
- [ ] AAP's Vault role binds the same `aud` and the hand-off claims (its own guide covers the AAP side).

**Step 6 — Verify:** the AAP job authenticates to Vault with the handed-off JWT and resolves its
secret; the CD/RO job log contains **no** secret value, only the (masked) token reference.

Next: how to rotate the signing key safely.

---

## Step 7 — Manual key-rotation runbook

The plugin's signing key is **not** rotated automatically. Because Vault validates against a static
public key, rotation is a **coordinated, two-place** change — do it on a schedule and after any
suspected exposure.

1. **Generate a new asymmetric key pair** (same algorithm family, e.g. RS256) offline.
2. **Add the new public key to Vault first** (dual-trust window — Vault accepts *both* old and new):
   ```bash
   vault write auth/jwt-cdro/config \
       jwt_validation_pubkeys="$(cat zerotrust-pub-OLD.pem zerotrust-pub-NEW.pem)" \
       bound_issuer="ZeroTrust"
   ```
   *(`jwt_validation_pubkeys` accepts multiple PEMs — supply both during overlap.)*
3. **Swap the private key** in the CD/RO **Credential** referenced by the plugin configuration. New
   runs now sign with the new key; in-flight runs signed with the old key still validate.
4. **After all old tokens have expired** (≥ `Token lifetime`, i.e. ≥ 900 s), **remove the old public
   key** from Vault:
   ```bash
   vault write auth/jwt-cdro/config \
       jwt_validation_pubkeys=@zerotrust-pub-NEW.pem bound_issuer="ZeroTrust"
   ```

**Step 7 — Hardening checklist**

- [ ] Public key added to Vault **before** the private key is swapped (no outage).
- [ ] Old public key removed **after** the overlap window (no stale trust).
- [ ] Old private key destroyed once retired.
- [ ] Rotation logged / ticketed; ACL on the signing Credential re-confirmed.

**Step 7 — Verify:** during overlap, both old and new tokens log in; after cleanup, a token signed
with the **old** key is **rejected**.

Next: when you can't use the plugin — the fallback.

---

## Step 8 — Fallback: the CI broker (only when the plugin can't be used)

The direct ZeroTrust flow is the default. Keep the **CI-broker** pattern only for:

- environments where the ZeroTrust plugin isn't installed or approved yet, or
- a migration bridge while you roll the plugin out.

In the broker pattern CD/RO has no identity of its own: it triggers a CI job that reads the secret
using **CI's** OIDC identity and returns it response-wrapped. Vault's audit then attributes the read to
the **CI broker**, not CD/RO — the tradeoff you avoid by using the plugin. The full broker procedure
(trigger, wrap, unwrap) lives in the reference guide:
[`../vault-integrations/03-cdro-zerotrust-jwt.md`](../vault-integrations/03-cdro-zerotrust-jwt.md) §10.

---

## Step 9 — Verify (end to end)

- A **test** procedure mints a JWT; `inspect_jwt_claims.py` shows `iss=ZeroTrust`, an asymmetric
  `alg`, your `aud`, and `job_name=<release>`.
- `vault read auth/jwt-cdro/config` shows `bound_issuer=ZeroTrust`, a static pubkey, and **no**
  discovery URL.
- A run of release `payments-app` reads `secret/data/cdr/payments-app/db`; pointing the same role at
  another release's path returns **403** (release scoping holds).
- In your SIEM, the read shows the **CD/RO** identity (`user_claim=sub`) with policy
  `cdro-zerotrust-ro` — **not** a CI broker.
- Neither the CD/RO job log nor any property prints a secret value.
- Rotating the key (Step 7) works with no run failures during the overlap window.

Next: **[04 — Ansible Automation Platform](04-aap-approle-ssh.md)**.
