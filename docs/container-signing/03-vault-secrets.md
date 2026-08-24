# 03 — Vault Enterprise: Secrets for the Signing Pipeline

> **Prereqs:** Vault Enterprise reachable at `https://<vault-vip>:8200`, namespace **`AUT`** established
> per `../vault-integrations/01-vault-foundation-AUT.md`. CloudBees CI OIDC provider configured per
> `../vault-integrations/02-cloudbees-ci-oidc.md`. All paths below are **inside namespace `AUT`**.
>
> **Ownership:** the **Vault team** applies. **CI engineering** authors these definitions as YAML and
> submits them by **pull request** to the Vault self-service repo — the same flow as the existing Vault
> integration guides. The YAML here is representative; reshape to the Vault team's schema.

---

## 1. What actually needs to be a secret

Be deliberate — over-vaulting adds failure modes without adding security.

| Item | Secret? | Where it lives |
|---|---|---|
| Harbor robot account token | **Yes** | KV v2 |
| Prisma Console service credential | **Yes** | KV v2 |
| Venafi service account password | **Yes — Option A only** | KV v2; **eliminated entirely by Option B** |
| Venafi signing key | **No — never leaves TPP** | CodeSign Protect Secret Store |
| PKCS#11 key URI | No — configuration | Jenkinsfile / folder property |
| PKCS#11 `pin-value` | See `02 §7` | Placeholder if confirmed; else KV v2 |
| Venafi code-signing **public** key | No — but integrity-critical | Git (signed commits) or KV v2 |
| TPP CA bundle | No | Agent image |

> The headline: **the signing key is not in Vault, because it is not anywhere except TPP.** Vault brokers
> access to *services*, not to key material. If someone proposes putting a signing key in Vault
> `transit` or KV "for convenience", that defeats the entire control this project exists to establish.

---

## 2. Secret paths

Follow the existing convention (`secret/data/ci/<app>/<name>`):

```
secret/data/ci/container-signing/harbor-robot        # username, token
secret/data/ci/container-signing/prisma              # username, password (or access key/secret)
secret/data/ci/container-signing/venafi              # username, password   [Option A only]
secret/data/ci/container-signing/pkcs11              # pin                  [only if a real PIN is required]
```

Write them (Vault team, or via the self-service pipeline):

```bash
export VAULT_NAMESPACE=AUT

vault kv put secret/ci/container-signing/harbor-robot \
    username='robot$container-build+ci' \
    token='<harbor-robot-token>'

vault kv put secret/ci/container-signing/prisma \
    username='<prisma-svc-user>' \
    password='<prisma-svc-password>'

# Option A only — omit entirely when using JWT Mapping (01 §6.3)
vault kv put secret/ci/container-signing/venafi \
    username='svc-container-signer' \
    password='<password>'
```

---

## 3. Policy — read-only, path-scoped

```hcl
# policy: ci-container-signing-ro
path "secret/data/ci/container-signing/*" {
  capabilities = ["read"]
}

path "secret/metadata/ci/container-signing/*" {
  capabilities = ["read", "list"]
}
```

Apply:

```bash
vault policy write -namespace=AUT ci-container-signing-ro ci-container-signing-ro.hcl
```

> Scope to `ci/container-signing/*` only. Do **not** attach the broader templated `ci-secrets-ro` policy
> from guide `01` to the signing role — the signing job is the most privileged job in the estate and
> should read the least.

---

## 4. JWT auth role for the signing job

Extends the per-controller mounts (`jwt-ci-ctrlA`, `jwt-ci-ctrlB`, …) already established:

```bash
export VAULT_NAMESPACE=AUT

vault write auth/jwt-ci-ctrlA/role/container-signing \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" \
    bound_claims='{"job":"AUT/platform/container-signing/*"}' \
    claim_mappings='{"build_url":"build_url","job":"job"}' \
    token_policies="ci-container-signing-ro" \
    token_ttl="15m" token_max_ttl="30m"
```

Self-service YAML fragment:

```yaml
auth_methods:
  - path: jwt-ci-ctrlA
    type: jwt
    roles:
      - name: container-signing
        role_type: jwt
        user_claim: sub
        bound_audiences: ["vault-AUT"]
        bound_claims_type: glob
        bound_claims: { job: "AUT/platform/container-signing/*" }
        token_policies: ["ci-container-signing-ro"]
        token_ttl: "15m"
        token_max_ttl: "30m"
```

> **`bound_claims` on `job` is the load-bearing control.** Without it, any job on that controller can
> mint a token that reads the signing secrets and reach the signing agent's capabilities. Bind tightly
> to the signing job's folder path and review it whenever the folder structure changes.

Repeat per controller. Token TTL of 15m comfortably exceeds a build; there is no case for longer.

---

## 5. Two audiences — Vault and Venafi

If you adopt the JWT Mapping approach in `01 §6.3`, the pipeline mints **two** ID tokens with **different
audiences**:

| Credential ID | Audience | Consumer |
|---|---|---|
| `vault-oidc` | `vault-AUT` | Vault JWT auth (`bound_audiences`) |
| `venafi-oidc` | `venafi-codesign` | TPP JWT Mapping |

```yaml
# casc/credentials.yaml — add alongside the existing vault-oidc credential
credentials:
  system:
    domainCredentials:
      - credentials:
          - idToken:
              scope: GLOBAL
              id: "venafi-oidc"
              audience: "venafi-codesign"     # must equal the TPP JWT Mapping audience
```

> **Do not reuse one token for both.** Audience separation is what stops a token minted for Vault from
> being replayed against the signing service, and vice versa. This costs nothing and closes a real
> lateral-movement path.

---

## 6. Retrieving secrets in the pipeline

Consistent with the existing pattern, exchange the OIDC token for a Vault token, then read. Using the
Vault CLI on the agent:

```bash
set -euo pipefail
export VAULT_NAMESPACE=AUT

VAULT_TOKEN="$(vault write -field=token \
    auth/jwt-ci-ctrlA/login \
    role=container-signing \
    jwt="${CI_OIDC_TOKEN}")"
export VAULT_TOKEN

HARBOR_USER="$(vault kv get -field=username secret/ci/container-signing/harbor-robot)"
HARBOR_TOKEN="$(vault kv get -field=token    secret/ci/container-signing/harbor-robot)"
```

Alternatively use the HashiCorp Vault Jenkins plugin so values are registered as masked build variables.
Either is acceptable; the plugin gives automatic log masking, the CLI gives explicit control.

> **Never `echo` a retrieved secret**, and keep retrieval inside `set +x`. See `04 §7`.

---

## 7. Revocation and rotation

| Credential | Rotation | Emergency revocation |
|---|---|---|
| Vault token | Automatic — 15m TTL, per build | `vault token revoke` |
| Harbor robot token | 90 days | Disable the robot in Harbor; rotate KV |
| Prisma credential | Per site policy | Disable in Prisma; rotate KV |
| Venafi password (Option A) | 90 days | Disable identity in TPP; rotate KV |
| Venafi grant | Per build | `pkcs11config revokegrant --force --clear`; revoke centrally in TPP |

To cut off signing immediately: **revoke the identity's key-use permission on the `container-prod`
environment in TPP** (`01 §7`). That is faster and more complete than rotating secrets, and it stops
in-flight grants. Full procedure in `07 §5`.

---

## 8. Acceptance checklist

- [ ] KV paths created under `secret/ci/container-signing/`
- [ ] `ci-container-signing-ro` policy applied, scoped to that subtree only
- [ ] JWT role `container-signing` created on every controller, `bound_claims` bound to the signing job
- [ ] `venafi-oidc` credential exists with a **distinct** audience (Option B)
- [ ] Signing job authenticates and reads all required secrets; a *different* job on the same controller
      is **denied** (negative test — run it)
- [ ] Vault audit log shows the reads, attributed to the signing job's `sub`
- [ ] No Venafi private key material anywhere in Vault

---

## Related

- `../vault-integrations/01-vault-foundation-AUT.md` — namespace, audit, secrets engines
- `../vault-integrations/02-cloudbees-ci-oidc.md` — OIDC provider, JWT mounts, ID-token credentials
- `../vault-integrations/05-operations-appendix.md` — day-2 Vault operations
