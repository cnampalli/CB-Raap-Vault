# 02 — CloudBees CI → Vault (per-build JWT)

Here you'll make a CloudBees CI build log into Vault **without any stored
credential**. Each build mints a short-lived signed token (a JWT), Vault checks
it, and hands back a token that expires in minutes.

**Your versions:** CloudBees CI Client Controller `2.528.3.35200-rolling`, OpenID
Connect Provider plugin `111.v29fd614b_3617`.

Do guide [01](01-vault-setup.md) first (the `jwt-ci` auth method must exist).

---

## Step 1 — Check the OIDC Provider plugin (and its security status)

On each controller: **Manage Jenkins → Plugins → Installed** → find **OpenID
Connect Provider** (`oidc-provider`).

**Good news on security:** your version `111.v29fd614b_3617` **is the fixed
version** for advisory **SECURITY-3574** (CVE-2025-47884, Critical — a flaw where
overridden environment variables could forge a build token). Affected versions are
`96.vee8ed882ec4d` **and earlier**; the fix shipped in exactly `111.v29fd614b_3617`.

- ✅ **You are safe on SECURITY-3574. No upgrade is required for security.**
- Upgrading later to the newest `212.v7657c4d7b_29f` is optional maintenance (it
  needs Jenkins core `2.541.3` — stage that first in an airgapped estate).
- Defense in depth regardless: restrict who can configure jobs / override
  environment variables, and keep the Vault role's audience/claims tight (Steps 4–5).

---

## Step 2 — Set each controller's Jenkins URL

The controller's URL becomes the JWT's `iss` (issuer) and the base of its OIDC
endpoints. It must be the **real external URL**.

**Manage Jenkins → System → Jenkins URL** → set e.g.
`https://ctrlA.ci.corp.example.com/`.

That gives you these endpoints:

```
Discovery : https://ctrlA.ci.corp.example.com/oidc/.well-known/openid-configuration
JWKS      : https://ctrlA.ci.corp.example.com/oidc/jwks
```

---

## Step 3 — Confirm Vault can reach the controller (firewall flow #1)

This is the #1 cause of mysterious JWT failures: Vault must reach the controller's
OIDC endpoints to validate builds' tokens. **Check it before configuring anything
in Vault.**

**Option A — the helper script** (run from a Vault node or an approved jump host):

```bash
python3 tools/check_oidc_discovery.py https://ctrlA.ci.corp.example.com --cacert /etc/pki/vault/ca.crt
```
Expected: `RESULT: OIDC discovery and JWKS are reachable and well-formed.` It also
prints the exact `issuer` value to use in the next step.

**Option B — plain curl** (same host):

```bash
curl -s https://ctrlA.ci.corp.example.com/oidc/.well-known/openid-configuration | grep jwks_uri
```
If this hangs or fails, flow #1 is not open — fix the firewall before continuing.

---

## Step 4 — Register the controller in Vault

Each controller is its own issuer, so give each **its own JWT mount** under `AUT`.
(You enabled the base `jwt-ci` method in guide 01; now add a per-controller mount.)

```bash
export VAULT_NAMESPACE=AUT

# One mount per controller — repeat for ctrlB, ctrlC, ...
vault auth enable -path=jwt-ci-ctrlA jwt

vault write auth/jwt-ci-ctrlA/config \
    oidc_discovery_url="https://ctrlA.ci.corp.example.com/oidc" \
    bound_issuer="https://ctrlA.ci.corp.example.com/oidc" \
    default_role="ci-build"
```

**Expected result:** `Success! Data written to: auth/jwt-ci-ctrlA/config`.

> Small fleet (2–10 controllers)? One mount each is clearest. For a large fleet,
> loop this in your self-service YAML instead of by hand.

---

## Step 5 — Inspect the JWT claims, then create the role

Before you bind a Vault role to the token, **look at what the token actually
contains**. The claims (`iss`, `aud`, `sub`, `job`) are what you bind to.

### 5a. See the claims

**Option A — from a build (in-pipeline):** run the example pipeline
[`Jenkinsfile.vault-oidc-nocli`](../vault-integrations/examples/Jenkinsfile.vault-oidc-nocli)
with its parameter **`PRINT_JWT = true`**. Its debug stage decodes and prints the
token **header + claims** (not the signature). It uses a `@NonCPS` base64url decoder
that needs no script approval.

**Option B — out of band:** capture one token and decode it on a jump host with the
helper (standard-library Python, no network, no signature check):

```bash
echo '<paste-the-JWT-here>' | python3 tools/inspect_jwt_claims.py
```

**Option C — run `inspect_jwt_claims.py` inside the pipeline.** Bind the credential with
`string(...)`, silence tracing with `set +x`, and feed the token via **stdin** (a heredoc, so it
never appears in the process list / `argv`):

```groovy
stage('Debug: inspect OIDC claims') {
  when { expression { params.PRINT_JWT } }        // keep it debug-gated
  steps {
    withCredentials([string(credentialsId: 'vault-oidc', variable: 'ID_TOKEN')]) {
      sh '''
        set +x
        python3 tools/inspect_jwt_claims.py <<EOF
$ID_TOKEN
EOF
      '''
    }
  }
}
```

> The `$ID_TOKEN` and `EOF` lines must sit at **column 0** (no indentation) — a shell heredoc
> ends only on a line that is exactly `EOF`. The tool prints the **decoded claims** (not the raw
> token) and needs no `pip install` (Python 3.6+, stdlib only).

The `sh` step runs on the **agent**, so the script must exist there. In an airgapped setup, pick
one: **(1)** bake `inspect_jwt_claims.py` into the agent image (reference it by absolute path);
**(2)** ship it via a Global Shared Library resource —
`writeFile file: 'inspect_jwt_claims.py', text: libraryResource('inspect_jwt_claims.py')` — then
run it; **(3)** rely on an SCM checkout that already contains `tools/`.

Either way you'll see something like:

```json
{
  "iss": "https://ctrlA.ci.corp.example.com/oidc",
  "aud": "vault-AUT",
  "sub": "https://ctrlA.ci.corp.example.com/oidc:job/AUT/payments/main",
  "job": "AUT/payments/main",
  "build_url": "https://ctrlA.ci.corp.example.com/job/AUT/job/payments/123/"
}
```

> **Security note:** a live JWT is a usable bearer credential until it expires.
> Inspect it privately and discard it — never leave one in a shared build log. The
> `PRINT_JWT` parameter is **off by default** for this reason. Decoding claims does
> **not** expose any secret; it just reveals the identity fields.

### 5b. Map claims → role

Now create the role, binding the claims you just saw:

```bash
vault write auth/jwt-ci-ctrlA/role/ci-build \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" \
    bound_claims='{"job":"AUT/payments/*"}' \
    claim_mappings='{"build_url":"build_url","job":"job"}' \
    token_policies="ci-secrets-ro,ci-ssh-sign" \
    token_ttl="15m" token_max_ttl="30m"
```

| Claim from the token | Role setting it maps to |
|---|---|
| `iss` | `bound_issuer` / `oidc_discovery_url` on the **mount** (Step 4) |
| `aud` = `vault-AUT` | `bound_audiences` (must match the CI credential's audience — Step 6) |
| `sub` | `user_claim` (the token's identity) |
| `job` = `AUT/payments/*` | `bound_claims` — **pin each role to a specific folder/job** |

**Expected result:** `Success! Data written to: auth/jwt-ci-ctrlA/role/ci-build`.

> Keep `bound_claims` narrow — one role per job/folder. Never ship a wildcard-all
> role.

---

## Step 6 — Create the CI credential that mints the token (JCasC)

Configure an OIDC ID-token credential whose **audience equals** the role's
`bound_audiences` (`vault-AUT`). Keeping it in JCasC makes it reproducible across
controllers.

```yaml
# casc/credentials.yaml
credentials:
  system:
    domainCredentials:
      - credentials:
          - idToken:                    # the JCasC symbol is `idToken` (a secret-text credential)
              scope: GLOBAL
              id: "vault-oidc"          # you reference this id in pipelines
              audience: "vault-AUT"      # MUST equal the Vault role bound_audiences
```

**Expected result:** after reloading configuration, a credential `vault-oidc`
appears under **Manage Jenkins → Credentials**.

---

## Step 6.5 — (Advanced) Project-scoped secrets from JWT claims

Instead of one Vault role per app, you can run **one role for every project** and let
Vault pick the secret path from the build's **own claims**. Each build then reads only:

```
secret/data/project/<group_name>/<job_name>/common/*
secret/data/project/<group_name>/<job_name>/ci/*
secret/data/project/<group_name>/<job_name>/*          # (this one already covers common/ + ci/)
```

where `<group_name>` and `<job_name>` come from claims **in that build's JWT**. This is
a "templated policy" — one policy definition, but each token only ever sees its own
project's path. Three pieces wire it together.

> If your KV mount is named something other than `secret` (e.g. `secrets`), use that
> name in the paths below.

### Background — CloudBees CI Folders (where the claim values come from)

New to Folders? Read this first — the whole feature hinges on it.

**What a Folder is.** A *Folder* is a container inside a CloudBees CI controller that groups
jobs together — like a directory in a filesystem. In a job path like `AUT/payments/main`,
`AUT` and `payments` are **folders** and `main` is the job. A folder is also a **scope**: its
**configuration, security (RBAC), credentials, and environment variables** are **inherited by
every job and subfolder inside it**. Set something once on the folder and everything within
gets it — no per-job editing.

**Folder environment variables.** A folder can define environment variables at
**Folder → Configure → Properties → Environment variables**. Every build of every job inside
that folder receives them automatically. Inheritance rules:
- A **subfolder overrides its parent folder** (the most specific value wins).
- **Global** environment variables (Manage Jenkins → System) **override folder** ones — so
  don't reuse a global variable name for a folder variable.

That is exactly how each build learns *which project it belongs to* without hard-coding
anything in the Jenkinsfile. The chain:

```
Folder AUT/payments  (Properties → Environment variables)
    VAULT_GROUP=payments   VAULT_JOB=main
        │  inherited by every job in the folder
        ▼
Build of AUT/payments/main starts → VAULT_GROUP / VAULT_JOB are in the build environment
        ▼
OIDC Provider claim templates use ${VAULT_GROUP} / ${VAULT_JOB}   [part (a)]
        →  JWT now carries  group_name=payments , job_name=main
        ▼
Vault role claim_mappings copy them to identity metadata          [part (b)]
        ▼
Templated policy resolves  secret/data/project/payments/main/*    [part (c)]
```

**Net effect:** *the folder a job lives in decides which secrets it can read* — move a job
into the `payments` folder and it automatically gets `payments` secrets, with no Vault or
pipeline change.

**Set it up (once per project folder):**
1. Open the folder (e.g. `AUT/payments`) → **Configure**.
2. **Properties** → enable **Environment variables** (CloudBees Folders Plus / Folder
   Properties).
3. Add `VAULT_GROUP = payments` and `VAULT_JOB = main` → **Save**.
4. Verify: run a job in that folder with a throwaway non-secret step `sh 'echo
   folder=$VAULT_GROUP'`, or run with `PRINT_JWT=true` and confirm `group_name`/`job_name`
   appear via `tools/inspect_jwt_claims.py`.

> **Security boundary:** because these values come from the folder, whoever holds **Configure**
> permission on the folder controls its group/job identity. Restrict folder configuration via
> folder RBAC — see the security note at the end of this section. (Reference: CloudBees docs →
> *Folder Properties* / *Folders Plus*.)

### (a) Make CI put `group_name` / `job_name` into the JWT

The OIDC Provider plugin only emits `iss, aud, iat, exp, sub, build_number` by default. You add
custom claims with **claim templates**, configured on the **global** Security page (Manage
Jenkins → Security → the OpenID Connect / ID Token section — it's a plugin-wide setting, not
per credential).

> ⚠️ **Use the "Build claim templates" list — not "Global claim templates."** The plugin has
> **three** lists, and they apply in different contexts:
>
> | List (UI label) | JCasC key | Included in the token… |
> |---|---|---|
> | Claim templates | `claimTemplates` | **always** |
> | Build claim templates | `buildClaimTemplates` | **only when minted inside a build** (your pipeline) |
> | Global claim templates | `globalClaimTemplates` | **only when minted outside a build** |
>
> Your JWT is minted **during a build**, so it uses `claimTemplates` + `buildClaimTemplates`
> and **ignores `globalClaimTemplates` entirely**. Putting `group_name` in the *Global* list is
> the #1 reason a custom claim goes missing while others still appear.

Add this JCasC (all your claims under **`buildClaimTemplates`**):

```yaml
# casc/jenkins.yaml  — global OIDC claim configuration (note: under `security:`)
security:
  idToken:
    tokenLifetime: 900               # seconds; keep short
    buildClaimTemplates:             # <-- Build list: applies to build-minted tokens
      - name: sub                    # REQUIRED — the plugin rejects config without a sub template
        format: "${JOB_URL}"         # use JOB_URL (per-build), NOT ${JENKINS_URL} (same for all builds)
        type: string
      - name: group_name             # your custom claim
        format: "${VAULT_GROUP}"     # resolves from a build/folder environment variable
        type: string
      - name: job_name               # your custom claim
        format: "${VAULT_JOB}"
        type: string
```

- `format` uses build-variable macros (`${VAR}`). You **cannot** name a standard claim
  (`iss, aud, exp, iat, nbf, jti, …`), and you **must** include a `sub` template.
- Make `sub` per-build (`${JOB_URL}`). `${JENKINS_URL}` is identical for every build, so it's
  useless as a subject and for Vault `bound_claims`.
- `${VAULT_GROUP}` / `${VAULT_JOB}` come from **folder environment variables** — see the
  **Background — CloudBees CI Folders** section just above for what those are and how to set
  them.
- If a custom claim is missing from the token, it's almost always in the wrong list (Global
  instead of Build) or a half-saved row — confirm with `inspect_jwt_claims.py` (below).

### (b) Map the claims into Vault alias metadata (role)

Add `claim_mappings` so Vault copies those claims onto the login's identity, where a
templated policy can read them. This replaces the per-app role from Step 5b:

```bash
vault write auth/jwt-ci-ctrlA/role/ci-build \
    role_type="jwt" user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" \
    bound_claims='{"sub":"https://ctrlA.ci.corp.example.com/*"}' \
    claim_mappings='{"group_name":"group_name","job_name":"job_name"}' \
    token_policies="ci-project-ro,ci-ssh-sign" \
    token_ttl="15m" token_max_ttl="30m"
```

> `claim_mappings` maps a **JWT claim → alias metadata key**. Every build using this
> role must carry `group_name` and `job_name`, or **login fails** with "claim not
> found" — so make sure the folder env vars are always set.

### (c) The templated policy

First get the **accessor** of this JWT mount (the templated path needs it):

```bash
export VAULT_NAMESPACE=AUT
vault auth list -detailed -format=json | grep -A3 '"jwt-ci-ctrlA/"'   # look for "accessor"
# or, simpler:
vault read -field=accessor sys/auth/jwt-ci-ctrlA    # -> e.g. auth_jwt_0a1b2c3d
```

Then write the policy, substituting that accessor for `<jwt-ci-accessor>`:

```bash
vault policy write ci-project-ro - <<'EOF'
# One policy for all projects — each token only resolves ITS OWN group/job path.
path "secret/data/project/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.group_name}}/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.job_name}}/*" {
  capabilities = ["read"]
}
# (optional) KV v2 metadata for the same subtree (version listing):
path "secret/metadata/project/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.group_name}}/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.job_name}}/*" {
  capabilities = ["read","list"]
}
EOF
```

- The single `.../<job_name>/*` rule **already covers** `common/*` and `ci/*` (and any
  other subtree under the job). If you want to allow **only** `common/` and `ci/` and
  nothing else, replace that one rule with two explicit rules ending in `/common/*` and
  `/ci/*`.

### (d) Verify it resolves

Run a build and inspect its token:

```bash
# In the pipeline (or via inspect_jwt_claims.py) confirm the JWT now carries the claims:
echo '<captured-JWT>' | python3 tools/inspect_jwt_claims.py     # should show group_name + job_name

# After logging in, from that build's token, a read of its own path works:
#   secret/data/project/<its group_name>/<its job_name>/ci/apikey   -> OK
# and a read of another group's path is denied (templated to its own claims only).
```

> **Security note (read this):** the `group_name`/`job_name` values come from the CI
> **folder environment variables**, so the real access boundary is *who can configure
> those folders*. Restrict folder configuration to trusted owners; a user who can set a
> folder's `VAULT_GROUP` could mint a token scoped to that group. Keep `bound_audiences`
> and the `sub` binding tight, and audit folder-property changes. The template itself is
> safe — a token can only ever read the path built from its **own** claims.

---

## Step 7 — Use it in a pipeline (pick ONE of three styles)

All three do the same thing: mint the JWT → exchange it for a Vault token → read a
secret → revoke the token. They differ only in **what must be present on the build
agent** — which matters in an airgapped image. Pick the row that matches what your
agents already have.

| Style | Needs on the agent | Needs as plugins | Example file |
|---|---|---|---|
| **A. curl** *(recommended for airgap)* | `curl` (+ `bash`) | OIDC Provider only | [`Jenkinsfile.vault-oidc-curl`](../vault-integrations/examples/Jenkinsfile.vault-oidc-curl) |
| **B. HTTP Request plugin** | *nothing* (no shell tools) | HTTP Request + OIDC Provider | [`Jenkinsfile.vault-oidc-nocli`](../vault-integrations/examples/Jenkinsfile.vault-oidc-nocli) |
| **C. vault CLI** | `vault` + `jq` (+ `bash`) | OIDC Provider only | [`Jenkinsfile.vault-oidc`](../vault-integrations/examples/Jenkinsfile.vault-oidc) |

> **On the typical baseline** (agents with `curl`, `jq`, `vault` 1.15.1, `openssh`, `bash`),
> **all three variants run as-is**; `vault` 1.15.1 against the 1.20.8+ent server is fine.
> Full per-component requirements + a "confirm on the agent image" checklist are in
> [00 — Before you begin §2.1](00-before-you-begin.md#21-software-requirements--compatibility-ci-agents--controllers).
>
> Adjust the `VAULT_JWT_PATH`/`VAULT_ROLE`/`VAULT_ADDR` env values at the top of the
> example to your mount (`jwt-ci-ctrlA`), role (`ci-build`), and Vault address.

### A — curl (Requirements: `curl` on the agent; OIDC Provider plugin)

The simplest airgapped option. The JWT is sent to Vault via **stdin** so it never
appears in the process list, and the token is parsed without `jq`:

```groovy
withCredentials([string(credentialsId: 'vault-oidc', variable: 'ID_TOKEN')]) {
  sh '''
    set -eu; set +x
    VAULT_TOKEN=$(curl -sS --fail --cacert "$VAULT_CACERT" \
        -H "X-Vault-Namespace: $VAULT_NAMESPACE" -X POST --data @- \
        "$VAULT_ADDR/v1/auth/jwt-ci-ctrlA/login" <<EOF |
{"role":"ci-build","jwt":"$ID_TOKEN"}
EOF
      grep -o '"client_token":"[^"]*"' | head -1 | cut -d'"' -f4)
    DB_PASS=$(curl -sS --fail --cacert "$VAULT_CACERT" \
        -H "X-Vault-Namespace: $VAULT_NAMESPACE" -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/ci/payments/db" \
      | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
    echo "Got secret (length=${#DB_PASS}) — value not printed."
  '''
}
```

See the full example (with self-revoke in `post`) in the linked file.

### B — HTTP Request plugin (Requirements: HTTP Request plugin; no shell tools)

Use when agents are minimal images without `curl`/`vault`. It calls Vault's HTTP
API via the `httpRequest` step and parses JSON with built-in Groovy
(`JsonSlurperClassic`), so it needs **no** Pipeline Utility Steps plugin. The token
header is set with `maskValue: true` and response bodies aren't logged. Full file:
[`Jenkinsfile.vault-oidc-nocli`](../vault-integrations/examples/Jenkinsfile.vault-oidc-nocli).

> One-time note: `JsonSlurperClassic` may need a single **Manage Jenkins →
> In-process Script Approval**, or run the pipeline from a trusted shared library.

### C — vault CLI (Requirements: `vault` + `jq` in the agent image)

Cleanest commands if your airgapped image already bundles the binaries. Full file:
[`Jenkinsfile.vault-oidc`](../vault-integrations/examples/Jenkinsfile.vault-oidc).

```groovy
withCredentials([string(credentialsId: 'vault-oidc', variable: 'ID_TOKEN')]) {
  sh '''
    set +x
    VAULT_TOKEN=$(vault write -field=token auth/jwt-ci-ctrlA/login role=ci-build jwt="$ID_TOKEN")
    export VAULT_TOKEN
    DB_PASS=$(vault kv get -field=password secret/ci/payments/db)
  '''
}
```

---

## Step 8 — (Optional) Sign an SSH cert and deploy

To reach a server, get a **short-lived signed SSH cert** instead of using a static
key (works with any of the three styles):

```groovy
sh '''
  set +x
  ssh-keygen -y -f "$KEY" > "$KEY.pub"
  vault write -field=signed_key ssh/sign/svc-ci \
      public_key=@"$KEY.pub" valid_principals="svc-ci" > "$KEY-cert.pub"
  ssh -i "$KEY" -o CertificateFile="$KEY-cert.pub" svc-ci@target.corp.example.com 'sudo systemctl restart myapp'
'''
```
The target node must trust the Vault SSH CA — that's set up by the AAP node-trust
playbook in guide [04](04-aap-approle-ssh.md).

---

## Step 9 — Hardening checklist

- [ ] OIDC Provider plugin `111.v29fd614b_3617` (✅ SECURITY-3574 fixed).
- [ ] Jenkins URL = real external URL on every controller (correct `iss`).
- [ ] Flow #1 verified (Vault → each `/oidc/**`) with `check_oidc_discovery.py`.
- [ ] Credential `audience` = role `bound_audiences` = `vault-AUT`.
- [ ] `bound_claims` pins each role to a specific job/folder — no wildcard-all role.
- [ ] Token TTLs 15/30 min; SSH cert ≤ 2 h.
- [ ] `set +x` / masking around secrets; `PRINT_JWT` stays **false** in normal runs.
- [ ] Restrict who can configure jobs / override env vars (SECURITY-3574 defense).

---

## Step 10 — Verify

```bash
# From a Vault node — discovery reachable:
python3 tools/check_oidc_discovery.py https://ctrlA.ci.corp.example.com --cacert /etc/pki/vault/ca.crt

# Run any of the three pipelines. In a debug build:
export VAULT_NAMESPACE=AUT
vault token lookup   # shows short TTL + policies ci-secrets-ro, ci-ssh-sign
```

If the pipeline logs `Vault login OK` and reads the secret length (never the value),
CI is done. Next: **[03 — CloudBees CD/RO](03-cloudbees-cdro.md)**.
