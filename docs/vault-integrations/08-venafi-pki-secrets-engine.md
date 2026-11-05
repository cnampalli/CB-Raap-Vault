# 08 — Vault ⇄ Venafi (CyberArk Certificate Manager) PKI secrets engine — reference

> **Scope:** Vault issues X.509 **TLS certificates** while **Venafi TPP** (now *CyberArk Certificate
> Manager, Self-Hosted*) is the policy authority and the enterprise CA signs. Vault never holds a CA
> key, and every certificate lands in the TPP inventory, so the PKI team sees it. Kubernetes workloads
> get the same certificates through **cert-manager** (or the Vault Agent Injector webhook).
>
> **This is the "how it works and why" reference. To _do_ the integration, follow the step-by-step,
> team-by-team runbook: [`09-venafi-pki-team-runbook.md`](09-venafi-pki-team-runbook.md).**
>
> **Pinned versions**
>
> | Component | Version | Notes |
> |---|---|---|
> | Vault Enterprise | **1.20.8+ent** | Raft, VMs, namespace **`AUT`** (guide `01`). In `vault-enterprise-config` the same namespace is the `automation` application |
> | `venafi-pki-backend` | **v0.16.0** (2026-07-02) | Embeds vcert **v5.13.7**. Binary already placed on every node by **Ansible** |
> | TPP / Certificate Manager, Self-Hosted | must offer the `hashicorp-vault-by-venafi` API integration with token refresh | API integrations exist from 20.1 |
> | cert-manager | **≥ 1.15** (checked against 1.21.3 source) | `serviceAccountRef` needs ≥ 1.12, `serviceAccountRef.audiences` needs ≥ 1.15 |
> | Terraform `hashicorp/vault` | 3.23.0 (unchanged) | No `vault_plugin` / mount `plugin_version` until 4.4.0, so `vault-enterprise-config` uses `vault_generic_endpoint` |
>
> **Not in scope:** code signing. Container-signing keys stay in CodeSign Protect and are **never** in
> Vault (see [`../container-signing/03-vault-secrets.md`](../container-signing/03-vault-secrets.md)).
>
> **Files**
>
> | File | Who runs it | Purpose |
> |---|---|---|
> | [`examples/ansible/venafi-pki-verify.yml`](examples/ansible/venafi-pki-verify.yml) | Vault team | Prove the Ansible-placed binary on **every** node (hash, owner, mode, `noexec`, symlink, trust bundle, TLS to TPP) |
> | [`examples/venafi-pki-verify-node.sh`](examples/venafi-pki-verify-node.sh) | Vault team | The same checks on one node, without Ansible |
> | [`examples/venafi-pki-configure.sh`](examples/venafi-pki-configure.sh) | Vault team | CLI alternative to the Terraform in `vault-enterprise-config`: register, mount, roles, policies |
> | [`examples/venafi-pki-bootstrap-secret.sh`](examples/venafi-pki-bootstrap-secret.sh) | Vault team, then Venafi team | Write the Venafi secret (TPP tokens) once, through a wrapped write-only token |
> | [`examples/venafi-pki-consumer.hcl`](examples/venafi-pki-consumer.hcl) | Vault team | Consumer policy (issue / sign / cert-manager variants) |
> | [`examples/k8s/`](examples/k8s/) | Kubernetes team | cert-manager RBAC, ClusterIssuer, demo Certificate, approver-policy, Agent Injector demo, `verify-cert-manager.sh` |
> | [`../../tools/venafi_pki_proof.py`](../../tools/venafi_pki_proof.py) | Anyone with a consumer token | Evidence report that Venafi really backs Vault's certificates |
> | [`examples/venafi-pki-install-node.sh`](examples/venafi-pki-install-node.sh) | Vault team | Fallback installer only (Ansible is the primary path) |

---

## 1. Why v0.16.0 and not older

v0.16.0 is a **security release**. Do not deploy anything older.

| Fix | Why it matters |
|---|---|
| CWE-639: prevent **cross-role private key disclosure** (VC-53759) | Before 0.16.0, a token allowed to read certificates under one role could read another role's stored private key. This matters whenever `store_pkey=true` |
| CWE-639: **cross-role revoke and delete** (VC-53760) | A consumer of role A could revoke role B's certificates |
| CWE-476: nil dereference on a **non-existent role** (VC-53758) | DoS of the plugin process |
| Certificate revocation identifiers fixed | Revocation now targets the right certificate in TPP |

> **v0.17.0 is already out (2026-08-26).** It adds `key_bits`/`key_type` to the role read output, a
> local-certificate **delete** endpoint, and vcert v5.13.9. Nothing in this guide changes for 0.17.0.
> §12 shows the in-place upgrade.

---

## 2. How it works

```
 Consumer                                   Vault Ent 1.20.8 (ns AUT)                      Venafi TPP               Enterprise CA
 ────────                                   ─────────────────────────                      ──────────               ─────────────
 CI / AAP / CDRO hand-off                    venafi-pki/issue/<role>  (Vault makes key+CSR)
 cert-manager (K8s)  ─ sign/<role> + CSR ──► venafi-pki/sign/<role>   (CSR only, key stays in the cluster)
 Vault Agent Injector ─ issue/<role> ──────►        │
                                                    │ 1 (if due) refresh access token  POST /vedauth/authorize/token
                                                    │ 2 POST /vedsdk/certificates/request  ──────► folder policy ─────► signs
                                                    │   (custom field Origin="HashiCorp Vault")     (DN, key, domains)
                                                    │ 3 poll /vedsdk/certificates/retrieve ◄──────  cert + chain ◄──────
 ◄── certificate, issuing_ca, ca_chain[], serial_number, expiration, (private_key on issue/) ──┘
```

**Facts this guide relies on** (read from the v0.16.0 / vcert v5.13.7 / cert-manager v1.21.3 sources,
not from marketing pages):

| Topic | Behaviour |
|---|---|
| **Key generation** | `issue/` — the **plugin** generates the key pair locally and sends TPP only a CSR. `sign/` — the caller sends a CSR, Vault never sees the key. Prefer `sign/` for long-lived identities and for Kubernetes |
| **Name control** | Roles have **no `allowed_domains`**. TPP's folder **domain whitelist** (CN and SANs) is the authoritative control. Vault ACL `allowed_parameters` is only a pre-filter (see §9 — it is bypassable) |
| **`sign/` ignores name parameters** | `sign/` accepts only `csr`, `ttl`, `custom_fields`, `retry`; CN and SANs come from the CSR. `common_name`, `alt_names`, `ip_sans`, `uri_sans`, `exclude_cn_from_sans` are ignored (with a warning) |
| **CN is not copied into SANs** | On `issue/`, the plugin puts only `alt_names`/`ip_sans` into the SANs. Send the CN in `alt_names` too, or modern TLS clients will reject the certificate |
| **Origin marker** | Every request carries the TPP custom field **`Origin = "HashiCorp Vault"`**, written onto the certificate object. That is how TPP proves a certificate came through Vault (proof check P9) |
| **Response fields** | `certificate`, `issuing_ca`, `ca_chain` (list), `certificate_chain` (leaf+chain, one string), `serial_number`, `expiration`, `private_key` (issue only), `certificate_uid` (unless `no_store`). These are the fields cert-manager parses |
| **`chain_option`** | Position of the **root**: `last` (default) = `ca_chain` is intermediates then root, so `issuing_ca = ca_chain[0]` is the real issuer. `first` puts the root first — **cert-manager then records the root as the issuer**. Use `last` |
| **`key_type: any`** | Valid for `sign/` only; `issue/` with `any` is refused ("only signing") |
| **Tokens: first write** | Writing the Venafi secret makes the **active node call TPP immediately** and spend the first refresh token. A successful write therefore already proves flow #11, the trust bundle, `client_id` and scope |
| **Tokens: refresh** | Lazy: on an `issue/`/`sign/` call after `next_refresh`. Only the **active node** refreshes (performance standbys forward). `refresh_interval` is **clamped** to (access-token lifetime − 30 s); it is not rejected |
| **Tokens: grant expiry** | The TPP grant has a fixed `refresh_until`. After it, refresh fails and **all issuance stops** until the secret is re-bootstrapped with new `vcert getcred` tokens. Calendar it (runbook V14/P11) |
| **Endpoints** | `venafi/<name>`, `roles/<name>`, `issue/<role>`, `sign/<role>`, `revoke/<role>`, `cert/<id>`, `certs/` |

---

## 3. Prerequisites

### 3.1 TPP side (owner: Venafi / PKI team — runbook P1–P8)

| # | Item | Detail |
|---|---|---|
| T1 | **API integration** | Application ID **`hashicorp-vault-by-venafi`** (must equal the secret's `client_id`). Scope **`certificate:manage,revoke`** (drop `revoke` if Vault must never revoke). **Token refresh enabled.** Note the token validity and grant validity |
| T2 | **Service identity** | `svc-vault-pki` (local or AD), allowed to use T1 only. No interactive use. Password in your PAM vault |
| T3 | **Policy folders** | `\VED\Policy\Certificates\Vault\AUT\{Web,Hosts,K8s}`. Grant T2 **View, Read, Write, Create** (+ **Revoke** if T1 has `revoke`) on `…\AUT`, nothing above it. Never *Private Key Read* |
| T4 | **Folder policy** | Subject O/OU/L/ST/C locked. CA template set and locked. Management type **Enrollment**. CSR generation **not** locked to *Service Generated* (both `issue/` and `sign/` send a CSR). Key ≥ RSA 2048 (or the EC curves you allow). **Domain whitelist set, covering SANs.** Wildcards off unless needed. **Disable Automatic Renewal = Yes** (consumers renew) |
| T5 | **CA turnaround** | Under 60 s preferred. The plugin waits `server_timeout` (default 180 s) |
| T6 | **Flexible validity** | If consumers must choose `ttl`, the CA template must allow it, and the role needs `issuer_hint` (`m`/`d`/`e`). Otherwise the CA's fixed validity wins (cert-manager copes either way) |
| T7 | **Trust material** | (a) TPP **web** chain PEM → `trust_bundle_file` on every Vault node. (b) Enterprise **root** (and issuing) CA PEM → proof check P7 and the Kubernetes team |
| T8 | **Read-only proof token** | A separate integration (e.g. `venafi-pki-proof`, scope `certificate`) for whoever runs the proof tool. Never reuse T1's tokens |

### 3.2 Network

| # | Source | Destination | Port | Purpose |
|---|---|---|---|---|
| **11** | **every** Vault node | TPP `/vedsdk/*`, `/vedauth/*` | 443 | Enrollment, retrieval, revocation, **token refresh**. The active node does it, and any node can become active |
| **12** | **every** Vault node | each Kubernetes API server | 6443 | `TokenReview` for the Kubernetes auth login used by cert-manager / the Agent Injector |
| **13** | Kubernetes nodes (cert-manager, agent pods) | `<vault-vip>` | 8200 | Login + `sign/` / `issue/` |
| **14** | Venafi engineer's admin host | `<vault-vip>` | 8200 | One-off: write the Venafi secret (bootstrap), and the proof run |

Prove #11 from **each** node: `docs/shared/conn_check.sh --hop flow11-vault-0N-to-tpp` (and the
Ansible play with `-e tpp_host=…`). #12 and #13 have targets in `docs/shared/targets.conf` too.

### 3.3 Vault side

- `plugin_directory` set in the server config of **every** node — a **real directory, not a symlink**,
  **not on a `noexec`** filesystem, owned so the `vault` user can execute the binary.
- The **same binary (same SHA-256)** on every node before registration (Ansible has done this).
- An admin token with `sudo` on **root** `sys/plugins/catalog/*` (the catalog is root-only) and admin
  rights in `AUT`. In `vault-enterprise-config` the root pipeline's `jenkins-ci-admin` policy now has it.

---

## 4. The plugin binary (placed by Ansible)

Ansible has dropped `venafi-pki-backend` on the nodes. **Prove it, node by node, before registering**
(runbook V2) — a wrong hash on a standby only surfaces after a failover, as `checksums did not match`.

```bash
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml -e tpp_host=tpp.corp.example.com
# or, on one node:
TPP_HOST=tpp.corp.example.com docs/vault-integrations/examples/venafi-pki-verify-node.sh
```

Expected **binary** SHA-256 for **v0.16.0 linux/amd64**:

```
48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec
```

> **Zip hash vs binary hash.** The release page publishes the **zip** hash
> (`53729133de9c3b2d465d2abd070d722e1ccd0d6cccb9b16c86aaca38031ba0e2`). The catalog needs the
> **binary** hash above. Registering the zip hash gives `checksums did not match` at mount time.
>
> **Signature (recommended for airgap):** the zip also holds `venafi-pki-backend_linux.sig`, from key
> fingerprint `AC2F327A4C25FBD4282EF02DD0C8AA8AA39E012D`. Get Venafi's public key from an official
> channel, confirm the fingerprint, then `gpg --verify venafi-pki-backend_linux.sig venafi-pki-backend`.

**If `plugin_directory` was newly added to the config**, restart nodes **one at a time**: standbys first,
then `vault operator step-down` on the leader and restart it last; check `vault operator raft list-peers`
between restarts. `vault-integrations/examples/venafi-pki-install-node.sh` exists only as a fallback for
a node Ansible cannot reach.

---

## 5. Register the plugin (root namespace)

**Terraform (recommended)** — `vault-enterprise-config`, `configs/root-namespace.yaml`:

```yaml
plugins:
  - type: "secret"
    name: "venafi-pki-backend"
    version: "v0.16.0"
    command: "venafi-pki-backend"
    sha256: "48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec"
```

Applied by the root pipeline (module `vault-plugin-catalog`). Removing an entry does **not** deregister
it, on purpose: a mount may still run that version.

**CLI:**

```bash
unset VAULT_NAMESPACE                       # catalog is root-only
vault plugin register \
    -sha256=48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec \
    -command=venafi-pki-backend -version=v0.16.0 \
    secret venafi-pki-backend
vault plugin info -version=v0.16.0 secret venafi-pki-backend
```

> **Why `-version`:** it lets 0.16.0 and 0.17.0 sit side by side, and each mount moves independently
> with `vault secrets tune -plugin-version` (§12). The binary does not report its own version, so the
> catalog value is authoritative — set it accurately.

---

## 6. Mount in `AUT`

**Terraform (recommended)** — `configs/applications/automation.yaml` → `secret_engines.venafi_pki`
(module `vault-secret-venafi-pki`). It creates the mount pinned to `plugin_version`, tunes it, and writes
the roles and generated consumer policies. See `vault-enterprise-config/docs/VENAFI_PKI.md`.

**CLI:**

```bash
vault secrets enable -namespace=AUT -path=venafi-pki -plugin-version=v0.16.0 \
    -description="Venafi TPP-backed TLS issuance" -max-lease-ttl=2160h venafi-pki-backend
vault secrets list -namespace=AUT -detailed -format=json | jq '."venafi-pki/" | {type, plugin_version, running_plugin_version}'
```

If `AUT` is (or will be) **performance-replicated**, create the mount with `-local` (Terraform:
`local: true`). Otherwise the secondary inherits the same single-use refresh tokens (§12).

---

## 7. The Venafi secret (TPP tokens)

**Not in Terraform, on purpose.** The secret holds an access token and two refresh tokens. Refresh tokens
are single-use and the plugin rotates them itself, so a Terraform copy would be stale after the first
refresh, would sit in clear text in state, and the next apply would overwrite the live tokens.

**Who writes it:** the **Venafi team**, through a write-only, response-wrapped, 30-minute token that the
Vault team issues — so TPP tokens never pass through the Vault team, and the bootstrap token cannot read
the secret back (runbook V8 → P9 → V9):

```bash
# Vault team
NS=AUT ./venafi-pki-bootstrap-secret.sh issue-token        # prints a wrapping token
# Venafi team (needs vcert v5, vault, jq, a terminal)
NS=AUT VAULT_WRAPPED_TOKEN=... TPP_URL=https://tpp.corp.example.com TPP_CHAIN=./tpp-chain.pem \
  ZONE='Certificates\Vault\AUT' ./venafi-pki-bootstrap-secret.sh write-secret
```

What `write-secret` does:

1. Unwraps the bootstrap token (fails loudly if someone else already used it).
2. Runs **`vcert getcred` twice** — the plugin needs **two independent refresh tokens**:

   ```bash
   vcert getcred -u https://tpp.corp.example.com --username svc-vault-pki \
       --client-id hashicorp-vault-by-venafi --scope "certificate:manage,revoke" \
       --trust-bundle ./tpp-chain.pem --format json
   ```

   There is **no `--password-prompt` flag**: leaving `--password` out makes vcert prompt on the terminal,
   which keeps the password out of `argv`/`ps`. `--client-id` **must** be given — vcert's default is
   `vcert-cli`, and a token for the wrong client is rejected by the plugin's refresh.
3. Takes `access_token` + `refresh_token` from pair 1 and **only** `refresh_token` from pair 2
   (`refresh_token_2`), written with `jq -j` (no trailing newline — `key=@file` keeps one, and TPP rejects it).
4. Writes the secret. The active node calls TPP right away (first refresh).
5. Revokes the bootstrap token, shreds the files, and prints **`refresh_until`** — the grant expiry date.

| Field | Value / rule |
|---|---|
| `url` | TPP base URL, no `/vedsdk` |
| `client_id` | `hashicorp-vault-by-venafi` (plugin default) — same as in `getcred` |
| `refresh_interval` | e.g. `12h`. Effective value is clamped to (access-token lifetime − 30 s). `vault read` shows the effective value |
| `zone` | Default folder **below `\VED\Policy`**; roles override it |
| `trust_bundle_file` | A **path on every Vault node**, not PEM content |

> ⚠️ **One token set = one Venafi secret in one cluster.** Never write the same tokens to a second secret,
> mount, namespace or cluster: when one refreshes, the others break. To re-write the secret, always get
> **fresh** tokens (the originals are already spent by the first refresh).

---

## 8. Roles

One role per **consumer type and trust domain**; each maps to one TPP folder.

```bash
# Server certs; Vault generates keys; keys NOT stored in Vault.
vault write -namespace=AUT venafi-pki/roles/web-aut venafi_secret=tpp \
    zone='Certificates\Vault\AUT\Web' key_type=rsa key_bits=2048 chain_option=last issuer_hint=m \
    ttl=720h max_ttl=2160h generate_lease=true store_by=serial store_pkey=false server_timeout=180

# CSR-only for hosts that keep their keys (AAP-managed servers).
vault write -namespace=AUT venafi-pki/roles/host-csr-aut venafi_secret=tpp \
    zone='Certificates\Vault\AUT\Hosts' key_type=any chain_option=last issuer_hint=m \
    ttl=2160h max_ttl=8760h no_store=true

# Kubernetes cert-manager (sign/). chain_option MUST be last.
vault write -namespace=AUT venafi-pki/roles/k8s-cert-manager venafi_secret=tpp \
    zone='Certificates\Vault\AUT\K8s' key_type=any chain_option=last issuer_hint=m \
    ttl=720h max_ttl=2160h no_store=true generate_lease=false
```

| Parameter | Default (v0.16.0) | Recommendation |
|---|---|---|
| `venafi_secret` | — (required) | `tpp` |
| `zone` | from the secret | Always set per role; keeps folders and ownership separate |
| `key_type` / `key_bits` / `key_curve` | `rsa` / `2048` / `P256` | `issue/` roles: must match the folder's locked key policy. `sign/` roles: `any` |
| `chain_option` | `last` | **Root position.** Keep `last` (required for cert-manager) |
| `ttl` / `max_ttl` | — | Honoured **only** with a flexible-validity CA template **and** `issuer_hint` (`m`, `d`, `e`) |
| `generate_lease` | `false` | `true` gives a lease; revoking it revokes in TPP (needs `revoke` scope). Keep `false` for cert-manager |
| `store_by` | `serial` | `serial`, `hash` (needed for prevent-re-issue) or `cn` |
| `store_pkey` | `false` | **Keep `false`.** Safe only with ≥ v0.16.0 |
| `no_store` | `false` | `true` = keep nothing in Vault (sign/ roles, cert-manager) |
| `server_timeout` | `180` s | Raise for a slow CA |
| `min_cert_time_left` / `ignore_local_storage` | `720h` / `false` | Prevent-re-issue tuning (issue/ with `store_by=hash`) |
| `service_generated_cert` | `false` | Leave `false`; `true` conflicts with T4 |

---

## 9. Consumer policies — and their limits

`vault-enterprise-config` generates one per role (`venafi-pki-<role>`); the hand-written equivalent is
[`examples/venafi-pki-consumer.hcl`](examples/venafi-pki-consumer.hcl). Paths are relative to `AUT`.

```hcl
path "venafi-pki/issue/web-aut" {
  capabilities = ["create", "update"]
  allowed_parameters = {
    "common_name" = ["*.aut.corp.example.com"]
    "alt_names"   = ["*.aut.corp.example.com"]
    "ttl" = [], "private_key_format" = [], "custom_fields" = []
  }
}
path "venafi-pki/sign/k8s-cert-manager" {          # cert-manager: exactly what it sends (v1.21)
  capabilities = ["create", "update"]
  allowed_parameters = { "csr" = [], "ttl" = [], "common_name" = [], "alt_names" = [], "ip_sans" = [],
                         "uri_sans" = [], "exclude_cn_from_sans" = [], "custom_fields" = [] }
}
path "venafi-pki/venafi/*" { capabilities = ["deny"] }
path "venafi-pki/roles/*"  { capabilities = ["deny"] }
```

**Tested on Vault 1.20 with real tokens** (12 cases; see §15):

| Request | Result |
|---|---|
| `issue/` CN inside the glob | allowed |
| `issue/` CN `evil.example.com` | **403** |
| `issue/` with an unlisted parameter (`ip_sans`) | **403** |
| `issue/` `alt_names` as a JSON list containing `evil.com` | **403** (checked per element) |
| `issue/` `alt_names="evil.com,x.aut.corp.example.com"` | **allowed — certificate contains `DNS:evil.com`** |
| cert-manager's exact `sign/` payload | allowed; response has `certificate`, `issuing_ca`, 2-element `ca_chain` |
| `sign/` with an extra parameter (`key_password`) | **403** |
| reading `roles/*` or `venafi/*` | **403** |

> **So: the ACL is a pre-filter, not the control.** Vault globs match commas, and on `sign/` the names
> come from the CSR. The TPP folder's **domain whitelist (CN and SANs)** must be set (T4). For
> Kubernetes, add **approver-policy** inside the cluster (`examples/k8s/03-approver-policy.yaml`).
>
> **Optional, Enterprise only — Sentinel EGP** to check every name on `issue/`. *Not executed here*
> (Sentinel is not in Vault Community); test it in a non-production namespace first:
>
> ```
> import "strings"
> import "types"
> suffix = ".aut.corp.example.com"
> names = func() {
>   out = []
>   d = request.data else {}
>   if "common_name" in keys(d) { append(out, d.common_name) }
>   if "alt_names" in keys(d) {
>     raw = d.alt_names
>     parts = raw
>     if types.type_of(raw) is "string" { parts = strings.split(raw, ",") }
>     for parts as p { append(out, strings.trim_space(p)) }
>   }
>   return out
> }
> main = rule { all names() as n { strings.has_suffix(n, suffix) } }
> ```
>
> `vault write -namespace=AUT sys/policies/egp/venafi-pki-names policy=@venafi-pki-names.sentinel
> paths="venafi-pki/issue/*" enforcement_level="hard-mandatory"`

**Audit:** the audit device HMACs response fields, so `private_key` is not written in clear to the SIEM.
Do **not** add `private_key` to `audit_non_hmac_response_keys` on this mount.

---

## 10. Consumers

| Consumer | Auth | Path | Notes |
|---|---|---|---|
| CloudBees CI | `auth/jwt-ci` role for the app folder | `issue/web-aut` | `vault write -format=json venafi-pki/issue/web-aut common_name=… alt_names=…` in the build |
| CDRO | `auth/jwt-cdro` | — | The ZeroTrust plugin is KV-only. Hand off to a job, or to AAP (guide `07`) |
| AAP | AppRole (guide `04`) or the guide `07` JWT | `issue/` or `sign/host-csr-aut` | `community.hashi_vault.vault_write` |
| **Kubernetes — cert-manager** (primary) | Kubernetes auth, role `cert-manager-venafi`, audience `vault://vault-venafi` | `sign/k8s-cert-manager` | ClusterIssuer in `examples/k8s/01-*.yaml`. Keys stay in the cluster. RBAC in `00-*.yaml` |
| **Kubernetes — Vault Agent Injector** (webhook, alternative) | Kubernetes auth, role per app SA | `issue/web-aut` via `pkiCert` | `examples/k8s/04-*.yaml`. Re-issues near expiry, not on every render |

**Kubernetes auth from an external Vault** (VMs): Vault stores **no** reviewer token; it calls
`TokenReview` with the caller's own token. Therefore the caller's ServiceAccount needs
`system:auth-delegator`, and that token must also carry the **API server's audience** — which is why the
ClusterIssuer lists it in `serviceAccountRef.audiences`. In `vault-enterprise-config` the Kubernetes
role binds `audience: "vault://vault-venafi"`, so a token minted for any other issuer is refused.

---

## 11. Use it (CLI)

```bash
vault write -namespace=AUT -format=json venafi-pki/issue/web-aut \
    common_name="app1.aut.corp.example.com" alt_names="app1.aut.corp.example.com,app1-int.aut.corp.example.com" ttl=720h

openssl req -new -newkey rsa:2048 -nodes -keyout host01.key -out host01.csr \
    -subj "/CN=host01.aut.corp.example.com" -addext "subjectAltName=DNS:host01.aut.corp.example.com"
vault write -namespace=AUT -format=json venafi-pki/sign/host-csr-aut csr=@host01.csr

vault list -namespace=AUT venafi-pki/certs                      # roles that store certs
vault write -namespace=AUT venafi-pki/revoke/web-aut serial_number="<serial>"
```

TPP custom fields, where the folder requires them: `custom_fields="AppOwner=automation,CostCentre=1234"`.

---

## 12. Vault Enterprise 1.20 operational notes

| Topic | What to do |
|---|---|
| **Every node, same binary** | A wrong hash on a standby surfaces only **after failover**. Re-run the Ansible verify play after every Ansible change to the plugin dir |
| **Upgrade (→ v0.17.0)** | Ansible places `venafi-pki-backend-0.17.0` (new file name) on all nodes. Register `-version=v0.17.0 -command=venafi-pki-backend-0.17.0` (Terraform: second `plugins[]` entry). Tune the mount (`plugin_version: v0.17.0`), then `vault plugin reload -type=secret -plugin=venafi-pki-backend -scope=global`. Roll back by tuning to `v0.16.0` and reloading |
| **Performance replication** | If `AUT` is replicated, a non-local mount replicates the **Venafi secret (tokens)** and the secondary can spend the same single-use tokens. Use `-local` (and a separate TPP identity per cluster) or a paths filter. **[Verify in your topology]** |
| **DR replication** | Fine: a DR secondary is passive until promoted. After promotion, issue once to confirm the tokens still refresh |
| **Grant expiry** | Record `refresh_until` printed by the bootstrap. Re-bootstrap ≥ 30 days before it. Nothing else warns you |
| **Silent token failure** | Both refresh tokens spent or expired → every issue fails with TPP 401 / `invalid_grant`. Alert on those strings in the server log, and run a daily synthetic issue (`venafi_pki_proof.py` on a schedule) |
| **TPP outage** | New issuance fails; issued certificates keep working. cert-manager retries with back-off |
| **Namespaces** | Catalog in root; mount, secret, roles, policies in `AUT`. A mount in another namespace needs its **own** TPP identity |
| **Backups** | Raft snapshots contain the Venafi secret with live tokens. Treat snapshots as secret material |

---

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `could not execute files outside of configured plugin directory` | `plugin_directory` is a symlink, or `-command` has a path | Real directory; `-command` is a file name |
| `checksums did not match` (some nodes / after failover) | Different binary on that node, or the **zip** hash registered | Ansible verify play; register the **binary** hash |
| `fork/exec … permission denied` | `noexec` mount, wrong owner/mode | Move `plugin_directory`; `root:vault` `0750` |
| Mount: `unknown plugin` / `plugin not found in the catalog` | Application pipeline ran before the root pipeline, or version mismatch | Register first; `plugin_version` must match the catalog exactly |
| Secret write fails `x509: certificate signed by unknown authority` | `trust_bundle_file` missing/wrong on the **active** node | Same PEM, same path, every node (Ansible `--tags trust_bundle`) |
| Secret write fails `invalid_grant` / `401` | Tokens already used, or wrong `client_id` (vcert default `vcert-cli`) | New `getcred` ×2 with `--client-id hashicorp-vault-by-venafi` |
| Works for weeks, then every issue fails with 401 | Grant passed `refresh_until`, or a second copy of the secret spent the tokens | Re-bootstrap; find any duplicate secret/mount/cluster |
| `403 Insufficient scope` on revoke | Integration lacks `revoke` | Add scope on T1, re-bootstrap |
| `PolicyLocked` / `… does not match policy` | Key type/size or DN conflicts with the folder | Align role or CSR with T4 |
| Issued cert has no SANs | Caller sent no `alt_names` (plugin does not copy CN) | Send the CN in `alt_names` |
| `ttl` ignored | Fixed-validity CA template, or no `issuer_hint` | Set `issuer_hint`; flexible template |
| cert-manager: `role key type "any" not allowed` | ClusterIssuer path is `issue/…` | Use `venafi-pki/sign/<role>` |
| cert-manager: `permission denied` on `sign/` | Policy has `allowed_parameters` without cert-manager's full set | Use the cert-manager variant (§9) |
| cert-manager: Kubernetes login `permission denied` / `invalid audience` | Vault role `audience` ≠ `vault://<ClusterIssuer name>` | Match the name exactly |
| cert-manager: `TokenReview` 401 / `service account lookup failed` | SA lacks `system:auth-delegator`, or token lacks the API audience, or flow #12 closed | `00-*.yaml`; `serviceAccountRef.audiences`; open #12 |
| cert-manager: secret's issuer is the **root** | Role has `chain_option=first` | `chain_option=last` |
| Times out at ~180 s | CA slower than `server_timeout` | Raise `server_timeout`; check CA queue in TPP |

---

## 14. Verification

Use the evidence pack in [runbook 09 §5](09-venafi-pki-team-runbook.md#5-proof-of-integration--the-evidence-pack).
In short: `tools/venafi_pki_proof.py` (issue mode from a consumer token, and `--cert-file` mode on a
cert-manager secret) plus the failover, renewal, revoke and grant-refresh checks listed there.

---

## 15. What was tested, and what was not

Tested in a disposable lab (Vault **Community 1.20.4** dev server — Vault Enterprise needs a licence;
Terraform 1.9.8; provider 3.23.0):

- `vault-enterprise-config`: `terraform validate` on both roots; apply of the catalog, Venafi-PKI and
  Kubernetes-auth modules; a second plan shows **no changes**. Mount pinned via `plugin_version`.
  The module was driven against Vault's built-in `pki` plugin, pinned by its builtin version, because…
- …**the `venafi-pki-backend` binary itself was not run**: executing a third-party plugin was not
  permitted in the test environment. Plugin behaviour above comes from reading its v0.16.0 source.
- Policies: 12 allow/deny cases with real tokens, including cert-manager's exact `sign/` payload.
- `venafi_pki_proof.py` against that Vault and a mock TPP (found, not found, 401, no Origin field,
  wrong folder, wrong trust root, cert-file mode on a cert-manager-shaped secret).
- `venafi-pki-verify-node.sh` (wrong hash, symlink, wrong group, TLS with right/wrong bundle),
  `venafi-pki-bootstrap-secret.sh` (wrap → unwrap → write → self-revoke → reuse refused) with a stub vcert,
  `venafi-pki-configure.sh` (tune branch, roles, all three policies).
- **Not tested:** namespaces (Enterprise-only), TPP, the Ansible playbook (no Ansible in the lab; parsed
  only), the Kubernetes manifests (parsed only), the Sentinel snippet.

---

## 16. Sources

- Plugin v0.16.0 source: `plugin/pki/path_venafi_cert_enroll.go`, `path_roles.go`,
  `path_venafi_secrets.go`, `util.go`, `backend.go` — <https://github.com/Venafi/vault-pki-backend-venafi/tree/v0.16.0>
- Releases v0.16.0 / v0.17.0 — <https://github.com/Venafi/vault-pki-backend-venafi/releases>
- vcert v5.13.7 CLI (`cmd/vcert/flags.go`, `passwords.go`) and TPP connector (`Origin` attribute) — <https://github.com/Venafi/vcert/tree/v5.13.7>
- cert-manager v1.21.3: `internal/vault/vault.go` (sign parameters, token audiences),
  `pkg/apis/certmanager/v1/types_issuer.go`, Helm `disableAutoApproval` — <https://github.com/cert-manager/cert-manager/tree/v1.21.3>
- approver-policy v0.29.0 CRD types — <https://github.com/cert-manager/approver-policy>
- Vault plugin management and upgrades — <https://developer.hashicorp.com/vault/docs/plugins/plugin-management>,
  <https://developer.hashicorp.com/vault/docs/upgrading/plugins>
- Terraform provider: `vault_plugin` and mount `plugin_version` first appear in 4.4.0 (3.23.0 lacks both)
