# 05 — Operations Appendix

Cross-cutting operational reference for the CI / CDRO / AAP ↔ Vault Enterprise (`AUT`) integrations.

---

## 1. Firewall matrix (validate first)

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| 1 | Vault nodes | each `<ci-ctrl>/oidc/**` | 443 | **Vault → CI** JWKS/discovery (validate JWTs) |
| 2 | CI controllers/agents | `<vault-vip>` | 8200 | JWT login + KV read + SSH sign |
| 3 | **CDRO server/agents** | `<vault-vip>` | 8200 | **ZeroTrust JWT login + KV read** (primary) |
| 3b | CI broker build *(fallback)* | `<vault-vip>` | 8200 | Broker login + read + response-wrap |
| 4 | CDRO server/agents *(fallback)* | `<ci-ctrl>` REST | 443 | Trigger broker job |
| 5 | CI (result) *(fallback)* | CDRO | 443/8443 | Return wrapping token / lease |
| 6 | CDRO server/agents *(fallback)* | `<vault-vip>` | 8200 | Unwrap / lease renew only |
| 7 | AAP controllers/EEs | `<vault-vip>` | 8200 | AppRole login + SSH sign + KV lookup |
| 8 | AAP EEs / CI agents | managed nodes | 22 | SSH using signed certs |
| 9 | Vault nodes | SIEM/syslog | 514/6514 | Audit stream |
| 10 | AAP node-trust playbook | `<vault-vip>/v1/AUT/ssh/public_key` | 8200 | Fetch SSH CA public key |

**Validate the whole matrix** with the shell-only harness in [`../shared/`](../shared/).
Its only dependency is bash — no python, no `jq` — so it runs on a hardened Vault
node, and the same check is callable from [AAP](../AAP/), [CloudBees CI](../CI/),
and [CD/RO](../CDRO/):

```bash
docs/shared/conn_check.sh                            # every flow, from here
docs/shared/conn_check.sh --app vault --env prod     # a subset
docs/shared/conn_check.sh --hop all                  # flows whose source is elsewhere
```

It separates **TIMEOUT** (a firewall DROP) from **REFUSED** (path open, nothing
listening), so a report tells you whether the firewall team or the service owner
owns the problem. Targets live in
[`../shared/targets.conf`](../shared/targets.conf), seeded from the table above.

**Validate flow #1 (most common failure)** from a Vault node. Its source is a
Vault node, so it cannot be checked from anywhere else — hop mode does the SSH:
```bash
docs/shared/conn_check.sh --hop flow1-vault-to-ci

# Equivalent by hand (needs jq on the Vault node):
curl -s https://<ci-ctrl>/oidc/.well-known/openid-configuration | jq .jwks_uri
curl -s "$(curl -s https://<ci-ctrl>/oidc/.well-known/openid-configuration | jq -r .jwks_uri)" | jq '.keys|length'
```
If either fails, JWT auth will fail with signature/validation errors regardless of role config.

---

## 2. TTL / rotation SLA table

> **Confirm against the mandated SLA (numbers pending).** Defaults below ship in the guides.

| Artifact | Default TTL | Max TTL | Where set | Rotation owner |
|---|---|---|---|---|
| CI JWT (id token) | job duration | job timeout | OIDC Provider plugin | automatic per build |
| Vault token (jwt/cert) | 15 min | 30 min | role `token_ttl`/`token_max_ttl` | automatic (re-auth) |
| CDRO ZeroTrust JWT | 900 s | 900 s | plugin `Token lifetime` | automatic per run (operator-set) |
| CDRO Vault token (ZeroTrust) | 15 min | 15 min | `cdro-zerotrust` role | automatic (re-auth) |
| Broker token (CDRO, fallback) | 5 min | 10 min | `cdro-broker` role | automatic per build |
| SSH signed cert | 1 h | 2 h | `ssh/roles/svc-*` | automatic (re-sign) |
| Response-wrap (CDRO fallback / AAP secret_id) | 90 s / 120 s | same | client `-wrap-ttl` | single-use |
| CDRO ZeroTrust signing key | n/a (long-lived) | — | plugin `Credential` + mount `jwt_validation_pubkeys` | **manual**, coordinated (guide `03` §7) |
| Dynamic DB/cloud lease | 30 min | 1 h | engine role | lease expiry/revoke |
| AAP AppRole `secret_id` | 10 min | 10 min | `aap-automation` role | single-use, CIDR-bound; rotation per §3 |
| Vault SSH CA key | n/a (long-lived) | — | `ssh/config/ca` | manual, planned rotation |

---

## 3. Rotation & DR

- **Vault:** Raft snapshots on a schedule (`vault operator raft snapshot save`); test restore periodically.
  Auto-unseal keys / recovery keys stored per your KMS/HSM policy.
- **SSH CA rotation:** generate a new CA, publish both old+new public keys in `TrustedUserCAKeys` during
  overlap (the node-trust playbook can append), then retire the old. Plan this before CA key max-age.
- **AAP AppRole `secret_id`:** single-use and short-lived by design. Rotate by issuing a fresh
  response-wrapped `secret_id` (`-wrap-ttl`) per run, or keep a longer-lived CIDR-locked `secret_id` in
  AAP's encrypted credential store and re-issue it on your SLA. `role_id` is stable and non-secret.
- **AD CS client certs (cert-auth alternative only):** if you use the cert-auth path, rotation is via AD CS
  enrollment; track expiry and re-enroll before `notAfter`. Vault needs no change on renewal (same CA chain).
- **CI OIDC:** no stored secret to rotate; JWTs are per-build. Rotate the **CDRO→CI trigger token** on SLA
  (fallback path only).
- **CDRO ZeroTrust signing key:** manual, coordinated rotation (guide `03` §7) — add the new **public** key
  to the `jwt-cdro` mount first (dual-trust window), swap the **private** key in the CDRO Credential, then
  remove the old public key after the ~900 s token overlap. Destroy the retired private key.

---

## 4. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| CI: `error validating token: ... signature` | Vault can't reach controller JWKS (flow #1) or wrong issuer | `curl` discovery from a Vault node; confirm Jenkins URL = `iss` |
| CI: `invalid audience` | Credential `audience` ≠ role `bound_audiences` | Compare JCasC `audience` and `vault read auth/jwt-*/role/...` |
| CI: `permission denied` on KV | `bound_claims` too broad/narrow or policy path mismatch | `vault token lookup` in a debug build; check policy path vs `secret/data/ci/<app>/*` |
| CI: custom claim (e.g. `group_name`) missing from JWT | Claim placed in **Global** claim templates (ignored in builds), not **Build** (`buildClaimTemplates`) | Move it to `buildClaimTemplates`; verify with `inspect_jwt_claims.py` |
| CI (nocli): `no such static method ... Math.ceil ... BigDecimal` | Old DEBUG stage used `Math.ceil(BigDecimal)` (script-security rejects it) | Use the current `Jenkinsfile.vault-oidc-nocli` DEBUG stage (Math-free `b64urlDecode`) |
| AAP: `invalid secret_id`/`invalid role_id` | `secret_id` already used, expired, or wrong mount | `secret_id_num_uses=1`, `secret_id_ttl=10m` — issue a fresh wrapped one; confirm **Path to Auth** = `approle` |
| AAP: AppRole `permission denied` from AAP host | Source IP not in the bound CIDR | AAP host IP inside `secret_id_bound_cidrs`/`token_bound_cidrs`? (behind NAT, Vault sees the proxy IP) |
| AAP (cert-auth alt): `tls: bad certificate` | AD CS chain not trusted or CN not allowed | `vault read auth/cert-aap/certs/aap`; verify client cert CN vs `allowed_common_names` |
| AAP: SSH `Permission denied (publickey)` | Node doesn't trust CA / wrong principal | node `TrustedUserCAKeys` present? cert `valid_principals` includes `svc-aap`? |
| CDRO (ZeroTrust): login `... signature` | Wrong/absent `jwt_validation_pubkeys`, or algorithm mismatch | Paste the matching PEM; confirm plugin `Algorithm` vs key type; decode header with `inspect_jwt_claims.py` |
| CDRO (ZeroTrust): `invalid issuer`/`invalid audience` | Plugin `Issuer`≠`bound_issuer`, or `customClaims.aud`≠`bound_audiences` | `vault read auth/jwt-cdro/config` and `.../role/cdro-zerotrust`; both must match the token exactly |
| CDRO (ZeroTrust): `permission denied` on KV | Release claim missing/mismapped, or cross-release read | `claim_mappings={"job_name":"release"}`; path `secret/data/cdr/<release>/*`; policy templated |
| CDRO (ZeroTrust): wrong secret / flaky auth | **Concurrency clobber** — shared CDRO credential across releases | Per-release/pipeline credential; don't share `zt_credential`; serialize with resource locks |
| CDRO (ZeroTrust): JWT/secret in logs | `debugLevel=debug/trace` or unmasked property | Set `debugLevel=info`; mark JWT/secret properties secure/masked |
| CDRO (fallback): `unwrap` fails | Token already used, expired, or wrong namespace | Wrap is single-use + 90 s; confirm `VAULT_NAMESPACE=AUT`; re-trigger broker |
| CDRO (fallback): broker `permission denied` | `cdro-broker` role/claims or policy scope | `bound_claims job=AUT/vault-broker`; `cdro-broker` policy path `secret/data/cdr/*` |
| Any: `namespace not found` | Missing `-namespace=AUT` / header | Set `VAULT_NAMESPACE=AUT` |

Useful:
```bash
export VAULT_NAMESPACE=AUT
vault read sys/health
vault auth list ; vault secrets list ; vault policy list
# Follow audit in SIEM by request path (auth/jwt-ci*, auth/cert-aap*, ssh/sign/*, secret/data/*)
```

---

## 5. Security posture summary

- No static Vault credential in CI (per-build JWT). CDRO proves **its own** identity with a short-lived
  **ZeroTrust JWT** minted per run; its only stored secret is the plugin's **signing key**, held in a
  locked-down CDRO Credential (least-privilege ACL, manual rotation). AAP uses a **hardened AppRole**: its
  one bootstrap `secret_id` is single-use, short-lived, response-wrapped, and CIDR-bound, stored only in
  AAP's encrypted credential store.
- All tokens/certs short-lived; SSH is cert-based (no static keys on nodes).
- Every login + read audited to SIEM (HMAC'd values). CDRO reads are now attributed to **CDRO's own
  identity** (`user_claim=sub`), not a broker.
- **Known residual risks (ZeroTrust):** the private signing key is a forge-if-stolen secret (mitigate with
  tight Credential ACLs, short `Token lifetime`, and rotation); key rotation is **manual**; and concurrent
  runs from different releases must not share one CDRO credential (clobber). The **CI-broker fallback**, if
  used, still attributes access to the CI broker identity.

---

## 6. Open follow-ups

- [ ] **Vault self-service YAML schema** — reshape guide `01` YAML to the Vault team's schema (to be shared).
- [ ] **TTL / rotation SLA numbers** — guides ship concrete zero-trust defaults (§2, guide `00` §5); override on formal SLA.
- [x] **OIDC Provider plugin** — resolved: `111.v29fd614b_3617` **is** the SECURITY-3574 fix; no security upgrade needed.
- [x] **AAP plugin field schema** — resolved: AppRole fields confirmed (`role_id`/`secret_id`, Path to Auth `approle`, Namespace, API Version `v2`; Signed SSH uses "Path to Secret" as the sign path).
- [ ] **CI trigger token** for CDRO — finalize scope (build `AUT/vault-broker` only) + storage in CDRO cred store (**fallback path only**).
- [ ] **ZeroTrust `aud` + algorithm/PEM** — decode a real token to confirm the exact `aud` (set `bound_audiences`; assumed `vault-AUT`) and the signing algorithm + `jwt_validation_pubkeys` PEM (assumed RS256). See guide `03` §1.
- [ ] **ZeroTrust signing-key rotation** — automate the public-key push + Credential swap on the mandated SLA (currently manual, guide `03` §7).
- [ ] **CDRO credential-per-release** — enforce that concurrent releases don't share one CDRO credential (avoid the clobber).
- [ ] **AAP `secret_id` rotation** — finalize delivery/rotation (wrapped one-shot per run vs. CIDR-locked stored `secret_id` rotated on SLA).
- [ ] **AAP 2.7 upgrade** — cut AAP over to native OIDC when available (drops AppRole entirely).
- [ ] **AD CS / Venafi (cert-auth alternative only)** — relevant only if you adopt the documented cert-auth alternative.
- [ ] **SPIRE (deferred)** — largely moot for CDRO now that the ZeroTrust plugin gives it its own JWT identity; reconsider only for pre-2.7 AAP if priorities change.
