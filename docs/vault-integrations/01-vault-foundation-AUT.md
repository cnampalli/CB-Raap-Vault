# 01 — Vault Foundation: the `AUT` Namespace

> Prereqs: Vault Enterprise cluster (VMs, Raft, 1.20.8+ent) healthy and unsealed; you can reach the API at
> `https://<vault-vip>:8200`. All paths below are **inside namespace `AUT`** (`-namespace=AUT` / header
> `X-Vault-Namespace: AUT`).
>
> **Ownership:** the **Vault team** creates `AUT` and applies everything here. The **Automation team**
> authors these definitions as **YAML** and submits them via **pull request** to the Vault self-service
> repo. The YAML below is **representative** — reshape it to the Vault team's schema once shared
> (tracked as an open follow-up). Terraform equivalents are provided so both sides are unambiguous.

---

## 1. Create the namespace (Vault team)

```bash
# Run in the parent (admin) namespace
vault namespace create AUT
```

Terraform:
```hcl
resource "vault_namespace" "aut" {
  path = "AUT"
}
```

Delegate day-2 config to the AUT self-service flow (PR-applied). No root token is used for ongoing changes.

---

## 2. Audit device → SIEM

Stream all requests/responses to the SIEM via syslog (in addition to any file device).

```bash
vault audit enable -namespace=AUT syslog \
    tag="vault-AUT" facility="AUTH" \
    log_raw=false
```

> `log_raw=false` keeps secret values HMAC'd in the audit log. Point the host syslog/`rsyslog` forwarder
> at the SIEM collector (firewall flow #9). If your SIEM ingests via a socket/file device instead, mount
> that device here.

---

## 3. Secrets engines

### 3.1 KV v2 — static app secrets

```bash
vault secrets enable -namespace=AUT -path=secret -version=2 kv
```

Path convention:
```
secret/data/ci/<app>/<name>
secret/data/cdr/<release>/<name>  # CDRO reads its own release path (ZeroTrust direct JWT)
secret/data/aap/<app>/<name>
```

### 3.2 SSH secrets engine — CA for signed client certs

```bash
vault secrets enable -namespace=AUT -path=ssh ssh
vault write   -namespace=AUT ssh/config/ca generate_signing_key=true
# Publish the CA public key (managed nodes will trust this):
vault read    -namespace=AUT -field=public_key ssh/config/ca
```

Roles — one dedicated service principal per platform:

```bash
# CI deploys
vault write -namespace=AUT ssh/roles/svc-ci \
    key_type=ca allow_user_certificates=true \
    allowed_users="svc-ci" default_user="svc-ci" \
    allowed_extensions="permit-pty,permit-port-forwarding" \
    default_extensions='{"permit-pty":""}' \
    ttl="1h" max_ttl="2h"

# AAP managed-node access
vault write -namespace=AUT ssh/roles/svc-aap \
    key_type=ca allow_user_certificates=true \
    allowed_users="svc-aap" default_user="svc-aap" \
    allowed_extensions="permit-pty" \
    default_extensions='{"permit-pty":""}' \
    ttl="1h" max_ttl="2h"
```

---

## 4. Auth methods

### 4.1 `jwt-ci` — CloudBees CI OIDC (per-build JWT)

```bash
vault auth enable -namespace=AUT -path=jwt-ci jwt
```

Each CI controller is a distinct OIDC issuer. Because the `jwt` config takes a single
`oidc_discovery_url`, register **one mount per controller** *or* use `bound_issuer` per role with a shared
`jwks_url` set. The cleanest for 2–10 controllers: **one mount per controller** (e.g. `jwt-ci-ctrlA`),
each pointing at that controller's discovery URL. See `02-cloudbees-ci-oidc.md` for the full per-controller
config and roles. Minimal shape:

```bash
vault write -namespace=AUT auth/jwt-ci/config \
    oidc_discovery_url="https://<ci-ctrl>/oidc" \
    bound_issuer="https://<ci-ctrl>/oidc"
```

### 4.1a `jwt-cdro` — CloudBees CDRO ZeroTrust plugin (locally-signed JWT)

CDRO's **ZeroTrust** plugin (`v1.0`) signs a JWT locally (`iss=ZeroTrust`) inside a procedure step.
Unlike CI, there is **no OIDC discovery/JWKS endpoint** — Vault validates against a **static public
key**. See `03-cdro-zerotrust-jwt.md` for the plugin details, role, and usage patterns.

```bash
vault auth enable -namespace=AUT -path=jwt-cdro jwt
vault write -namespace=AUT auth/jwt-cdro/config \
    jwt_validation_pubkeys=@/etc/pki/vault/zerotrust-pub.pem \
    bound_issuer="ZeroTrust"
# NO oidc_discovery_url / jwks_url — offline static-key validation.
```

> `zerotrust-pub.pem` is the public half of the plugin's signing Credential. Supply multiple PEMs during
> a rotation overlap. The role (`cdro-zerotrust`) and its release-scoped policy are in
> `03-cdro-zerotrust-jwt.md` §3–§4 and §5.4 below.

### 4.2 `approle` — AAP login (primary; hardened)

AAP 2.4 has no native OIDC, so it logs in with a **hardened AppRole**. See
`../getting-started/04-aap-approle-ssh.md` for the end-to-end AAP-side setup and the response-wrapped
`secret_id` delivery.

```bash
vault auth enable -namespace=AUT approle

vault write -namespace=AUT auth/approle/role/aap-automation \
    token_policies="aap-kv-read,aap-ssh-sign" \
    token_ttl="20m" token_max_ttl="30m" token_type="service" \
    token_bound_cidrs="10.20.0.0/24" \
    secret_id_ttl="10m" secret_id_num_uses="1" \
    secret_id_bound_cidrs="10.20.0.0/24" \
    bind_secret_id=true
```

> Hardening rationale: `secret_id_num_uses=1` (single-use), `secret_id_ttl=10m` (short), the two
> `*_bound_cidrs` pin both the `secret_id` and resulting token to AAP host IPs (replace `10.20.0.0/24`),
> and delivery is **response-wrapped** (`-wrap-ttl`, see guide 04). No `secret_id` is ever stored in git.

### 4.3 `cert-aap` — AAP mTLS (AD CS-issued client certs) — *alternative*

Retained as a documented alternative to AppRole (e.g. if you already operate automated AD CS
enrollment/renewal). AppRole (§4.2) is the primary method because it avoids that PKI-automation dependency.

```bash
vault auth enable -namespace=AUT -path=cert-aap cert

# Trust the AD CS chain and bind to AAP's client cert identity
vault write -namespace=AUT auth/cert-aap/certs/aap \
    display_name="aap" \
    certificate=@adcs-chain.pem \
    allowed_common_names="aap-*.corp.example.com" \
    token_policies="aap-ssh-sign,aap-kv-read" \
    token_ttl="15m" token_max_ttl="30m"
```

> Replace `adcs-chain.pem` with your AD CS issuing-CA (and root) public certificate(s). Tighten
> `allowed_common_names` (or use `allowed_dns_sans`) to exactly the AAP controller/EE cert names.
> **Venafi note:** when AD CS is replaced by Venafi, only this trust anchor + `allowed_*` bindings change;
> roles/policies stay the same.

---

## 5. Policies

### 5.1 CI — KV read + SSH sign

`ci-secrets-ro` and `ci-ssh-sign` (attach via the CI JWT role):

```hcl
# ci-secrets-ro.hcl  (templated by claim so each app reads only its own path)
path "secret/data/ci/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.app}}/*" {
  capabilities = ["read"]
}
```
```hcl
# ci-ssh-sign.hcl
path "ssh/sign/svc-ci" {
  capabilities = ["update"]
}
```

**Optional — project-scoped by claim (`ci-project-ro`).** One policy serves every project; each token
only resolves its **own** `group_name`/`job_name` path (populated via the role's `claim_mappings` and the
OIDC claim templates — see `02-cloudbees-ci-oidc.md` §4.1). Substitute the real mount accessor for
`<jwt-ci-accessor>` (`vault auth list -detailed`):

```hcl
# ci-project-ro.hcl
path "secret/data/project/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.group_name}}/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.job_name}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/project/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.group_name}}/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.job_name}}/*" {
  capabilities = ["read", "list"]
}
```
> The trailing `/*` already subsumes `.../common/*` and `.../ci/*`. Enumerate those two explicitly only if
> you need to *exclude* other subtrees under `job_name`.

### 5.2 AAP — KV read + SSH sign

```hcl
# aap-kv-read.hcl
path "secret/data/aap/*" {
  capabilities = ["read"]
}
```
```hcl
# aap-ssh-sign.hcl
path "ssh/sign/svc-aap" {
  capabilities = ["update"]
}
```

### 5.3 CDRO broker — read + response-wrap (attached to the CI **broker** role) — *fallback only*

Used only when the ZeroTrust plugin can't be used (see §5.4 for the primary CDRO policy).

```hcl
# cdro-broker.hcl
path "secret/data/cdr/*" {
  capabilities = ["read"]
}
# allow issuing dynamic DB creds if/when a database engine is added:
# path "database/creds/cdr-*" { capabilities = ["read"] }
```
> Response-wrapping is requested by the **client** (the broker job sends `-wrap-ttl`); no special policy
> capability is required beyond `read` on the target path.

### 5.4 CDRO ZeroTrust — KV v2 read-only, release-scoped (primary; attached to `cdro-zerotrust`)

Templated by the release claim (via the role's `claim_mappings`, see `03-cdro-zerotrust-jwt.md` §3), so
each run reads **only** its own release. Substitute the real `jwt-cdro` mount accessor
(`vault auth list -detailed`) for `<jwt-cdro-accessor>`:

```hcl
# cdro-zerotrust-ro.hcl
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}
```
> **KV v2 read-only** — no write/dynamic/SSH capabilities on the CDRO role. Dynamic secrets are reached
> externally via the plugin's mint-and-hand-off (Pattern B).

---

## 6. Representative self-service YAML (PR to Vault repo)

> **Shape is illustrative** — conform to the Vault team's schema before submitting. It captures the same
> logical config as §2–§5 so the mapping is mechanical.

```yaml
# aut-vault-config.yaml
namespace: AUT

audit:
  - type: syslog
    options: { tag: "vault-AUT", facility: "AUTH", log_raw: "false" }

secrets_engines:
  - path: secret
    type: kv
    options: { version: "2" }
  - path: ssh
    type: ssh
    ca: { generate_signing_key: true }
    roles:
      - name: svc-ci
        key_type: ca
        allow_user_certificates: true
        allowed_users: "svc-ci"
        default_user: "svc-ci"
        default_extensions: { permit-pty: "" }
        allowed_extensions: "permit-pty,permit-port-forwarding"
        ttl: "1h"
        max_ttl: "2h"
      - name: svc-aap
        key_type: ca
        allow_user_certificates: true
        allowed_users: "svc-aap"
        default_user: "svc-aap"
        default_extensions: { permit-pty: "" }
        ttl: "1h"
        max_ttl: "2h"

auth_methods:
  - path: jwt-ci
    type: jwt
    # one block per controller — see 02-cloudbees-ci-oidc.md
    config: { oidc_discovery_url: "https://<ci-ctrl>/oidc", bound_issuer: "https://<ci-ctrl>/oidc" }
    roles: []            # defined in guide 02
  - path: jwt-cdro
    type: jwt
    # CDRO ZeroTrust plugin — static pubkey, NO discovery url — see 03-cdro-zerotrust-jwt.md
    config: { bound_issuer: "ZeroTrust", jwt_validation_pubkeys_file: "zerotrust-pub.pem" }
    roles:
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
  - path: cert-aap
    type: cert
    certs:
      - name: aap
        certificate_file: adcs-chain.pem
        allowed_common_names: "aap-*.corp.example.com"
        token_policies: ["aap-ssh-sign", "aap-kv-read"]
        token_ttl: "15m"
        token_max_ttl: "30m"

policies:
  - name: ci-secrets-ro   ; file: policies/ci-secrets-ro.hcl
  - name: ci-ssh-sign     ; file: policies/ci-ssh-sign.hcl
  - name: aap-kv-read     ; file: policies/aap-kv-read.hcl
  - name: aap-ssh-sign    ; file: policies/aap-ssh-sign.hcl
  - name: cdro-zerotrust-ro ; file: policies/cdro-zerotrust-ro.hcl   # primary CDRO policy
  - name: cdro-broker     ; file: policies/cdro-broker.hcl           # fallback (CI broker) only
```

---

## 7. Terraform equivalent (if the pipeline is YAML→TF)

```hcl
provider "vault" { namespace = "AUT" }   # provider authenticates via the team's OIDC/CI flow

resource "vault_audit" "syslog" {
  type    = "syslog"
  options = { tag = "vault-AUT", facility = "AUTH", log_raw = "false" }
}

resource "vault_mount" "kv" {
  path = "secret"; type = "kv"; options = { version = "2" }
}

resource "vault_mount" "ssh" { path = "ssh"; type = "ssh" }
resource "vault_ssh_secret_backend_ca" "ssh" { backend = vault_mount.ssh.path; generate_signing_key = true }

resource "vault_ssh_secret_backend_role" "svc_ci" {
  backend = vault_mount.ssh.path
  name    = "svc-ci"
  key_type = "ca"
  allow_user_certificates = true
  allowed_users = "svc-ci"; default_user = "svc-ci"
  default_extensions = { permit-pty = "" }
  allowed_extensions = "permit-pty,permit-port-forwarding"
  ttl = "3600"; max_ttl = "7200"
}
# svc_aap analogous …

resource "vault_jwt_auth_backend" "jwt_ci" {
  path = "jwt-ci"; type = "jwt"
  oidc_discovery_url = "https://<ci-ctrl>/oidc"
  bound_issuer       = "https://<ci-ctrl>/oidc"
}

resource "vault_jwt_auth_backend" "jwt_cdro" {
  path                   = "jwt-cdro"; type = "jwt"
  bound_issuer           = "ZeroTrust"
  jwt_validation_pubkeys = [file("/etc/pki/vault/zerotrust-pub.pem")]  # static key; no discovery url
}

resource "vault_jwt_auth_backend_role" "cdro_zerotrust" {
  backend           = vault_jwt_auth_backend.jwt_cdro.path
  role_name         = "cdro-zerotrust"
  role_type         = "jwt"
  user_claim        = "sub"
  bound_audiences   = ["vault-AUT"]        # == the token's aud (confirm from a decoded token)
  bound_claims_type = "glob"
  bound_claims      = { job_name = "*" }
  claim_mappings    = { job_name = "release" }
  token_policies    = ["cdro-zerotrust-ro"]
  token_ttl         = 900; token_max_ttl = 900
}

resource "vault_cert_auth_backend_role" "aap" {
  backend  = "cert-aap"
  name     = "aap"
  certificate = file("adcs-chain.pem")
  allowed_common_names = ["aap-*.corp.example.com"]
  token_policies = ["aap-ssh-sign", "aap-kv-read"]
  token_ttl = 900; token_max_ttl = 1800
}
```

---

## 8. Verification

```bash
export VAULT_NAMESPACE=AUT
vault audit list                       # syslog device present
vault secrets list                     # secret/ (kv v2), ssh/ present
vault auth list                        # jwt-ci/, jwt-cdro/, approle/ present (cert-aap/ if using the alternative)
vault read ssh/config/ca               # CA public key returned (nodes will trust this)
vault policy list                      # ci-*, aap-*, cdro-zerotrust-ro, cdro-broker present
```

Then proceed to guide `02` (CI), `03` (CDRO), `04` (AAP), which add the roles that bind identities to
these policies.
