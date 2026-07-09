# 05 — Verify & Troubleshoot

Use this page to prove the whole setup works and to fix the failures people
actually hit. Everything here is airgap-friendly — local CLIs and UIs only.

---

## 1. Quick end-to-end checklist

Run top to bottom. Each line should pass before the next.

**Vault foundation (guide 01)**
```bash
export VAULT_NAMESPACE=AUT
vault auth list       # jwt-ci/ , jwt-cdro/ , approle/  (and per-controller jwt-ci-ctrlA/ …)
vault secrets list    # secret/ (kv v2) , ssh/
vault policy list     # ci-secrets-ro, ci-ssh-sign, aap-kv-read, aap-ssh-sign, cdro-zerotrust-ro, cdro-broker
vault read ssh/config/ca   # SSH CA public key present
```

**CloudBees CI (guide 02)**
```bash
# Flow #1: Vault can reach the controller's OIDC endpoints
python3 tools/check_oidc_discovery.py https://ctrlA.ci.corp.example.com --cacert /etc/pki/vault/ca.crt
```
Then run any of the three sample pipelines. In a debug build:
```bash
vault token lookup    # short TTL (≤30m) + policies ci-secrets-ro, ci-ssh-sign
```
Inspect the token's claims if a bind isn't matching:
```bash
echo '<captured-JWT>' | python3 tools/inspect_jwt_claims.py   # check iss / aud / sub / job
```

**CloudBees CD/RO (guide 03) — ZeroTrust plugin (primary)**
- A test procedure mints a JWT; decode it: `python3 tools/inspect_jwt_claims.py < token.jwt` shows
  `iss=ZeroTrust`, an asymmetric `alg`, your `aud`, and `job_name=<release>`.
- `vault read auth/jwt-cdro/config` shows `bound_issuer=ZeroTrust`, a static pubkey, and **no** discovery URL.
- A run of release `payments-app` reads `secret/data/cdr/payments-app/db`; the same role pointed at
  another release's path returns **403** (release scoping).
- The read shows the **CD/RO** identity (not a CI broker) in your SIEM.

**CloudBees CD/RO — CI broker (fallback only)**
- Trigger the broker (`SCOPE=cdr/<release>/db`, `SECRET_TYPE=kv`); CD/RO receives a **wrapping token**,
  unwraps once, value is usable; unwrapping the **same** token again **fails** (single-use).

**AAP (guide 04)**
```bash
ROLE_ID=$(vault read -field=role_id auth/approle/role/aap-automation/role-id)
WRAP=$(vault write -wrap-ttl=120s -field=wrapping_token -f auth/approle/role/aap-automation/secret-id)
SECRET_ID=$(vault unwrap -field=secret_id "$WRAP")
vault write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"   # policies aap-*
vault unwrap "$WRAP"   # must FAIL (already used) — proves single-use
```
- A job template using **Signed SSH** connects to a node as `svc-aap`.
- A job template using **Secret Lookup** resolves a KV value (masked in log).

---

## 2. Firewall validation (do this before blaming config)

Most "it won't authenticate" problems are a closed firewall path, not bad config.
Validate the flows from [00 §3](00-before-you-begin.md#3-network-flows-to-request-airgapped--nothing-is-open-by-default).

**Flow #1 (the classic silent failure) — from a Vault node:**
```bash
# Helper (clearest):
python3 tools/check_oidc_discovery.py https://ctrlA.ci.corp.example.com --cacert /etc/pki/vault/ca.crt

# Or manually:
curl -s https://ctrlA.ci.corp.example.com/oidc/.well-known/openid-configuration | grep jwks_uri
```
If either fails, JWT login fails with signature/validation errors **regardless of
role config**. Fix the firewall first.

---

## 3. Troubleshooting table

| Platform | Symptom | Likely cause | What to check |
|---|---|---|---|
| CI | `error validating token: … signature` | Vault can't reach controller JWKS (flow #1), or wrong issuer | `check_oidc_discovery.py`; confirm **Jenkins URL** = the JWT `iss` |
| CI | `invalid audience` | Credential `audience` ≠ role `bound_audiences` | Compare JCasC `audience` with `vault read auth/jwt-ci-ctrlA/role/ci-build` |
| CI | `permission denied` on KV | `bound_claims` too broad/narrow, or policy path mismatch | `vault token lookup` in a debug build; check policy path vs `secret/data/ci/<app>/*`; inspect claims with `inspect_jwt_claims.py` |
| CI | a custom claim (e.g. `group_name`) is **missing** from the JWT (others present) | Claim defined in **Global claim templates** (ignored during builds), or a half-saved row | Move it to the **Build claim templates** list (`buildClaimTemplates`); confirm the row saved (name/format/type); re-check with `inspect_jwt_claims.py` |
| CI (nocli) | `no such static method … java.lang.Math ceil … BigDecimal` | Old DEBUG stage padded base64 with `Math.ceil` (sandbox-rejected) | Use the current `Jenkinsfile.vault-oidc-nocli` — its DEBUG stage uses the `Math`-free `b64urlDecode` helper (no script approval) |
| CI | token/JWT printed in log | `PRINT_JWT=true` left on | Set it back to **false**; rotate is automatic (token expires) |
| CD/RO | login `error validating token: … signature` | Wrong/absent public key on the mount, or wrong algorithm | Paste the **matching** `jwt_validation_pubkeys` PEM; confirm plugin `Algorithm` matches the key type; decode the token header with `inspect_jwt_claims.py` |
| CD/RO | login `invalid issuer` | Plugin `Issuer` ≠ mount `bound_issuer` | Both must be exactly `ZeroTrust` (`vault read auth/jwt-cdro/config`) |
| CD/RO | login `invalid audience` | `customClaims.aud` ≠ role `bound_audiences` | Decode the token (`aud`); compare with `vault read auth/jwt-cdro/role/cdro-zerotrust` |
| CD/RO | `permission denied` on KV read | Release claim missing/mismapped, or reading another release's path | Confirm `job_name` is in the token and `claim_mappings={"job_name":"release"}`; path must be `secret/data/cdr/<release>/*` |
| CD/RO | run reads the **wrong** secret / intermittent auth failures | **Concurrency clobber** — two releases share one CD/RO credential | Give each release/pipeline its own credential (e.g. not a shared `zt_credential`); serialize with resource locks |
| CD/RO | JWT or secret value appears in logs | `debugLevel=debug`/`trace`, or a property not masked | Set `debugLevel=info`; mark the JWT/secret property secure/masked |
| CD/RO (fallback) | `unwrap` fails | Token already used, expired, or wrong namespace | Wrap is single-use + 90 s; confirm `VAULT_NAMESPACE=AUT`; re-trigger the broker |
| CD/RO (fallback) | broker `permission denied` | `cdro-broker` role/claims or policy scope | `bound_claims job=AUT/vault-broker`; `cdro-broker` policy path `secret/data/cdr/*` |
| AAP | login `invalid role_id` / `invalid secret_id` | Wrong/expired/already-used `secret_id`, or wrong mount | `secret_id_num_uses=1` and `secret_id_ttl=10m` — generate a fresh wrapped one; confirm **Path to Auth** = `approle` |
| AAP | login `permission denied` from AAP host | Source IP not in the bound CIDR | Confirm the AAP host IP is inside `secret_id_bound_cidrs`/`token_bound_cidrs` (mind NAT/proxy — Vault sees the proxy IP) |
| AAP | SSH `Permission denied (publickey)` | Node doesn't trust the CA, or wrong principal | Node has `TrustedUserCAKeys`? cert `valid_principals` includes `svc-aap`? Re-run the trust playbook |
| AAP | KV field empty at launch | Wrong metadata mapping | Check **Name of Secret Backend** = `secret`, **Path to Secret** = `aap/<app>/<name>`, **Key Name**, **API Version** = `v2` |
| Any | `namespace not found` | Missing `-namespace=AUT` / header | `export VAULT_NAMESPACE=AUT` or add `X-Vault-Namespace: AUT` |
| Any | `x509: certificate signed by unknown authority` | Vault's private CA not trusted | Pass `--cacert`/import the CA into the platform truststore |

Handy general checks:
```bash
export VAULT_NAMESPACE=AUT
vault read sys/health
vault auth list ; vault secrets list ; vault policy list
# In SIEM, follow by request path: auth/jwt-ci*, auth/approle/*, ssh/sign/*, secret/data/*
```

---

## 4. Confirm the security properties actually hold

Don't just check it *works* — check it's *safe*:

- **Short TTLs:** `vault token lookup` shows ≤ 30 min on issued tokens; SSH certs
  ≤ 2 h (`ssh/roles/svc-*`).
- **Least privilege:** each token's `policies` list contains only that platform's
  `*-ro`/`*-sign` policies — nothing broader.
- **No static secrets:** CI stores no Vault token (JWT per build); CD/RO mints a
  short-lived ZeroTrust JWT per run (its only stored secret is the plugin's **signing
  key**, held in a locked-down Credential — see guide 03 Step 8); AAP's `secret_id` is
  single-use, short-lived, and CIDR-bound.
- **Single-use wraps:** re-unwrapping any CD/RO (broker fallback) or AAP wrap token fails.
- **Audit:** every login + read appears in the SIEM with values HMAC'd, not
  plaintext (`log_raw=false`).
- **No secrets in logs:** grep a build/job log for a known secret value — it must
  not appear (only lengths/OK messages).

---

## 5. Default TTLs shipped by these guides

These are the zero-trust defaults the guides use. Override them if a formal rotation
SLA says otherwise.

| Artifact | Default TTL | Max TTL | Where set |
|---|---|---|---|
| CI JWT (id token) | job duration | job timeout | OIDC Provider plugin (automatic per build) |
| Vault token (JWT / AppRole) | 15–20 min | 30 min | role `token_ttl` / `token_max_ttl` |
| CD/RO ZeroTrust JWT | 900 s | 900 s | plugin `Token lifetime` (keep short) |
| CD/RO Vault token (ZeroTrust) | 15 min | 15 min | `cdro-zerotrust` role |
| Broker token (CD/RO, fallback) | 5 min | 10 min | `cdro-broker` role |
| SSH signed cert | 1 h | 2 h | `ssh/roles/svc-*` |
| Response-wrap (CD/RO, fallback) | 90 s | 90 s | client `-wrap-ttl` (single-use) |
| AAP `secret_id` | 10 min | 10 min | `aap-automation` role (`secret_id_num_uses=1`) |

---

## 6. Reference material

- Design rationale, decision records, full firewall matrix:
  [`../vault-integrations/`](../vault-integrations/) (docs 00–05).
- Helper tools: [`../../tools/inspect_jwt_claims.py`](../../tools/inspect_jwt_claims.py),
  [`../../tools/check_oidc_discovery.py`](../../tools/check_oidc_discovery.py).
- Pipeline examples: [`../vault-integrations/examples/`](../vault-integrations/examples/).

That's the full loop. If every check in §1 passes, all three platforms are pulling
secrets from Vault with short-lived, workload-bound identity and no static secrets.
