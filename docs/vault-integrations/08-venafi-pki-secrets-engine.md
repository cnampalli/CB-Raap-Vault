# 08 — Vault ⇄ Venafi (CyberArk Certificate Manager) PKI secrets engine

> **Scope:** issue X.509 **TLS certificates** from Vault where **Venafi TPP** (now *CyberArk Certificate
> Manager, Self-Hosted*) is the policy authority and the enterprise CA does the signing. Vault never
> holds a CA key. Every certificate lands in the TPP inventory, so the PKI team can see it.
>
> **Pinned versions:**
>
> | Component | Version | Notes |
> |---|---|---|
> | Vault Enterprise | **1.21.0+ent** | Raft, VMs, namespace **`AUT`** (as in guide `01`) |
> | `venafi-pki-backend` | **v0.16.0** (2026-07-02) | Built with go1.25.7 and `vault/sdk` v0.25.1 |
> | TPP / Certificate Manager, Self-Hosted | must support the `hashicorp-vault-by-venafi` API integration | 20.1+ for API integrations; the plugin README badge states 17.3+ for the product line |
>
> **Not in scope:** code signing. Container signing keys stay in CodeSign Protect and are **never** in
> Vault (see [`../container-signing/03-vault-secrets.md`](../container-signing/03-vault-secrets.md)).
> This guide covers TLS server and client certificates only.
>
> **Working examples:**
> [`examples/venafi-pki-install-node.sh`](examples/venafi-pki-install-node.sh) (run on every Vault node),
> [`examples/venafi-pki-configure.sh`](examples/venafi-pki-configure.sh) (run once, as a Vault admin),
> [`examples/venafi-pki-consumer.hcl`](examples/venafi-pki-consumer.hcl) (consumer policy).

---

## 1. Why v0.16.0 and not older

v0.16.0 is a **security release**. Do not deploy anything older.

| Fix | Why it matters |
|---|---|
| CWE-639: prevent **cross-role private key disclosure** (VC-53759) | Before 0.16.0, a token allowed to read certificates under one role could read another role's stored private key. This matters whenever `store_pkey=true` |
| CWE-639: **cross-role revoke and delete** (VC-53760) | A consumer of role A could revoke role B's certificates |
| CWE-476: nil dereference on a **non-existent role** (VC-53758) | Unauthenticated-adjacent DoS of the plugin process |
| Certificate revocation identifiers fixed | Revocation now targets the right certificate in TPP |

> **v0.17.0 is already out (2026-08-26).** It adds `key_bits`/`key_type` to the role read output, a
> local-certificate **delete** endpoint, and vcert v5.13.9. Nothing in this guide changes for 0.17.0.
> §10 shows the in-place upgrade.

---

## 2. How it works

```
 Consumer (CI / CDRO / AAP)                Vault Enterprise 1.21 (ns AUT)                    Venafi TPP                 Enterprise CA
 ──────────────────────────               ─────────────────────────────────                 ───────────                ─────────────
  1  login (jwt-ci / approle / jwt-cdro) ─►  token + policy venafi-pki-consumer
  2  write venafi-pki/issue/web-aut ──────►  role "web-aut" → venafi secret "tpp"
                                             plugin generates key + CSR locally
                                          3  POST /vedsdk/certificates/request ──────────►  policy-folder checks
                                                (Bearer access_token)                       (DN, key size, domains)  ─►  signs
                                          4  poll /vedsdk/certificates/retrieve ◄──────────  cert + chain       ◄────────
  5  ◄── certificate, issuing_ca, chain, private_key (+ lease if generate_lease=true)
                                             (optional) store cert/key in Vault storage
```

- **Key generation:** by default the **plugin** generates the key pair and sends only a CSR
  (`service_generated_cert=false`). With `sign/` the consumer generates the key and Vault never sees it.
  Prefer `sign/` for long-lived service identities.
- **Policy authority:** the **TPP policy folder** decides subject DN, key size, allowed domains,
  validity and CA template. The plugin's role has **no `allowed_domains`** setting, unlike Vault's
  built-in `pki`. So name restriction belongs in **two** places: TPP domain whitelisting, and Vault ACL
  `allowed_parameters` (see §8).
- **API:** the plugin uses the same API shape as Vault's built-in PKI engine for issue, sign and
  revoke. The CA-management endpoints do not exist.
- **Endpoints** (from the v0.16.0 source): `venafi/<name>`, `roles/<name>`, `issue/<role>`,
  `sign/<role>`, `revoke/<role>`, `cert/<id>`, `certs/`.

---

## 3. Prerequisites

### 3.1 TPP side (owner: PKI / Venafi team)

| # | Item | Detail |
|---|---|---|
| T1 | **API integration** | **`hashicorp-vault-by-venafi`** ("Venafi Secrets Engine for HashiCorp Vault"). Scope **`certificate:manage,revoke`**. Leave out `revoke` if Vault must never revoke |
| T2 | **Service identity** | A dedicated local or AD account, e.g. `svc-vault-pki`, that is allowed to use the T1 integration. No other use |
| T3 | **Policy folder** per trust domain | e.g. `\VED\Policy\Certificates\Automation\Vault\AUT`. Grant T2 **View, Read, Write, Create** on it, and nothing above it |
| T4 | **Policy on the folder** | Subject O/OU/L/ST/C locked. CA template set. Management Type **not locked**, or locked to *Enrollment*. CSR generation **not** locked to *Service Generated*. *Generate key/CSR on application* not locked, or locked to *No*. **Disable Automatic Renewal = Yes** (Vault consumers renew, not TPP). Key size ≥ 2048. **Domain whitelisting set** |
| T5 | **CA turnaround** | The CA must issue in **under 60 s**. Raise `server_timeout` (§7) if it is slower |
| T6 | **Token lifetime** | Note the access-token validity configured on the T1 integration. It drives `refresh_interval` (§6) |
| T7 | **WebSDK TLS chain** | The root and intermediate certificates of TPP's *web* certificate, as PEM. Becomes `trust_bundle_file` |

### 3.2 Network (new firewall flow)

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| **11** | **every Vault node** | TPP `/vedsdk/*`, `/vedauth/*` | 443 | Enrollment, retrieval, revocation and **token refresh** |

The plugin runs on whichever node is the **active** node. Open the flow from **all** nodes, or the first
leader election breaks issuance. Prove it from every node with
`docs/shared/conn_check.sh --hop flow11-vault-01-to-tpp` (and `-02`, `-03`). The `tpp-vault` targets
and hops are in `docs/shared/targets.conf`.

### 3.3 Vault side

- `plugin_directory` set in the server config of **every** node. It must be a **real directory, not a
  symlink**, on a filesystem **not mounted `noexec`**, and owned by the `vault` user.
- The same binary (same SHA-256) in that directory on **every** node, before the plugin is registered.
- An admin token able to write `sys/plugins/catalog` in the **root** namespace. The plugin catalog is
  root-only on Enterprise, while mounts live in `AUT`.

---

## 4. Install the binary on every node

Run [`examples/venafi-pki-install-node.sh`](examples/venafi-pki-install-node.sh) on each Vault node. It:

1. Verifies the release zip against the **published** SHA-256 for v0.16.0 linux/amd64:
   `53729133de9c3b2d465d2abd070d722e1ccd0d6cccb9b16c86aaca38031ba0e2`.
2. Extracts the binary and checks it against the `venafi-pki-backend.SHA256SUM` file shipped inside the zip.
3. Installs it as `<plugin_directory>/venafi-pki-backend` with mode `0750`, owned by `root:vault`.
4. Prints the **binary** SHA-256. This value is what you register in §5.

Expected binary SHA-256 for **v0.16.0 linux/amd64**:

```
48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec
```

> **Zip hash vs binary hash.** The release page publishes **zip** hashes. Vault's catalog needs the
> **binary** hash. Mixing them up gives `checksums did not match` at mount time.
>
> **Signature (optional, recommended for airgap):** the zip also contains a detached OpenPGP signature,
> `venafi-pki-backend_linux.sig`, issued by key fingerprint
> `AC2F327A4C25FBD4282EF02DD0C8AA8AA39E012D`. Get Venafi's public key from an official channel,
> confirm that fingerprint, then run
> `gpg --verify venafi-pki-backend_linux.sig venafi-pki-backend`.

**First-time `plugin_directory`:** if the directory is new to the server config, restart the nodes **one at
a time**: standbys first, then `vault operator step-down` on the leader and restart it last. Check
`vault operator raft list-peers` between each restart.

---

## 5. Register the plugin (root namespace)

```bash
export VAULT_ADDR=https://vault-vip.corp.example.com:8200
unset VAULT_NAMESPACE                       # catalog is root-only

vault plugin register \
    -sha256=48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec \
    -command=venafi-pki-backend \
    -version=v0.16.0 \
    secret venafi-pki-backend

vault plugin info -version=v0.16.0 secret venafi-pki-backend
```

> **Why `-version`:** pinning a version in the catalog lets you run 0.16.0 and 0.17.0 side by side
> and move each mount independently with `vault secrets tune -plugin-version` (§10). Without it you
> get a single unversioned entry, and upgrading means overwriting it in place. The plugin binary does
> not report its own version, so the catalog value is authoritative. Set it accurately.

---

## 6. Mount in `AUT` and configure the Venafi secret

### 6.1 Enable

```bash
vault secrets enable -namespace=AUT \
    -path=venafi-pki \
    -plugin-version=v0.16.0 \
    -description="Venafi TPP-backed TLS issuance" \
    -max-lease-ttl=2160h \
    venafi-pki-backend
```

### 6.2 Get tokens from TPP (once, as the service identity)

The plugin refreshes its own access token. It needs **two independent refresh tokens**:
`refresh_token` and `refresh_token_2`. Each refresh token is **single-use**, so having two is what
makes the hand-over safe. Run `vcert getcred` **twice**:

```bash
vcert getcred -u https://tpp.corp.example.com \
    --username svc-vault-pki --password-prompt \
    --client-id hashicorp-vault-by-venafi \
    --scope "certificate:manage,revoke" \
    --trust-bundle /etc/vault/tls/tpp-chain.pem --format json > /dev/shm/pair1.json
# ...repeat to /dev/shm/pair2.json
```

From **pair 1** take `access_token` and `refresh_token`. From **pair 2** take **only** `refresh_token`,
which becomes `refresh_token_2`. The two access tokens are **not** interchangeable.

```bash
umask 077
jq -j .access_token  /dev/shm/pair1.json > /dev/shm/access_token     # -j: no trailing newline
jq -j .refresh_token /dev/shm/pair1.json > /dev/shm/refresh_token
jq -j .refresh_token /dev/shm/pair2.json > /dev/shm/refresh_token_2
```

> `vault write key=@file` keeps any trailing newline, and a token with a newline is rejected by TPP.
> `jq -j` avoids that. The configure script also strips the newline.

### 6.3 Write the Venafi secret

```bash
vault write -namespace=AUT venafi-pki/venafi/tpp \
    url="https://tpp.corp.example.com" \
    access_token=@/dev/shm/access_token \
    refresh_token=@/dev/shm/refresh_token \
    refresh_token_2=@/dev/shm/refresh_token_2 \
    client_id="hashicorp-vault-by-venafi" \
    refresh_interval="12h" \
    zone='Certificates\Automation\Vault\AUT' \
    trust_bundle_file="/etc/vault/tls/tpp-chain.pem"
shred -u /dev/shm/pair*.json /dev/shm/*_token*
```

| Parameter | Value / rule |
|---|---|
| `url` | TPP base URL, no `/vedsdk` |
| `client_id` | Must be the **same** client id used in `vcert getcred` (default `hashicorp-vault-by-venafi`) |
| `refresh_interval` | Default 30 days, and validated to be ≤ the access-token lifetime. **Set it to ≤ ½ of the token lifetime.** Example: 24 h tokens → `12h` |
| `zone` | Default policy folder **below `\VED\Policy`**. Roles may override it |
| `trust_bundle_file` | A **path on every Vault node**, not the PEM content. Copy the same file to the same path on all nodes |

> ⚠️ **One token set = one Venafi secret, in one cluster.** When any secret refreshes, the other
> copies holding the same tokens break. Never write the same tokens to a second secret, mount,
> namespace or cluster. If the secret ever has to be **re-written**, get **fresh** tokens. The ones
> you originally supplied may already have been consumed by a refresh.
>
> **Tokens on the command line:** use the `@file` form shown above, from tmpfs. Never pass tokens as
> literal arguments; they would land in shell history and `ps`.

---

## 7. Roles

One role per **consumer and trust domain**. Each role maps to one TPP folder (`zone`), so TPP
inventory and ownership follow the role.

```bash
# Short-lived service certs for CI-deployed apps. Vault generates keys; keys are NOT stored in Vault.
vault write -namespace=AUT venafi-pki/roles/web-aut \
    venafi_secret=tpp \
    zone='Certificates\Automation\Vault\AUT\Web' \
    key_type=rsa key_bits=2048 \
    chain_option=last \
    issuer_hint=m \
    ttl=720h max_ttl=2160h \
    generate_lease=true \
    store_by=serial store_pkey=false \
    server_timeout=180

# CSR-only role for hosts that keep their own keys (AAP-managed servers)
vault write -namespace=AUT venafi-pki/roles/host-csr-aut \
    venafi_secret=tpp \
    zone='Certificates\Automation\Vault\AUT\Hosts' \
    issuer_hint=m ttl=2160h max_ttl=8760h \
    no_store=true
```

| Parameter | Default (v0.16.0) | Recommendation |
|---|---|---|
| `venafi_secret` | — (required) | `tpp` |
| `zone` | from the secret | Always set it per role. Keeps folders and ownership separate |
| `key_type` / `key_bits` / `key_curve` | `rsa` / `2048` / `P256` | Must satisfy the folder's locked key policy, or issuance fails |
| `chain_option` | `last` | `last` = leaf first, then chain |
| `ttl` / `max_ttl` | — | Honoured **only** if the CA template allows flexible validity. For **Microsoft, DigiCert or Entrust** CAs also set **`issuer_hint`** (`m`, `d`, `e`) |
| `generate_lease` | `false` | `true` if consumers should get a lease. Revoking the lease then revokes the certificate in TPP; needs the `revoke` scope |
| `store_by` | `serial` | `serial` or `hash` (needed for *prevent re-issue local*) |
| `store_pkey` | `false` | **Keep `false`** unless you need prevent-re-issue. If `true`, private keys sit in Vault storage. Safe only with ≥ v0.16.0 because of the cross-role fix |
| `no_store` | `false` | `true` = store nothing in Vault. Revoke via Vault then needs the serial or thumbprint from your own records |
| `server_timeout` | `180` (s) | Raise it if the CA is slow (see T5) |
| `min_cert_time_left` | `720h` | With prevent-re-issue: return the cached cert if it has at least this much validity left |
| `ignore_local_storage` | `false` | `true` forces a new cert on every call |
| `service_generated_cert` | `false` | Leave `false`. `true` lets TPP generate the key, which conflicts with T4 |

---

## 8. Consumer policy (least privilege)

The role has no domain restriction, so **restrict names in the ACL** with `allowed_parameters`
globs. Full file: [`examples/venafi-pki-consumer.hcl`](examples/venafi-pki-consumer.hcl).

```hcl
path "venafi-pki/issue/web-aut" {
  capabilities = ["create", "update"]
  # Once allowed_parameters is set, any parameter NOT listed is rejected.
  allowed_parameters = {
    "common_name"        = ["*.aut.corp.example.com"]
    "alt_names"          = []   # [] = any value; tighten if consumers send SANs
    "ttl"                = []
    "private_key_format" = []
    "custom_fields"      = []   # drop if the TPP folder needs none
  }
}
path "venafi-pki/venafi/*" { capabilities = ["deny"] }   # tokens: admins only
path "venafi-pki/roles/*"  { capabilities = ["deny"] }
```

Attach the policy to the existing auth roles from guide `01`:

| Consumer | Auth role | How it calls |
|---|---|---|
| CloudBees CI | `auth/jwt-ci` role for the app folder | `vault write -format=json venafi-pki/issue/web-aut common_name=…` in the build (same pattern as the KV read in guide `02`) |
| CDRO | `auth/jwt-cdro` | The ZeroTrust plugin is **KV-only**. Hand off to a job, or to AAP (guide `07`, Pattern B), which calls `issue/` |
| AAP | `auth/approle` (guide `04`) or the guide `07` JWT | `community.hashi_vault.vault_write` to `venafi-pki/issue/<role>`, or `sign/` with a CSR made on the node |

> **Audit:** the audit device HMACs response fields by default, so `private_key` is **not** written in
> clear to the SIEM. Do **not** add `private_key` to `audit_non_hmac_response_keys` on this mount.

---

## 9. Use it

```bash
# Issue (Vault generates the key)
vault write -namespace=AUT -format=json venafi-pki/issue/web-aut \
    common_name="app1.aut.corp.example.com" \
    alt_names="app1.aut.corp.example.com,app1-int.aut.corp.example.com" ttl=720h

# Sign (consumer keeps the key)
openssl req -new -newkey rsa:2048 -nodes -keyout app1.key -out app1.csr \
    -subj "/CN=host01.aut.corp.example.com"
vault write -namespace=AUT -format=json venafi-pki/sign/host-csr-aut csr=@app1.csr

# List and read stored certs (roles with store_by and without no_store)
vault list -namespace=AUT venafi-pki/certs
vault read -namespace=AUT venafi-pki/cert/<serial>

# Revoke in TPP
vault write -namespace=AUT venafi-pki/revoke/web-aut serial_number="<serial>"
# ...or revoke the lease, when generate_lease=true
vault lease revoke -namespace=AUT venafi-pki/issue/web-aut/<lease-id>
```

TPP custom fields, where the folder requires them:
`custom_fields="AppOwner=automation,CostCentre=1234"`. For a multi-value field, repeat the name.

---

## 10. Vault Enterprise 1.21 operational notes

| Topic | What to do |
|---|---|
| **Every node, same binary** | A mismatched SHA on a standby surfaces only **after failover**, as `checksums did not match`. The install script prints the hash; record it per node |
| **Plugin upgrade (→ v0.17.0)** | Install the new binary on all nodes under a **new filename** (`venafi-pki-backend-0.17.0`). Register it with `-version=v0.17.0 -command=venafi-pki-backend-0.17.0`. Then run `vault secrets tune -namespace=AUT -plugin-version=v0.17.0 venafi-pki/` and `vault plugin reload -type=secret -plugin=venafi-pki-backend -scope=global`. Roll back by tuning back to `v0.16.0`. Keep the old binary until you are sure |
| **Performance replication** | If `AUT` is replicated to a PR secondary, the mount and the **Venafi secret (tokens)** are replicated, and the secondary may refresh **the same single-use tokens**. Either create the mount with `-local` on the primary (and configure a separate TPP identity on each cluster), or exclude the path with a paths filter. **[Verify in your topology before enabling PR on this namespace]** |
| **DR replication** | Fine. A DR secondary is passive and does not refresh tokens until promoted |
| **Token refresh failing quietly** | When both refresh tokens are spent or expired, every issue call fails with HTTP 401 from TPP. Alert on that string in the Vault server log, and keep the TPP refresh-token lifetime well above `refresh_interval` |
| **Namespaces** | The catalog is in root. The mount, the Venafi secret, roles and policies are all in `AUT`. A mount in another namespace needs **its own** TPP identity (see the ⚠️ in §6) |
| **mlock / tmp** | No special handling. The plugin is a normal external plugin process started by Vault |
| **Backups** | Raft snapshots include the Venafi secret, with live tokens. Treat snapshots as secret material |

---

## 11. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `could not execute files outside of configured plugin directory` | `plugin_directory` is a symlink, or the path in the catalog differs | Use a real directory. `-command` is just the filename |
| `checksums did not match` (only on some nodes or after failover) | Binary differs on that node, or the **zip** hash was registered | Re-run the install script on every node. Register the **binary** hash |
| `fork/exec … permission denied` | `noexec` mount or wrong owner/mode | Move `plugin_directory` off `noexec`. `chown root:vault`, `chmod 0750` |
| `x509: certificate signed by unknown authority` (to TPP) | `trust_bundle_file` missing or wrong on the **active** node | Same PEM, same path, on all nodes |
| `401` / `invalid_grant` after it had worked | Tokens consumed by another copy of the secret, or both refresh tokens expired | Get **two new** token pairs (§6.2) and re-write the secret. Find the duplicate secret |
| `403` / `Insufficient scope` on revoke | Integration granted without `revoke` | Add the scope on T1 and get new tokens |
| `PolicyLocked` / `… does not match policy` | Role key type/size or DN conflicts with the folder's locked values | Align the role with the folder (T4) |
| Cert issued, but `ttl` ignored | CA template has fixed validity, or `issuer_hint` missing | Set `issuer_hint`. Ask the PKI team for a flexible-validity template |
| Times out at ~180 s | CA slower than `server_timeout` | Raise `server_timeout` on the role. Check CA queueing in TPP |
| Consumer gets `permission denied` on `issue/` | CN outside the `allowed_parameters` glob | Fix the request, or widen the policy deliberately |

---

## 12. Verification

1. On every node: `sha256sum <plugin_directory>/venafi-pki-backend` shows `48eec755…c99ec`.
2. `vault plugin info -version=v0.16.0 secret venafi-pki-backend` shows the same sha256.
3. `vault secrets list -namespace=AUT -detailed` shows `venafi-pki/` with
   `plugin_version=v0.16.0`.
4. Issue a test cert from `web-aut`. It appears in TPP under the role's folder, with the CA chain
   you expect.
5. **Cross-role check (the 0.16.0 fix):** with a token holding **only** the `web-aut` policy, `revoke`
   on `host-csr-aut` is **denied**.
6. Policy check: issue with `common_name=evil.example.com` → `permission denied`.
7. Revoke the test cert. TPP shows it revoked, and CRL/OCSP reflect it within the CA's publish interval.
8. Fail over (`vault operator step-down`), then issue again. This proves the binary, trust bundle and
   firewall flow #11 are correct on the new leader.
9. After `refresh_interval` has passed, issue again **without re-writing the secret**. This proves
   token refresh works.

---

## 13. Sources

- Plugin README at tag v0.16.0 — <https://github.com/Venafi/vault-pki-backend-venafi/blob/v0.16.0/README.md>
- Release v0.16.0 (security fixes, zip hashes) — <https://github.com/Venafi/vault-pki-backend-venafi/releases/tag/v0.16.0>
- Release v0.17.0 — <https://github.com/Venafi/vault-pki-backend-venafi/releases/tag/v0.17.0>
- Role and secret fields and defaults: `plugin/pki/path_roles.go`, `path_venafi_secrets.go` at tag v0.16.0
- Vault plugin catalog and versioning — <https://developer.hashicorp.com/vault/docs/plugins/plugin-management>
- Vault plugin upgrade procedure — <https://developer.hashicorp.com/vault/docs/upgrading/plugins>
- VCert CLI `getcred` — <https://github.com/Venafi/vcert/blob/master/README-CLI-PLATFORM.md>
