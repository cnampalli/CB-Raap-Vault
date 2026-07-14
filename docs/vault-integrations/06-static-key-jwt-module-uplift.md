# 06 — Uplift the `vault-enterprise-terraform` module for static-key JWT (CDRO)

> **Audience:** the CND team maintaining Prescient Solutions' `vault-enterprise-terraform` repo (v2.0).
> **Goal:** teach the reusable `vault-auth-jwt` module to validate a JWT against a **static public key**
> (`jwt_validation_pubkeys`) so **CloudBees CD/RO (CDRO)** can authenticate with its **ZeroTrust** plugin
> — which mints a locally-signed JWT (`iss=ZeroTrust`) and has **no OIDC-discovery / JWKS endpoint**.
> **Non-goal:** changing the existing OIDC providers (Jenkins CI, GitLab); they keep working unchanged.

This guide is the module-side companion to [`03-cdro-zerotrust-jwt.md`](03-cdro-zerotrust-jwt.md) (the
CDRO ZeroTrust integration) and [`../getting-started/03a-zerotrust-key-generation.md`](../getting-started/03a-zerotrust-key-generation.md)
(the signing key-pair runbook). It is written against the supplied v2.0 snapshot of the repo.

---

## 1. Why the current module can't do this

The `vault-auth-jwt` module hardwires **discovery-based** validation. Vault's JWT auth method accepts
exactly **one** trust root:

| Trust root | Field | Vault behavior | Fits CDRO? |
|---|---|---|---|
| OIDC discovery | `oidc_discovery_url` | Vault fetches `/.well-known/openid-configuration` → JWKS over the network | ❌ no endpoint |
| JWKS | `jwks_url` (+ `jwks_ca_pem`) | Vault fetches the JWKS over the network | ❌ no endpoint |
| **Static keys** | **`jwt_validation_pubkeys`** | Vault validates **offline** against pasted PEM(s) | ✅ **required** |

The module only wires the first one, so a discovery-less issuer like ZeroTrust cannot be expressed.

**Root-cause locations (v2.0 snapshot):**

| # | Concern | File |
|---|---|---|
| 1 | Backend always sets `oidc_discovery_url`; no static-key / JWKS attrs | `terraform/modules/vault-auth-jwt/main.tf` |
| 2 | `oidc_discovery_url` is a **required** var; role object lacks `role_type`/`bound_claims_type`/`token_max_ttl` | `terraform/modules/vault-auth-jwt/variables.tf` |
| 3 | Callers pass only `oidc_discovery_url` | `terraform/tower-namespaces/main.tf` (`module "jwt_auth"`), `terraform/root-namespace/main.tf` (`module "jwt_jenkins_ci"`) |
| 4 | Schema forces `required: [oidc_discovery_url, …]` | `configs/schemas/namespace-config-schema.yaml` |
| 5 | Validator errors when `oidc_discovery_url` missing | `tests/validate-yaml.py` (`_validate_auth_methods`) |
| 6 | CDRO provider misconfigured as OIDC (points at a non-existent discovery URL) | `configs/towers/cnd.yaml` (`auth_methods.jwt.cdro`) |

> **Provider version:** `hashicorp/vault` **3.23.0** (already pinned) supports `jwt_validation_pubkeys`,
> `jwks_url`, `jwt_supported_algs`, and role `role_type` / `bound_claims_type` / `token_max_ttl` /
> `bound_subject`. **No provider upgrade is required.**

---

## 2. Change #1 — the `vault-auth-jwt` module

The change is **backward-compatible**: existing callers that pass `oidc_discovery_url` behave exactly as
before; the new attributes default to unset/empty.

### 2.1 `terraform/modules/vault-auth-jwt/main.tf` (full replacement)

```hcl
resource "vault_jwt_auth_backend" "jwt" {
  namespace = var.namespace
  path      = var.path
  type      = "jwt"

  # Exactly one trust root is used per provider. oidc_discovery_url / jwks_url /
  # jwt_validation_pubkeys are mutually ConflictsWith in the Vault provider, and an
  # EMPTY LIST still counts as "configured" — so the unused list attrs must be null,
  # not []. Otherwise an existing OIDC provider errors with
  # "oidc_discovery_url conflicts with jwt_validation_pubkeys".
  oidc_discovery_url     = var.oidc_discovery_url
  jwks_url               = var.jwks_url
  jwks_ca_pem            = var.jwks_ca_pem
  jwt_validation_pubkeys = length(var.jwt_validation_pubkeys) > 0 ? var.jwt_validation_pubkeys : null
  jwt_supported_algs     = length(var.jwt_supported_algs) > 0 ? var.jwt_supported_algs : null
  bound_issuer           = var.bound_issuer

  lifecycle {
    precondition {
      condition = (
        var.oidc_discovery_url != null ||
        var.jwks_url != null ||
        length(var.jwt_validation_pubkeys) > 0
      )
      error_message = "Set exactly one JWT trust root: oidc_discovery_url, jwks_url, or jwt_validation_pubkeys."
    }
  }
}

resource "vault_jwt_auth_backend_role" "roles" {
  for_each = { for role in var.roles : role.role_name => role }

  namespace         = var.namespace
  backend           = vault_jwt_auth_backend.jwt.path
  role_name         = each.value.role_name
  role_type         = try(each.value.role_type, "jwt")            # JWT (not oidc) login flow
  bound_audiences   = each.value.bound_audiences
  bound_subject     = try(each.value.bound_subject, null)
  bound_claims      = try(each.value.bound_claims, {})
  bound_claims_type = try(each.value.bound_claims_type, "string") # "glob" for CDRO job_name: "*"
  claim_mappings    = try(each.value.claim_mappings, {})
  user_claim        = each.value.user_claim
  token_policies    = each.value.policies
  token_ttl         = each.value.ttl
  token_max_ttl     = try(each.value.token_max_ttl, each.value.ttl)
}
```

> **Gotcha — `ConflictsWith` + empty list.** `oidc_discovery_url`, `jwks_url`, and
> `jwt_validation_pubkeys` are mutually `ConflictsWith` in the Vault provider, and an **empty list still
> counts as "configured."** If the module passed `jwt_validation_pubkeys = var.jwt_validation_pubkeys`
> (default `[]`) directly, every existing **OIDC** provider would fail at plan/validate with
> `oidc_discovery_url conflicts with jwt_validation_pubkeys` — because it now has *both* a discovery URL
> and an (empty) pubkeys list. That is why the list trust roots above are coalesced to **`null`** when
> empty (`length(...) > 0 ? ... : null`). `null` means "unset"; `[]` does not.

### 2.2 `terraform/modules/vault-auth-jwt/variables.tf` (full replacement)

```hcl
variable "namespace" {
  description = "Vault namespace"
  type        = string
}

variable "path" {
  description = "Path to mount the JWT auth backend"
  type        = string
}

# --- Trust roots (set exactly one) -------------------------------------------

variable "oidc_discovery_url" {
  description = "OIDC discovery URL (dynamic validation). Leave null for static-key validation."
  type        = string
  default     = null
}

variable "jwks_url" {
  description = "JWKS URL (dynamic validation without full OIDC discovery). Optional."
  type        = string
  default     = null
}

variable "jwks_ca_pem" {
  description = "CA cert (PEM) used to validate the TLS connection to jwks_url. Optional."
  type        = string
  default     = null
}

variable "jwt_validation_pubkeys" {
  description = "Static public keys (PEM) used to validate JWT signatures offline. Used by discovery-less issuers such as the CDRO ZeroTrust plugin. Supply multiple PEMs during a key rotation overlap."
  type        = list(string)
  default     = []
}

variable "jwt_supported_algs" {
  description = "Signing algorithms Vault will accept (e.g. [\"RS256\"]). Recommended with static keys."
  type        = list(string)
  default     = []
}

# -----------------------------------------------------------------------------

variable "bound_issuer" {
  description = "Bound issuer for JWT validation (e.g. \"ZeroTrust\" for CDRO)"
  type        = string
}

variable "roles" {
  description = "JWT auth roles"
  type = list(object({
    role_name         = string
    bound_audiences   = list(string)
    bound_subject     = optional(string)
    bound_claims      = optional(map(string), {})
    bound_claims_type = optional(string, "string") # "string" (default) or "glob"
    claim_mappings    = optional(map(string), {})
    role_type         = optional(string, "jwt")
    user_claim        = string
    policies          = list(string)
    ttl               = number
    token_max_ttl     = optional(number)
  }))
}
```

> `outputs.tf` is unchanged.

**What each new knob buys CDRO**
- `jwt_validation_pubkeys` + `jwt_supported_algs` → offline validation of the ZeroTrust signature; **no
  network call to CDRO**.
- `role_type = "jwt"` → the direct JWT login flow (not the interactive OIDC flow).
- `bound_claims_type = "glob"` → lets the role require `job_name: "*"` (claim must be present; the
  templated policy path is what actually scopes each run to its release).
- `token_max_ttl` → pin the Vault token TTL to the short ZeroTrust `Token lifetime` (≤ 900 s).

---

## 3. Change #2 — the callers pass the new fields

Both callers gain `try(...)` pass-throughs. Existing OIDC providers are unaffected (they still supply
`oidc_discovery_url`).

### 3.1 `terraform/tower-namespaces/main.tf` — `module "jwt_auth"`

```hcl
module "jwt_auth" {
  source   = "../modules/vault-auth-jwt"
  for_each = try(local.tower_config.auth_methods.jwt, {})

  namespace              = var.tower_namespace
  path                   = "jwt/${each.key}"
  oidc_discovery_url     = try(each.value.oidc_discovery_url, null)
  jwks_url               = try(each.value.jwks_url, null)
  jwks_ca_pem            = try(each.value.jwks_ca_pem, null)
  jwt_validation_pubkeys = try(each.value.jwt_validation_pubkeys, [])
  jwt_supported_algs     = try(each.value.jwt_supported_algs, [])
  bound_issuer           = each.value.bound_issuer
  roles                  = each.value.roles

  depends_on = [module.namespace]
}
```

### 3.2 `terraform/root-namespace/main.tf` — `module "jwt_jenkins_ci"`

```hcl
module "jwt_jenkins_ci" {
  source = "../modules/vault-auth-jwt"
  count  = local.enable_jwt_jenkins_ci ? 1 : 0

  namespace              = "root"
  path                   = "jwt/jenkins-ci"
  oidc_discovery_url     = try(local.root_config.auth_methods.jwt_jenkins_ci.oidc_discovery_url, null)
  jwks_url               = try(local.root_config.auth_methods.jwt_jenkins_ci.jwks_url, null)
  jwks_ca_pem            = try(local.root_config.auth_methods.jwt_jenkins_ci.jwks_ca_pem, null)
  jwt_validation_pubkeys = try(local.root_config.auth_methods.jwt_jenkins_ci.jwt_validation_pubkeys, [])
  jwt_supported_algs     = try(local.root_config.auth_methods.jwt_jenkins_ci.jwt_supported_algs, [])
  bound_issuer           = local.root_config.auth_methods.jwt_jenkins_ci.bound_issuer

  roles = local.root_config.auth_methods.jwt_jenkins_ci.roles
}
```

---

## 4. Change #3 — the schema

`configs/schemas/namespace-config-schema.yaml`, `properties.auth_methods.properties.jwt` block — drop
`oidc_discovery_url` from `required`, add the new properties, and require **at least one** trust root via
`anyOf`:

```yaml
      jwt:
        type: object
        patternProperties:
          "^[a-z0-9-]+$":
            type: object
            required:
              - bound_issuer
              - roles
            anyOf:
              - required: [oidc_discovery_url]
              - required: [jwks_url]
              - required: [jwt_validation_pubkeys]
            properties:
              oidc_discovery_url:
                type: string
                format: uri
              jwks_url:
                type: string
                format: uri
              jwks_ca_pem:
                type: string
              jwt_validation_pubkeys:
                type: array
                items:
                  type: string
              jwt_supported_algs:
                type: array
                items:
                  type: string
              bound_issuer:
                type: string
              roles:
                type: array
                items:
                  type: object
```

---

## 5. Change #4 — the Python validator

`tests/validate-yaml.py`, JWT branch of `_validate_auth_methods` — require **one of** the three trust
roots instead of `oidc_discovery_url` specifically:

```python
        # Validate JWT
        if 'jwt' in methods:
            jwt = methods['jwt']
            if not isinstance(jwt, dict):
                self.errors.append("jwt auth methods must be a dictionary")
            else:
                trust_roots = ['oidc_discovery_url', 'jwks_url', 'jwt_validation_pubkeys']
                for provider_name, provider in jwt.items():
                    if not any(k in provider for k in trust_roots):
                        self.errors.append(
                            f"JWT provider '{provider_name}' must set one of: {', '.join(trust_roots)}")
                    if 'bound_issuer' not in provider:
                        self.errors.append(f"JWT provider '{provider_name}' missing 'bound_issuer'")
                    if not provider.get('roles'):
                        self.warnings.append(f"JWT provider '{provider_name}' has no roles")
```

> **Unrelated pre-existing bug spotted while editing:** the namespace-format check reads
> `re.match(r'^[a-z0-9-]+, namespace)` — the pattern is missing its closing `$'`. It should be
> `re.match(r'^[a-z0-9-]+$', namespace)`. Out of scope for this uplift; flag it to the team separately.

---

## 6. Change #5 — fix `cnd.yaml` to use static keys

`configs/towers/cnd.yaml`, replace the `auth_methods.jwt.cdro` block. The public key is **not secret**
and is safe to commit inline — consistent with how this repo already inlines Kubernetes CA certs and SSH
CA public keys.

**Before (broken — points at a discovery URL that doesn't exist):**
```yaml
    cdro:
      oidc_discovery_url: "https://cdro.prescient-solutions.internal/.well-known/openid-configuration"
      bound_issuer: "https://cdro.prescient-solutions.internal"
      roles:
        - role_name: "release-pipeline"
          bound_audiences: ["https://vault.prescient-solutions.internal:8200"]
          claim_mappings:
            job_name: "release_name"
            group_name: "project"
          user_claim: "sub"
          ttl: 3600
          enable_pki: true
```

**After (static key — matches how the ZeroTrust plugin actually signs):**
```yaml
    cdro:
      # CDRO ZeroTrust plugin mints a locally-signed JWT (iss=ZeroTrust); no OIDC discovery endpoint.
      bound_issuer: "ZeroTrust"
      jwt_supported_algs: ["RS256"]          # match the plugin Algorithm (confirm from a decoded token)
      jwt_validation_pubkeys:
        - |
          -----BEGIN PUBLIC KEY-----
          <paste zerotrust-pub.pem — the public half of the plugin's signing Credential>
          -----END PUBLIC KEY-----
      roles:
        - role_name: "release-pipeline"
          role_type: "jwt"
          bound_audiences: ["https://vault.prescient-solutions.internal:8200"]  # == plugin customClaims aud
          bound_claims_type: "glob"
          bound_claims:
            job_name: "*"
          claim_mappings:
            job_name: "release_name"
            project: "project"
          user_claim: "sub"
          ttl: 900
          token_max_ttl: 900
          enable_pki: true
```

> **Confirm two values from a real decoded token** (see [`03-cdro-zerotrust-jwt.md`](03-cdro-zerotrust-jwt.md)
> §1–§2): the exact `aud` → `bound_audiences`, and the exact `alg` + public-key PEM →
> `jwt_supported_algs` + `jwt_validation_pubkeys`. Until then treat **RS256 / RSA-3072** as the placeholder;
> generate the pair with [`../getting-started/03a-zerotrust-key-generation.md`](../getting-started/03a-zerotrust-key-generation.md)
> (`openssl`, airgap-safe). Decode a captured token with [`../../tools/inspect_jwt_claims.py`](../../tools/inspect_jwt_claims.py).

> **Note on `claim_mappings` typing:** the module passes `claim_mappings` as `map(string)`, so keep the
> existing `job_name → release_name` / `project → project` mappings flat. The `enable_pki: true` flag is
> consumed by the existing `jwt_pipeline_policies` for_each in `tower-namespaces/main.tf`, unchanged.

---

## 7. Apply, verify, roll back

### 7.1 Static checks (no Vault needed)
```bash
# From the repo root
./scripts/validate-config.sh                 # cnd.yaml passes with the static-key cdro block
python3 tests/validate-yaml.py               # "must set one of: …" no longer fires for cdro

cd terraform/tower-namespaces
terraform init
terraform fmt -check -recursive
terraform validate
```

### 7.2 Plan — confirm no OIDC regression
```bash
terraform plan \
  -var="tower_namespace=cnd" \
  -var="tower_name=cnd" \
  -var="jenkins_jwt_token=$ID_TOKEN" \
  -var="ldap_bindpass=$LDAP_BINDPASS"
```
Expect: `module.jwt_auth["cdro"]` creates `jwt/cdro` with `jwt_validation_pubkeys` set and **no**
`oidc_discovery_url`; `module.jwt_auth["gitlab"]` (OIDC) shows **no change** to its trust root.

### 7.3 Apply, then assert on the Vault side (namespace `cnd`)
```bash
export VAULT_NAMESPACE=cnd
vault read auth/jwt/cdro/config
#   bound_issuer         = ZeroTrust
#   jwt_validation_pubkeys = [ -----BEGIN PUBLIC KEY----- … ]
#   oidc_discovery_url   = (empty)         <-- no discovery
vault read auth/jwt/cdro/role/release-pipeline
#   role_type = jwt, bound_audiences, bound_claims_type = glob, claim_mappings present
```

### 7.4 End-to-end login
```bash
# 1) Mint a ZeroTrust JWT from a test CDRO procedure, then decode it (offline, no signature check):
python3 tools/inspect_jwt_claims.py <<'EOF'
<paste the eyJ… token>
EOF
#   header alg == RS256 (or your alg); iss = ZeroTrust; aud == bound_audiences; job_name = <release>

# 2) Exchange it for a Vault token:
curl -sS --fail -H "X-Vault-Namespace: cnd" -X POST --data @- \
  "$VAULT_ADDR/v1/auth/jwt/cdro/login" <<EOF
{"role":"release-pipeline","jwt":"<token>"}
EOF
#   -> returns a client_token carrying the release-pipeline policy
```
A token signed by any **other** key is **rejected** (signature mismatch) — the offline-validation proof.

### 7.5 Regression
A Jenkins CI login (`root` namespace, `jwt/jenkins-ci`) and a GitLab login (`cnd`, `jwt/gitlab`) still
succeed unchanged.

### 7.6 Rollback
Config-only, no state migration needed (the `jwt/cdro` mount is newly created): restore the previous
`cdro` block (or `terraform destroy -target=module.jwt_auth["cdro"]`) and revert the module. Existing
OIDC providers are untouched throughout.

### 7.7 Key rotation
`jwt_validation_pubkeys` accepts **multiple** PEMs. To rotate: add the NEW public key alongside the OLD
(`jwt_validation_pubkeys: [OLD, NEW]`) → apply → swap the private key in the CDRO Credential → after the
`Token lifetime` overlap (≥ 900 s), drop the OLD key → apply. This mirrors
[`03-cdro-zerotrust-jwt.md`](03-cdro-zerotrust-jwt.md) §7.

---

## 8. Change summary

| File | Change |
|---|---|
| `terraform/modules/vault-auth-jwt/main.tf` | Add `jwks_url` / `jwks_ca_pem` / `jwt_validation_pubkeys` / `jwt_supported_algs` to the backend + a one-trust-root precondition; add `role_type` / `bound_subject` / `bound_claims_type` / `token_max_ttl` to the role |
| `terraform/modules/vault-auth-jwt/variables.tf` | `oidc_discovery_url` → optional; add the four backend vars; extend the `roles` object with the four optional role fields |
| `terraform/tower-namespaces/main.tf` | `module "jwt_auth"` passes the new fields via `try(...)` |
| `terraform/root-namespace/main.tf` | `module "jwt_jenkins_ci"` passes the new fields via `try(...)` |
| `configs/schemas/namespace-config-schema.yaml` | JWT block: `anyOf` trust root + new properties |
| `tests/validate-yaml.py` | JWT branch: require one-of trust roots, not `oidc_discovery_url` |
| `configs/towers/cnd.yaml` | `jwt.cdro` converted from OIDC to static-key (ZeroTrust) |

Net effect: the module now speaks **both** dynamic (OIDC/JWKS) and **static** (`jwt_validation_pubkeys`)
JWT validation, so CDRO's discovery-less ZeroTrust JWT is a first-class, schema-validated config — with
zero change to the existing OIDC providers.
