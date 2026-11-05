# 09 — Venafi ⇄ Vault PKI: team-by-team runbook

> **What this is:** the exact steps, in order, for the **Venafi (PKI) team**, the **Vault team** and
> the **Kubernetes platform team** to switch on Vault Enterprise **1.20.8+ent**'s Venafi PKI secrets
> engine (`venafi-pki-backend` **v0.16.0**, already placed on the Vault VMs by Ansible), connect
> Kubernetes through **cert-manager**, and **prove** that Venafi really governs the certificates.
>
> **Why it works the way it does:** [`08-venafi-pki-secrets-engine.md`](08-venafi-pki-secrets-engine.md).
> **Config as code:** `vault-enterprise-config` (`docs/VENAFI_PKI.md`).
>
> Step IDs: **P** = Venafi/PKI team, **V** = Vault team, **K** = Kubernetes team, **E** = evidence.
> Every step lists *Do*, *Expect*, and *Hand-off/Evidence*. Do not skip an *Expect* — each one guards a
> failure that otherwise shows up weeks later.

---

## 0. Before anyone starts

### 0.1 Who does what

| Area | Venafi team | Vault team | Kubernetes team |
|---|---|---|---|
| TPP API integration, service account, folders, folder policy, CA template | **R/A** | C | — |
| TPP web chain + enterprise root CA files | **R** | consumes | consumes |
| Plugin binary on nodes (Ansible), node verification | — | **R/A** | — |
| Firewall flows #11–#14 | C | **R** (raise) | C (#13) |
| Catalog, mount, roles, policies (Terraform / CLI) | C | **R/A** | — |
| Writing the Venafi secret (TPP tokens) | **R** (holds the password) | **A** (issues the bootstrap token) | — |
| Kubernetes auth mount + cert-manager role in Vault | — | **R/A** | C |
| cert-manager RBAC, ClusterIssuer, approver-policy | — | C | **R/A** |
| Proof / sign-off | **R** (TPP side) | **R** (Vault side) | **R** (K8s side) |
| Grant-expiry re-bootstrap (day 2) | **R** | **A** | — |

R = does it, A = accountable, C = consulted.

### 0.2 Agreement sheet — fill this in together first

| # | Item | Example used in this runbook | Owner | Agreed value |
|---|---|---|---|---|
| A1 | TPP base URL | `https://tpp.corp.example.com` | Venafi | |
| A2 | TPP version / build | 24.x | Venafi | |
| A3 | Service account | `svc-vault-pki` | Venafi | |
| A4 | API integration Application ID | `hashicorp-vault-by-venafi` (do not change) | Venafi | |
| A5 | Scope | `certificate:manage,revoke` | Venafi + Security | |
| A6 | Access-token validity / grant validity | 1 day / 365 days | Venafi | |
| A7 | Parent folder | `\VED\Policy\Certificates\Vault\AUT` | Venafi | |
| A8 | Leaf folders → Vault roles | `Web`→`web-aut`, `Hosts`→`host-csr-aut`, `K8s`→`k8s-cert-manager` | Venafi + Vault | |
| A9 | Domains per folder | `*.aut.corp.example.com`, `*.k8s.aut.corp.example.com` | Venafi + app owners | |
| A10 | CA template + issuer type (for `issuer_hint`) | Microsoft CA → `m` | Venafi | |
| A11 | Vault VIP, namespace | `https://vault-vip.corp.example.com:8200`, `AUT` | Vault | |
| A12 | Vault nodes | `vault-01/02/03.corp.example.com` | Vault | |
| A13 | Mount path | `venafi-pki` | Vault | |
| A14 | Kubernetes cluster(s), API URL, Vault auth path | `automation-k8s`, `https://automation.corp.example.com:6443`, `auth/kubernetes/automation-k8s` | K8s + Vault | |
| A15 | cert-manager version / namespace | ≥ 1.15, `cert-manager` | K8s | |
| A16 | ClusterIssuer name (becomes the audience) | `vault-venafi` → `vault://vault-venafi` | K8s + Vault | |
| A17 | Secure channel for the one-time bootstrap token | your PAM / sealed ticket | Security | |
| A18 | Change ticket(s) | CHG… | All | |

### 0.3 Order of work

```
P1 ─ P2 ─ P3 ─ P4 ─ P5 ─ P6 ─ P7 ─ P8 ──────────────┐ (TPP ready, files handed over)
V1 ─ V2 ─ V3 ─ V4 ─ V5 ─────── V6 ─ V7 ─ V8 ───────►│ P9 (Venafi team writes the secret) ─► V9 ─ V10
                                                    │
K1 ─ K2 ─ K3 ─ K4 ─────────────────────────────── V11 ─ K5 ─ K6 ─ K7 ─ K8
                                                    │
                           §5 proof (E1–E14), sign-off ─► V12 failover ─► V13 monitoring ─► day 2
```

The Venafi and Vault tracks run in parallel until **P9**, which needs both.

---

## 1. Venafi (PKI) team

### P1 — Confirm the platform

**Do**
1. Record the TPP version (Help ► About). API integrations need 20.1 or later.
2. From your admin host: `curl -sS -o /dev/null -w '%{http_code}\n' https://tpp.corp.example.com/vedsdk/` — any
   `200/401` proves WebSDK is up.
3. Confirm the WebSDK/Authorize endpoints are served by the same certificate chain on every TPP node
   behind the load balancer.

**Expect** WebSDK reachable; one consistent server certificate chain.

**Hand-off** A1, A2 on the agreement sheet.

### P2 — Create the service identity

**Do**
1. Create `svc-vault-pki` (local identity, or AD account if policy requires it).
2. Set *interactive login* off where your directory supports it; store the password in your PAM vault.
3. Do **not** add it to any group that grants rights above the Vault folder.

**Expect** The account can authenticate to TPP and holds no other rights.

**Hand-off** A3. The password never leaves the Venafi team.

### P3 — Create the API integration

**Do** (Aperture: *Platform ► API ► Integrations ► Add* — labels vary slightly by version)
1. **Application ID: `hashicorp-vault-by-venafi`** — exactly this. It is the plugin's `client_id`, and
   the token refresh is bound to it.
2. Name: "Venafi Secrets Engine for HashiCorp Vault — AUT".
3. **Scope:** Certificate → `manage` **and** `revoke` (`certificate:manage,revoke`). Leave out `revoke`
   only if Vault must never revoke.
4. **Allow token refresh: on.** Token validity: **1 day**. Grant validity: **365 days** (A6).
5. Allowed identities: **`svc-vault-pki` only**.
6. Repeat for a **read-only proof integration**, Application ID `venafi-pki-proof`, scope
   `certificate` (no manage), validity 1 day, no refresh, allowed identity: the PKI analyst who will
   co-run the proof (T8). It is used only for E7/E8.

**Expect** Both integrations listed and enabled.

**Hand-off** A4–A6 to the Vault team (they set `refresh_interval` ≤ ½ token validity → `12h`).

### P4 — Create the policy folders

**Do**
1. Create `\VED\Policy\Certificates\Vault\AUT`.
2. Under it: `Web`, `Hosts`, `K8s` (A8). One folder per Vault role keeps inventory and ownership clean.

**Expect** Folders visible in Policy Tree.

### P5 — Folder permissions

**Do** On `\VED\Policy\Certificates\Vault\AUT` (inherited by the three leaves), give `svc-vault-pki`:

| Permission | Why |
|---|---|
| View, Read | find the folder and its policy |
| Write, Create | create certificate objects, submit CSRs |
| Revoke | only if A5 includes `revoke` |
| **Not** Delete, Admin, *Private Key Read/Write* | Vault never needs TPP to hold or return keys |

Give it **nothing** above `\AUT`.

**Expect** *Effective permissions* for `svc-vault-pki` on `\VED\Policy\Certificates\Vault` shows nothing.

### P6 — Folder policy (each leaf)

**Do** Set and **lock**:

| Setting | `Web` | `Hosts` | `K8s` |
|---|---|---|---|
| CA template | A10 | A10 | A10 |
| Management type | Enrollment | Enrollment | Enrollment |
| CSR generation | *User provided / Generated on application* allowed — **not locked to Service Generated** | same | same |
| Key | RSA ≥ 2048 (lock) | RSA ≥ 2048 or EC P-256 | RSA ≥ 2048 (cert-manager demo uses RSA 2048) |
| Subject O / OU / L / ST / C | locked values | locked | locked |
| **Domain whitelist** | `aut.corp.example.com` (subdomains) | host domain | `k8s.aut.corp.example.com` |
| Whitelist applies to SANs | yes | yes | yes |
| Wildcards | off | off | off |
| Disable Automatic Renewal | **Yes** (consumers renew) | Yes | Yes (cert-manager renews) |
| Validity | flexible if consumers choose `ttl` (T6), else fixed | | |

**Expect** A test CSR for `evil.example.com` submitted by an admin into `Web` is **rejected** by policy.
This whitelist is the control that the Vault ACL cannot be (guide 08 §9).

### P7 — CA turnaround and revocation data

**Do**
1. Enroll one test certificate into `Web` from the TPP UI; time it. Target < 60 s (plugin waits 180 s).
2. Note the CRL distribution point / OCSP URL on that certificate.

**Expect** Issued in < 60 s; CRL/OCSP URLs present.

**Hand-off** Turnaround time (Vault team sets `server_timeout` if > 120 s).

### P8 — Export trust material

**Do**
1. **TPP web chain** (root + intermediates of the certificate on `tpp.corp.example.com:443`) as PEM →
   `tpp-chain.pem`. Verify: `openssl s_client -connect tpp.corp.example.com:443 -CAfile tpp-chain.pem </dev/null | grep 'Verify return code: 0'`.
2. **Enterprise root** (and issuing CA) of the CA template → `enterprise-root.pem`, `enterprise-issuing.pem`.

**Hand-off** Both files to the Vault team and the Kubernetes team through your normal artifact process
(they are public certificates, but integrity matters: send their SHA-256 separately).

### P9 — Write the Venafi secret (with the Vault team's bootstrap token)

Needs: V8's wrapping token; your admin host with `vcert` (v5), `vault`, `jq`, network to Vault 8200
(flow #14) and to TPP 443; `tpp-chain.pem`.

**Do**
```bash
export VAULT_ADDR=https://vault-vip.corp.example.com:8200 VAULT_CACERT=/path/vault-listener-ca.pem
export NS=AUT MOUNT=venafi-pki SECRET=tpp
export VAULT_WRAPPED_TOKEN='<wrapping token from V8>'
export TPP_URL=https://tpp.corp.example.com TPP_USER=svc-vault-pki TPP_CHAIN=./tpp-chain.pem
export ZONE='Certificates\Vault\AUT' REFRESH_INTERVAL=12h TRUST_BUNDLE=/etc/vault/tls/tpp-chain.pem
./docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh write-secret
```
You will be prompted **twice** for the `svc-vault-pki` password (two `vcert getcred` runs → two
independent refresh tokens).

**Expect**
- `Success! Data written to: venafi-pki/venafi/tpp`. This write makes the Vault active node call TPP
  and refresh the tokens, so success already proves flow #11, the trust bundle, `client_id` and scope.
- `== bootstrap token revoked`.
- `GRANT EXPIRES (refresh_until): <date>`.

**If** `unwrap failed`: the token expired (30 min) or **someone else used it** — stop and raise it.
**If** `invalid_grant`/401: wrong client id or scope — re-check P3, ask V8 for a new token.

**Hand-off** "Secret written" + the **`refresh_until` date** to the Vault team (V9) and into your
calendar (P11). Do not send the tokens anywhere; the script shreds them.

### P10 — Proof, TPP side (with the Vault team, §5)

**Do**
1. Give the proof runner a token from the **read-only** integration:
   `vcert getcred -u https://tpp.corp.example.com --username <analyst> --client-id venafi-pki-proof --scope certificate --trust-bundle tpp-chain.pem --format json | jq -r .access_token`
   → exported as `TPP_TOKEN` in the proof shell only.
2. In the TPP UI, open each proof certificate and screenshot: folder path, **Origin = HashiCorp Vault**,
   issuer, validity, and (after E12) revocation status.

**Evidence** E7, E8, E12 (TPP side).

### P11 — Day 2 (owned by the Venafi team)

| When | What |
|---|---|
| ≥ 30 days before `refresh_until` | Re-run P9 with a fresh V8 token. Nothing else warns you; after that date all issuance stops |
| TPP web certificate renewed with a new chain | Send the new `tpp-chain.pem` (V4) **before** the switch |
| `svc-vault-pki` password rotation | No effect on live tokens; record it |
| Folder policy changes | Tell the Vault team; roles may need the same key size/curve |

---

## 2. Vault team

All commands assume `export VAULT_ADDR=https://vault-vip.corp.example.com:8200 VAULT_CACERT=…` and an
admin token. Prefer the Terraform path (`vault-enterprise-config`); the CLI path is given as the fallback.

### V1 — Cluster health

**Do**
```bash
vault status                       # Version 1.20.8+ent, Sealed false, HA Enabled true
vault operator raft list-peers     # all voters present
vault read sys/license/status      # licence valid
```
**Expect** Healthy, licensed, all peers.

### V2 — Prove the Ansible-placed binary on every node

**Do**
```bash
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml
# no Ansible on the box? on each node:  sudo docs/vault-integrations/examples/venafi-pki-verify-node.sh
```
**Expect** Every node passes: `plugin_directory` set in the server config, real directory, not `noexec`,
binary SHA-256 **`48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec`**, group `vault`,
not group/other writable.

**Evidence** E1 — the `EVIDENCE host=…` / `SUMMARY host=…` line per node.

### V3 — `plugin_directory` live on every node

**Do** If V2 shows `plugin_directory` was *added* by Ansible and the nodes have not restarted since:
restart one node at a time — standbys first, `vault operator step-down` on the leader, restart it last —
with `vault operator raft list-peers` between each.

**Expect** All nodes back as voters; leader elected.

### V4 — TPP trust bundle on every node

**Do**
```bash
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml \
  --tags trust_bundle -e trust_bundle_src=./tpp-chain.pem
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml \
  -e tpp_host=tpp.corp.example.com
```
**Expect** `/etc/vault/tls/tpp-chain.pem` on every node, and `Verify return code: 0 (ok)` to TPP from
every node.

**Evidence** E2.

### V5 — Firewall flows

**Do** Raise and then prove:

| # | From | To | Port | Prove with |
|---|---|---|---|---|
| 11 | each Vault node | TPP `/vedsdk/*`, `/vedauth/*` | 443 | `docs/shared/conn_check.sh --hop flow11-vault-0N-to-tpp` (N = 1..3) |
| 12 | each Vault node | each K8s API server | 6443 | `--hop flow12-vault-0N-to-k8s` |
| 13 | K8s nodes | Vault VIP | 8200 | `--app vault-from-k8s` from a K8s node / debug pod |
| 14 | Venafi admin host | Vault VIP | 8200 | `--app vault` from that host |

**Expect** All green. **#11 and #12 from every node**, not just the leader.

**Evidence** E3.

### V6 — Register the plugin (root catalog)

**Do (Terraform)** PR to `vault-enterprise-config` adding the `plugins:` entry to
`configs/root-namespace.yaml` (already in this change); run `jenkins/Jenkinsfile.root`.
**Do (CLI)** `SKIP_REGISTER=0 NS=AUT docs/vault-integrations/examples/venafi-pki-configure.sh` (it does V6+V7).

**Expect**
```bash
VAULT_NAMESPACE= vault plugin info -version=v0.16.0 secret venafi-pki-backend
# sha256  48eec755…c99ec   version v0.16.0   command venafi-pki-backend
```
**Evidence** E4.

### V7 — Mount, roles, policies in `AUT`

**Do (Terraform)** `configs/applications/automation.yaml` → `secret_engines.venafi_pki` (already in
this change; adjust zones and domains to A8/A9); run `jenkins/Jenkinsfile.namespace` with
`APPLICATION=automation`.

**Expect**
```bash
vault secrets list -namespace=AUT -detailed -format=json | jq '."venafi-pki/" | {type, plugin_version, running_plugin_version}'
# "venafi-pki-backend", "v0.16.0", "v0.16.0"
vault list -namespace=AUT venafi-pki/roles      # web-aut host-csr-aut k8s-cert-manager (or the YAML names)
vault policy list -namespace=AUT | grep venafi-pki-
```
Issuance does not work yet (no secret) — that is expected.

**Evidence** E5.

### V8 — Issue the one-time bootstrap token for the Venafi team

**Do**
```bash
NS=AUT MOUNT=venafi-pki SECRET=tpp docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh issue-token
```
**Expect** Policy `venafi-pki-bootstrap` (create/update on `venafi-pki/venafi/tpp` + revoke-self only),
and a **wrapping token** valid 30 minutes.

**Hand-off** The wrapping token to the Venafi engineer over the A17 channel — never chat or e-mail. Note
the wrapping accessor; if P9 does not happen in 30 minutes, it simply expires.

### V9 — Check the secret

**Do**
```bash
NS=AUT docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh status
```
**Expect** `url`, `zone`, `client_id=hashicorp-vault-by-venafi`, tokens shown **masked**, and the
**effective** `refresh_interval` (clamped to the token validity if you set it longer). Record
`refresh_until` from P9 in the runbook ticket and the team calendar.

### V10 — Attach consumer policies

**Do** In `vault-enterprise-config`, add `venafi-pki-<role>` to the `policies` of the auth roles that
should issue (CI JWT role, AAP AppRole, Kubernetes roles). CLI equivalent: add the policy to the role's
`token_policies`.

**Expect** A consumer token shows the policy: `vault token lookup` → `policies`.

### V11 — Kubernetes auth for cert-manager (with the K8s team)

**Do** In `configs/applications/automation.yaml` → `auth_methods.kubernetes.automation-k8s` (already in
this change): API URL and CA (A14), and the role

```yaml
- role_name: "cert-manager-venafi"
  bound_service_account_names: ["vault-venafi-issuer"]
  bound_service_account_namespaces: ["cert-manager"]
  audience: "vault://vault-venafi"            # = vault://<ClusterIssuer name>  (A16)
  policies: ["venafi-pki-k8s-cert-manager"]
  ttl: 600
```
Run the application pipeline.

**Expect** `vault read -namespace=AUT auth/kubernetes/automation-k8s/role/cert-manager-venafi` shows the
audience and policy. Vault stores **no** reviewer token (`token_reviewer_jwt` unset).

### V12 — Failover proof

**Do** After §5 passes: `vault operator step-down` on the leader, wait for the new leader, then run the
issue-mode proof again (E13).

**Expect** PASS on the new leader — proves binary, trust bundle and flow #11 on another node.

### V13 — Monitoring and alerts

**Do**
1. Log alert on the Vault server log (all nodes): `invalid_grant`, `error validating access token`,
   `401` together with `venafi`, `checksums did not match`, `could not execute files`.
2. Daily synthetic issue from CI: `tools/venafi_pki_proof.py` in issue mode with a dedicated low-TTL
   role or `--ttl 1h --revoke`; alert on exit code ≠ 0.
3. Calendar: `refresh_until − 30 days` → P11 + V8.

**Evidence** E14 (alert rule IDs, schedule).

### V14 — Day 2 (owned by the Vault team)

| Event | Do |
|---|---|
| Re-bootstrap (P11) | V8 again → P9 → V9. Never re-use old tokens |
| Upgrade to v0.17.0 | guide 08 §12 |
| New consumer namespace wants its own mount | its **own** TPP identity and token set — never copy `tpp` |
| Raft snapshot | handle as secret material (it holds live tokens) |

---

## 3. Kubernetes platform team (cert-manager path)

Files: [`examples/k8s/`](examples/k8s/).

### K1 — Prerequisites

**Do**
```bash
kubectl -n cert-manager get deploy cert-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
**Expect** cert-manager **≥ 1.15** (needed for `serviceAccountRef.audiences`). Note the controller's
ServiceAccount name (Helm default `cert-manager`).

### K2 — Identity and RBAC

**Do** `kubectl apply -f docs/vault-integrations/examples/k8s/00-vault-venafi-issuer-rbac.yaml`

**Expect**
```bash
kubectl auth can-i create serviceaccounts --subresource=token -n cert-manager \
  --as=system:serviceaccount:cert-manager:cert-manager      # yes (for vault-venafi-issuer only)
kubectl auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:cert-manager:vault-venafi-issuer   # yes (system:auth-delegator)
```

### K3 — API server audience and CA for Vault

**Do**
```bash
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer   # usually also the API audience
kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > k8s-api-ca.pem
```
**Hand-off** API URL + `k8s-api-ca.pem` to the Vault team for V11; the audience goes into K4.

### K4 — Vault listener CA

**Do** `base64 -w0 < vault-listener-ca.pem` (the CA of Vault's **TLS listener**, from the Vault team —
not the Venafi CA). Put it in `caBundle` of `01-clusterissuer-vault-venafi.yaml`, together with the
audience from K3, `namespace: AUT`, and `mountPath: /v1/auth/kubernetes/automation-k8s`.

### K5 — ClusterIssuer

**Do** `kubectl apply -f docs/vault-integrations/examples/k8s/01-clusterissuer-vault-venafi.yaml`

**Expect**
```bash
kubectl get clusterissuer vault-venafi
# READY True   (status message: "Vault verified")
```
**If not Ready:** `kubectl describe clusterissuer vault-venafi` — `invalid audience` → V11 audience must
be `vault://vault-venafi`; `TokenReview`/`service account lookup failed` → K2 auth-delegator, the audience in
K4, or flow #12; `x509` → wrong `caBundle`.

### K6 — Name control in the cluster (recommended)

**Do** Install approver-policy, set cert-manager `disableAutoApproval=true`, then
`kubectl apply -f docs/vault-integrations/examples/k8s/03-approver-policy.yaml` (domains from A9).

**Expect** A Certificate for `evil.example.com` against `vault-venafi` is **Denied** before it reaches
Vault (E10).

### K7 — Demo certificate

**Do** `kubectl apply -f docs/vault-integrations/examples/k8s/02-certificate-demo.yaml` (CN/SANs from A9)

**Expect**
```bash
kubectl -n venafi-demo get certificate demo-tls       # READY True
kubectl -n venafi-demo get certificaterequest -o wide # APPROVED True, READY True
```

### K8 — Prove it from the cluster

**Do**
```bash
TPP_URL=https://tpp.corp.example.com TPP_CA=./tpp-chain.pem TPP_TOKEN=<from P10> \
TRUST_ROOT=./enterprise-root.pem EXPECT_FOLDER='Certificates\Vault\AUT\K8s' RENEW=1 \
  docs/vault-integrations/examples/k8s/verify-cert-manager.sh
```
**Expect** PASS for the chain, the enterprise root, TPP inventory under `…\AUT\K8s`, Origin, and a new
serial after the forced renewal.

**Evidence** E9, E11.

### K-alt — Vault Agent Injector (mutating webhook) instead of cert-manager

Use only for workloads that cannot consume a Kubernetes Secret.
1. Install the injector only, pointed at the external Vault (command in `04-vault-agent-injector-demo.yaml`).
2. Vault team: Kubernetes role `web-agent` bound to `venafi-demo/web`, policy `venafi-pki-web-aut`;
   bind that ServiceAccount to `system:auth-delegator`.
3. Apply `04-vault-agent-injector-demo.yaml`; check `/vault/secrets/tls.pem` in the pod
   (`kubectl exec … -- openssl x509 -in /vault/secrets/tls.pem -noout -issuer`).
4. Copy the PEM out and run `tools/venafi_pki_proof.py --cert-file`.

Here Vault generates the key (`issue/`), so the ACL's CN/SAN globs do apply — with the comma caveat.

---

## 4. Consumers outside Kubernetes (quick reference)

```bash
# CI / AAP / any consumer token with policy venafi-pki-web-aut
vault write -namespace=AUT -format=json venafi-pki/issue/web-aut \
  common_name=app1.aut.corp.example.com alt_names=app1.aut.corp.example.com ttl=720h
```
Always include the CN in `alt_names` — the plugin does not copy it into the SANs.

---

## 5. Proof of integration — the evidence pack

The question to answer: **"Is Venafi really governing the certificates Vault hands out?"** Each line is
one artifact for the change ticket. `tools/venafi_pki_proof.py` produces most of them as a
Markdown + JSON report (no private key material in it).

**Issue-mode run** (Vault team + PKI analyst together):

```bash
export VAULT_TOKEN=<a consumer token holding only venafi-pki-web-aut>   # not an admin token
export TPP_TOKEN=<read-only token from P10>
CN="proof-$(date +%s).aut.corp.example.com"        # one value, used for CN and SAN
python3 tools/venafi_pki_proof.py --namespace AUT --mount venafi-pki --role web-aut \
  --common-name "$CN" --alt-names "$CN" --ttl 24h \
  --negative-cn evil.example.com \
  --trust-root ./enterprise-root.pem \
  --tpp-url https://tpp.corp.example.com --tpp-ca ./tpp-chain.pem \
  --expect-folder 'Certificates\Vault\AUT\Web' --revoke
# admin token only, adds the catalog check:  --expect-sha256 48eec755…c99ec
```

| # | Evidence | Proves | How | Owner |
|---|---|---|---|---|
| E1 | Per-node verify lines | Same, correct binary on **every** node | V2 | Vault |
| E2 | TLS to TPP from every node | Trust bundle + flow #11 per node | V4 | Vault |
| E3 | `conn_check.sh` output | Flows #11–#14 | V5 | Vault |
| E4 | `vault plugin info -version=v0.16.0 …` | Catalog pinned to the binary hash | V6 / proof P3 | Vault |
| E5 | Mount `plugin_version`/`running_plugin_version` | Mount runs v0.16.0 | V7 / proof P2 | Vault |
| E6 | Proof P4–P7 | A certificate came out of Vault, its key matches, and it **chains to the enterprise root you supplied out of band** — no Vault CA anywhere | proof tool | Vault |
| E7 | Proof P8 + TPP screenshot | TPP has that exact certificate (SHA-1 thumbprint) under `…\AUT\Web` | proof tool + P10 | Venafi |
| E8 | Proof P9 + TPP screenshot | TPP records **Origin = HashiCorp Vault** for it | proof tool + P10 | Venafi |
| E9 | `verify-cert-manager.sh` report | Same chain, TPP inventory and Origin for a certificate **issued to Kubernetes** | K8 | K8s |
| E10 | Denied requests | Policy works at every layer: proof P10 (Vault ACL 403 or TPP policy), K6 (approver-policy Denied), and P6's admin test (TPP whitelist) | proof tool, K6, P6 | All |
| E11 | Renewed serial | cert-manager renews through Vault/TPP; new cert also in TPP | K8 `RENEW=1` | K8s |
| E12 | Proof P11 + TPP screenshot + CRL | Revoke through Vault reaches TPP and the CA's CRL/OCSP (after the CA's publish interval) | proof tool + P10 | Venafi |
| E13 | Proof re-run after step-down | Works on another node | V12 | Vault |
| E14 | Second issue after `refresh_interval` without touching the secret | Token refresh works (no re-bootstrap needed) | re-run the proof > 12 h later | Vault |

**Sign-off** when E1–E14 are attached and PASS (E8 may be a TPP screenshot if your TPP version's API
does not return the Origin field — the tool marks that INFO, not FAIL).

---

## 6. Troubleshooting by team

| Seen by | Symptom | Most likely | Step to revisit |
|---|---|---|---|
| Vault | `checksums did not match` after failover | one node has a different binary | V2 |
| Vault | Mount fails `unknown plugin` | root pipeline not run, or version text differs | V6 |
| Venafi | `write-secret`: `unwrap failed` | expired or already used wrapping token | V8 (and report if "already used") |
| Venafi | `write-secret`: `x509: … unknown authority` | `trust_bundle_file` missing on the **active** node | V4 |
| Venafi | `write-secret`: `invalid_grant` | wrong client id / scope / refresh disabled | P3 |
| Vault | Issue `PolicyLocked` / `does not match policy` | role key or DN vs folder lock | P6 / guide 08 §8 |
| Vault | Issue works, cert has no SANs | `alt_names` not sent | §4 |
| Vault | Everything fails after months, 401 | grant expired (`refresh_until`) | P11 + V8 |
| K8s | ClusterIssuer `invalid audience` | Vault role audience ≠ `vault://<name>` | V11 / A16 |
| K8s | ClusterIssuer `TokenReview` 401 | missing auth-delegator, API audience, or flow #12 | K2 / K3 / V5 |
| K8s | CertificateRequest `permission denied` on sign | policy lacks cert-manager's parameters | V7 (cert-manager policy variant) |
| K8s | Secret's `ca.crt` is the wrong CA / chain odd | role `chain_option=first` | guide 08 §8 |
| K8s | Requests stay *Pending approval* | approver-policy installed, no matching policy or RBAC `use` | K6 |

---

## 7. Final checklist

- [ ] Agreement sheet complete and attached (A1–A18)
- [ ] P1–P8 done; P6 negative test rejected by TPP
- [ ] V1–V7 done; E1–E5 attached
- [ ] P9 done; bootstrap token revoked; `refresh_until` recorded and calendared
- [ ] V9–V11 done
- [ ] K1–K8 done (or K-alt)
- [ ] E6–E14 attached and PASS
- [ ] V13 alerts live; synthetic issue scheduled
- [ ] Demo resources removed (`kubectl delete ns venafi-demo`), proof certificates revoked
