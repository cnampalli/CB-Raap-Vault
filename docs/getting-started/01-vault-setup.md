# 01 — Set Up Vault (the `AUT` Namespace)

This is the shared foundation. Do it first — CI, CD/RO, and AAP all depend on it.
You'll enable auditing, a secret store, an SSH certificate signer, two login
methods (JWT for CI, AppRole for AAP), and least-privilege permission policies.

> **Who runs this:** the Vault team applies it; you (Automation) author it. If you
> submit config as YAML via pull request, the equivalent YAML is in
> [`../vault-integrations/01-vault-foundation-AUT.md`](../vault-integrations/01-vault-foundation-AUT.md).
> This page shows the direct `vault` commands so you can see exactly what each does.

**Before each command block**, set your namespace and address once per shell:

```bash
export VAULT_ADDR="https://<vault-vip>:8200"
export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"   # your internal CA bundle
```

> Prereq: Vault Enterprise `1.20.8+ent` is healthy and unsealed, and the `AUT`
> namespace exists. To create it (Vault team, from the parent namespace):
> `vault namespace create AUT`

---

## Step 1 — Turn on audit logging (to your SIEM)

Every login and secret read must be recorded. This streams the audit log to your
SIEM over syslog (firewall flow #9).

```bash
vault audit enable syslog tag="vault-AUT" facility="AUTH" log_raw=false
```

- `log_raw=false` keeps secret values **hashed** in the log (never plaintext).
- **Expected result:** `Success! Enabled the syslog audit device at: syslog/`
- Point the host's syslog forwarder at your SIEM collector.

---

## Step 2 — Enable the secret store (KV v2)

```bash
vault secrets enable -path=secret -version=2 kv
```

**Expected result:** `Success! Enabled the kv secrets engine at: secret/`

Use this path convention (one folder per platform, then per app):

```
secret/data/ci/<app>/<name>       # e.g. secret/data/ci/payments/db
secret/data/cdr/<release>/<name>  # CD/RO reads its own release path (ZeroTrust plugin, guide 03)
secret/data/aap/<app>/<name>
```

Put a test secret in so later guides have something to read:

```bash
vault kv put secret/ci/payments/db password="example-not-a-real-password"
```

---

## Step 3 — Enable the SSH certificate signer

This lets Vault sign short-lived SSH certificates so nobody keeps static keys on
servers.

```bash
# Enable the SSH engine and generate its signing CA
vault secrets enable -path=ssh ssh
vault write ssh/config/ca generate_signing_key=true

# Print the CA public key — managed nodes will be told to trust this (guide 04)
vault read -field=public_key ssh/config/ca
```

Create one signing role per platform (a dedicated login user each):

```bash
# For CloudBees CI deploys (user: svc-ci)
vault write ssh/roles/svc-ci \
    key_type=ca allow_user_certificates=true \
    allowed_users="svc-ci" default_user="svc-ci" \
    allowed_extensions="permit-pty,permit-port-forwarding" \
    default_extensions='{"permit-pty":""}' \
    ttl="1h" max_ttl="2h"

# For AAP deploys (user: svc-aap)
vault write ssh/roles/svc-aap \
    key_type=ca allow_user_certificates=true \
    allowed_users="svc-aap" default_user="svc-aap" \
    allowed_extensions="permit-pty" \
    default_extensions='{"permit-pty":""}' \
    ttl="1h" max_ttl="2h"
```

**Expected result:** each `vault write` returns `Success! Data written to: ...`.
Certificates signed by these roles live at most **2 hours**.

---

## Step 4 — Enable the login method for CloudBees CI (JWT)

CI controllers each act as an OpenID Connect provider. Vault validates each build's
JWT against the controller's published keys. Enable the JWT method now; you'll add
one config + role **per controller** in guide [02](02-cloudbees-ci.md).

```bash
vault auth enable -path=jwt-ci jwt
```

**Expected result:** `Success! Enabled jwt auth method at: jwt-ci/`

> You'll come back and run `vault write auth/jwt-ci-<controller>/config ...` for
> each controller in guide 02. Nothing more to do here.

---

## Step 4b — Enable the login method for CloudBees CD/RO (ZeroTrust JWT)

CD/RO's **ZeroTrust** plugin signs its own JWT locally, so — unlike CI — Vault
validates it against a **static public key**, not a discovery URL. Enable a
dedicated JWT mount now; you'll add the config + role in guide
[03](03-cloudbees-cdro.md).

```bash
vault auth enable -path=jwt-cdro jwt
```

**Expected result:** `Success! Enabled jwt auth method at: jwt-cdro/`

> In guide 03 you'll run `vault write auth/jwt-cdro/config
> jwt_validation_pubkeys=@zerotrust-pub.pem bound_issuer=ZeroTrust` (no discovery
> URL — the plugin has no JWKS endpoint).

---

## Step 5 — Enable the login method for AAP (hardened AppRole)

AAP 2.4 has no native OIDC, so it logs in with an **AppRole**: a public `role_id`
plus a secret `secret_id`. Because the `secret_id` is a bootstrap secret, we harden
it heavily. (Full delivery + AAP-side setup is in guide [04](04-aap-approle-ssh.md);
here we just create the method and the role.)

```bash
# Enable the AppRole method
vault auth enable approle
```

Create the AAP role with **all** the hardening switches:

```bash
vault write auth/approle/role/aap-automation \
    token_policies="aap-kv-read,aap-ssh-sign" \
    token_ttl="20m" \
    token_max_ttl="30m" \
    token_type="service" \
    token_bound_cidrs="10.20.0.0/24" \
    secret_id_ttl="10m" \
    secret_id_num_uses="1" \
    secret_id_bound_cidrs="10.20.0.0/24" \
    bind_secret_id=true
```

What each hardening setting buys you:

| Setting | Effect |
|---|---|
| `token_policies` | The login token can do **only** `aap-kv-read` + `aap-ssh-sign` (Step 6). |
| `token_ttl` / `token_max_ttl` | The token dies in 20–30 minutes. |
| `token_bound_cidrs` | The token only works **from AAP's IP range**. A stolen token is useless elsewhere. |
| `secret_id_ttl="10m"` | An unused `secret_id` self-destructs in 10 minutes. |
| `secret_id_num_uses="1"` | A `secret_id` can be redeemed **exactly once**. Reuse is rejected. |
| `secret_id_bound_cidrs` | The `secret_id` can only be presented **from AAP's IP range**. |
| `bind_secret_id=true` | A `secret_id` is always required (no role_id-only login). |

> Replace `10.20.0.0/24` with your **actual AAP host IP(s)**. You can use exact
> `/32` addresses for the tightest lock. Note: behind a NAT/proxy, Vault sees the
> *proxy* IP — bind to whatever address actually reaches Vault.

**Expected result:** `Success! Data written to: auth/approle/role/aap-automation`

---

## Step 6 — Create the least-privilege policies

Policies are the permission rules. Each one grants read on **only** the paths that
platform needs. Create the policy files, then load them.

**CI — read its own secrets + sign its SSH role:**

```bash
# ci-secrets-ro: read only this app's CI secrets (templated per app via claim metadata)
vault policy write ci-secrets-ro - <<'EOF'
path "secret/data/ci/{{identity.entity.aliases.<jwt-ci-accessor>.metadata.app}}/*" {
  capabilities = ["read"]
}
EOF

vault policy write ci-ssh-sign - <<'EOF'
path "ssh/sign/svc-ci" {
  capabilities = ["update"]
}
EOF
```

> Replace `<jwt-ci-accessor>` with the accessor of your `jwt-ci-<controller>` mount
> (`vault auth list -detailed` shows accessors). If templating is more than you need
> to start, use a simpler fixed path like `path "secret/data/ci/*"` and tighten later.
>
> **Want per-project paths driven by the build's claims** (e.g.
> `secret/data/project/<group_name>/<job_name>/*`)? That uses a `ci-project-ro`
> templated policy plus JWT claim templates — the full recipe is in
> [02 — CloudBees CI, Step 6.5](02-cloudbees-ci.md#step-65--advanced-project-scoped-secrets-from-jwt-claims).

**AAP — read its own secrets + sign its SSH role:**

```bash
vault policy write aap-kv-read - <<'EOF'
path "secret/data/aap/*" {
  capabilities = ["read"]
}
EOF

vault policy write aap-ssh-sign - <<'EOF'
path "ssh/sign/svc-aap" {
  capabilities = ["update"]
}
EOF
```

**CD/RO (ZeroTrust) — read only its own release's secrets (guide 03):**

```bash
# cdro-zerotrust-ro: templated so each release reads only secret/data/cdr/<release>/*
vault policy write cdro-zerotrust-ro - <<'EOF'
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}
EOF
```

> Replace `<jwt-cdro-accessor>` with the accessor of your `jwt-cdro` mount
> (`vault auth list -detailed`). The release name arrives as a JWT claim and is mapped
> to identity metadata in guide [03, Step 4](03-cloudbees-cdro.md#step-4--create-the-vault-role--release-scoped-read-only-policy).
> To start simpler, use a fixed `path "secret/data/cdr/*"` and tighten later.

**CD/RO broker — *fallback only* (used by the CI broker job when the plugin can't be used, guide 03 §8):**

```bash
vault policy write cdro-broker - <<'EOF'
path "secret/data/cdr/*" {
  capabilities = ["read"]
}
EOF
```

**Expected result:** each returns `Success! Uploaded policy: <name>`.

> Response-wrapping (used for CD/RO and for AAP's `secret_id`) needs **no** special
> policy capability — the requester just asks for it with `-wrap-ttl`. Read on the
> target path is enough.

---

## Step 7 — Verify the foundation

```bash
export VAULT_NAMESPACE=AUT
vault audit list          # -> syslog/ present
vault secrets list        # -> secret/ (kv v2) and ssh/ present
vault auth list           # -> jwt-ci/, jwt-cdro/, and approle/ present
vault read ssh/config/ca  # -> the SSH CA public key
vault policy list         # -> ci-secrets-ro, ci-ssh-sign, aap-kv-read, aap-ssh-sign, cdro-zerotrust-ro, cdro-broker
```

If all show what's expected, the foundation is done.

---

## What you built

| You enabled | So that |
|---|---|
| Audit → SIEM | every access is recorded |
| KV v2 at `secret/` | secrets have a home, versioned |
| SSH CA + `svc-ci`/`svc-aap` roles | servers get short-lived signed certs, no static keys |
| `jwt-ci` auth | CloudBees CI can log in per build (guide 02) |
| `jwt-cdro` auth | CloudBees CD/RO can log in with its ZeroTrust JWT (guide 03) |
| `approle` auth + hardened `aap-automation` role | AAP can log in safely (guide 04) |
| 6 least-privilege policies | each platform reads only its own secrets |

Next: **[02 — CloudBees CI](02-cloudbees-ci.md)**.
