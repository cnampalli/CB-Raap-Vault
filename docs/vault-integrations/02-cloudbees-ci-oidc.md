# 02 — CloudBees CI ⇄ Vault via OIDC (per-build JWT)

> Trust root: each CI controller acts as an **OpenID Connect provider** (OIDC Provider plugin). A build
> mints a short-lived JWT; Vault validates it against the controller's JWKS and returns a scoped token.
> This extends the pattern the Vault team already runs successfully.
>
> Deployment here: **traditional CI on VMs, CJOC + 2–10 controllers** (Client Controller
> `2.528.3.35200-rolling`). Consumes **KV v2 static secrets** and **SSH signing** for deploys.

---

## 1. Install / verify the OIDC Provider plugin

On each controller (Manage Jenkins → Plugins), ensure **OpenID Connect Provider** (`oidc-provider`) is
installed. This environment runs **`111.v29fd614b_3617`**, which **is the fixed version** for
[SECURITY-3574](https://www.jenkins.io/security/advisory/2025-05-14/#SECURITY-3574) (CVE-2025-47884,
Critical): affected versions are `96.vee8ed882ec4d` **and earlier**, and the fix shipped in exactly
`111.v29fd614b_3617`. **No security upgrade is required.** Upgrading to the latest `212.v7657c4d7b_29f` is
optional maintenance (it needs Jenkins core `2.541.3`). Defense in depth regardless: restrict who can
configure jobs / override environment variables (the SECURITY-3574 attack requires Job/Configure).

Confirm each controller's **Jenkins URL** is set to its real external URL (Manage Jenkins → System) — it
becomes the JWT `iss` and the base of the JWKS/discovery endpoints:

```
Issuer / discovery : https://<ci-ctrl>/oidc/.well-known/openid-configuration
JWKS               : https://<ci-ctrl>/oidc/jwks
```

**Firewall:** Vault must reach each controller's `/oidc/**` (matrix flow #1).

---

## 2. Register each controller in Vault

Because each controller is a separate issuer, create **one JWT auth mount per controller** in `AUT`
(clearest for a small fleet). Example for controller "A":

```bash
export VAULT_NAMESPACE=AUT

vault auth enable -path=jwt-ci-ctrlA jwt
vault write auth/jwt-ci-ctrlA/config \
    oidc_discovery_url="https://ctrlA.ci.corp.example.com/oidc" \
    bound_issuer="https://ctrlA.ci.corp.example.com/oidc" \
    default_role="ci-build"
```

Repeat per controller (`jwt-ci-ctrlB`, …). For 10+ controllers, templatize this in the self-service YAML
loop rather than by hand.

> Alternative (single mount): if you prefer one mount, set `jwks_url`/`jwks_ca_pem` and use per-role
> `bound_issuer`. The per-mount approach keeps discovery + issuer aligned and is easier to reason about
> for < 10 controllers.

---

## 3. JWT roles — bind to build claims, attach policies

The OIDC Provider plugin emits claims including the issuer, audience, and build context (job full name,
etc.). Bind on them so only intended jobs get a given policy.

```bash
# KV read + SSH sign for a specific folder/app
vault write auth/jwt-ci-ctrlA/role/ci-build \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="vault-AUT" \
    bound_claims_type="glob" \
    bound_claims='{"sub":"https://ctrlA.ci.corp.example.com/oidc:*"}' \
    claim_mappings='{"build_url":"build_url","job":"job"}' \
    token_policies="ci-secrets-ro,ci-ssh-sign" \
    token_ttl="15m" token_max_ttl="30m"
```

Tighten `bound_claims` to the job/folder that should hold each policy (e.g. bind the `job` claim to
`AUT/payments/*`). Map the app segment into entity metadata if you use the templated `ci-secrets-ro`
policy from guide `01` (so `secret/data/ci/<app>/*` resolves per job).

Self-service YAML fragment:
```yaml
auth_methods:
  - path: jwt-ci-ctrlA
    type: jwt
    config:
      oidc_discovery_url: "https://ctrlA.ci.corp.example.com/oidc"
      bound_issuer: "https://ctrlA.ci.corp.example.com/oidc"
    roles:
      - name: ci-build
        role_type: jwt
        user_claim: sub
        bound_audiences: ["vault-AUT"]
        bound_claims_type: glob
        bound_claims: { job: "AUT/payments/*" }
        token_policies: ["ci-secrets-ro", "ci-ssh-sign"]
        token_ttl: "15m"
        token_max_ttl: "30m"
```

---

## 4. Define the ID-token credential (JCasC)

Configure an OIDC ID-token credential whose **audience** matches `bound_audiences` above. Example JCasC:

```yaml
# casc/credentials.yaml
credentials:
  system:
    domainCredentials:
      - credentials:
          - idToken:                         # JCasC symbol is `idToken` (secret-text ID token)
              scope: GLOBAL
              id: "vault-oidc"
              audience: "vault-AUT"          # must equal Vault role bound_audiences
              # issuer: optional; per-credential fields are only id/scope/description/audience/issuer.
              # Custom claims are configured GLOBALLY, not here — see §4.1.
```

Keep controller config in JCasC so issuer/audience are versioned and reproducible across the fleet.

> **Binding:** the ID-token credential is a **secret-text (String) credential**
> (`IdTokenStringCredentials`), so pipelines bind it with `string(credentialsId: 'vault-oidc',
> variable: 'ID_TOKEN')` — there is no `oidcIdToken` step. (A file variant, JCasC symbol
> `idTokenFile`, binds with `file(...)`.)

### 4.1 Custom claims for project-scoped policies (global config)

By default the plugin (`111.v29fd614b_3617`) emits only `iss, aud, iat, exp, sub` (= `${JOB_URL}` in a
build) and `build_number`. To drive **templated Vault policies** off the build's identity — e.g.
`secret/data/project/<group_name>/<job_name>/*` — emit extra claims via **claim templates**. These are
**global** (`security: → idToken:`), not per-credential:

```yaml
# casc/jenkins.yaml — global OIDC claim configuration (Security category)
security:
  idToken:
    tokenLifetime: 900
    buildClaimTemplates:
      - { name: sub,        format: "${JOB_URL}",     type: string }   # REQUIRED (must define sub)
      - { name: group_name, format: "${VAULT_GROUP}", type: string }   # from a folder env var
      - { name: job_name,   format: "${VAULT_JOB}",   type: string }
```

Rules (source-verified for this version): a template may **not** name a standard claim (`iss, aud, exp,
iat, nbf, jti, auth_time, nonce, acr, amr, azp`); it **must** define `sub`; `format` supports build
variable macros (`${VAR}`) and `type` is `string`/`boolean`/`integer`. Populate `${VAULT_GROUP}` /
`${VAULT_JOB}` as **folder-scoped environment variables** so each job inherits its project identity.
Use `sub: ${JOB_URL}` (per-build), not `${JENKINS_URL}` (identical for every build).

> **Use `buildClaimTemplates`, not `globalClaimTemplates`.** The plugin has three lists:
> `claimTemplates` (always applied), `buildClaimTemplates` (applied **only when the token is minted in a
> build**), and `globalClaimTemplates` (applied **only outside a build**). A build-minted token uses
> `claimTemplates` + `buildClaimTemplates` and **ignores** `globalClaimTemplates` — so a custom claim
> placed in the Global list silently never appears in a pipeline's token.

Then on the Vault role add `claim_mappings` (JWT claim → alias metadata):

```bash
vault write auth/jwt-ci-ctrlA/role/ci-build \
    role_type=jwt user_claim=sub bound_audiences="vault-AUT" \
    bound_claims_type=glob bound_claims='{"sub":"https://ctrlA.ci.corp.example.com/*"}' \
    claim_mappings='{"group_name":"group_name","job_name":"job_name"}' \
    token_policies="ci-project-ro,ci-ssh-sign" token_ttl="15m" token_max_ttl="30m"
```

and attach the templated `ci-project-ro` policy (see `01-vault-foundation-AUT.md` §5.1). Beginner
walk-through with verification + security notes:
`../getting-started/02-cloudbees-ci.md` (Step 6.5).

---

## 5. Pipeline usage

### 5.1 Read a KV v2 secret

```groovy
pipeline {
  agent any
  environment { VAULT_ADDR = 'https://vault-vip.corp.example.com:8200'; VAULT_NAMESPACE = 'AUT' }
  stages {
    stage('Fetch secret') {
      steps {
        withCredentials([string(credentialsId: 'vault-oidc', variable: 'ID_TOKEN')]) {
          sh '''
            set -euo pipefail
            VAULT_TOKEN=$(vault write -field=token auth/jwt-ci-ctrlA/login \
                            role=ci-build jwt="$ID_TOKEN")
            export VAULT_TOKEN
            DB_PASS=$(vault kv get -field=password secret/ci/payments/db)
            # ... use $DB_PASS; never echo it
          '''
        }
      }
    }
  }
}
```

### 5.2 Get a signed SSH cert and deploy

```groovy
stage('Deploy over SSH') {
  steps {
    withCredentials([string(credentialsId: 'vault-oidc', variable: 'ID_TOKEN'),
                     sshUserPrivateKey(credentialsId: 'svc-ci-key', keyFileVariable: 'KEY')]) {
      sh '''
        set -euo pipefail
        VAULT_TOKEN=$(vault write -field=token auth/jwt-ci-ctrlA/login role=ci-build jwt="$ID_TOKEN")
        export VAULT_TOKEN
        # Sign the build agent's public key -> short-lived cert
        ssh-keygen -y -f "$KEY" > "$KEY.pub"
        vault write -field=signed_key ssh/sign/svc-ci \
            public_key=@"$KEY.pub" valid_principals="svc-ci" > "$KEY-cert.pub"
        ssh -i "$KEY" -o CertificateFile="$KEY-cert.pub" \
            svc-ci@target.corp.example.com 'sudo systemctl restart myapp'
      '''
    }
  }
}
```

> The target node must trust the Vault SSH CA (`TrustedUserCAKeys`) — distributed by the AAP node-trust
> playbook in guide `04`. `svc-ci` is the dedicated CI service principal.

---

## 6. Hardening checklist

- [ ] `oidc-provider` `111.v29fd614b_3617` (SECURITY-3574 fixed) on every controller.
- [ ] Jenkins URL = real external URL on every controller (correct `iss`).
- [ ] Vault → each `/oidc/**` reachable (matrix flow #1) — test with `curl` from a Vault node.
- [ ] Audience is unique to this integration (`vault-AUT`) and matches on both sides.
- [ ] `bound_claims` pin each role to a specific job/folder — no wildcard-all roles.
- [ ] Token TTLs 15/30 min; SSH cert TTL ≤ 2 h.
- [ ] No secret values echoed in build logs (`set +x` around secret use; use masking).

---

## 7. Verification

```bash
# From a Vault node — discovery reachable:
curl -s https://ctrlA.ci.corp.example.com/oidc/.well-known/openid-configuration | jq .

# End-to-end: run the sample pipeline; it should
#  (1) mint an ID token, (2) log into Vault, (3) read KV, (4) sign an SSH cert, (5) SSH to a test node.
vault token lookup            # (inside a debug build) shows short TTL + ci-* policies
```
