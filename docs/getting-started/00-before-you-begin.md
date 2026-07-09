# 00 — Before You Begin

Spend 10 minutes here. It saves hours later. By the end you'll know the handful
of concepts involved, what access you need, which network paths to request, and
who is responsible for what.

---

## 1. The concepts you actually need

Just five ideas. Everything in these guides is one of these.

| Idea | Plain-language meaning | Why we use it |
|---|---|---|
| **Workload identity** | A machine proves *who it is* instead of typing a password. CI uses a per-build signed token; AAP uses an AppRole. | You can't steal a password that doesn't exist. |
| **Short-lived token** | The Vault token a platform gets back expires in **15–30 minutes**. | A leaked token is useless minutes later. |
| **Least privilege** | Each platform's Vault "policy" allows reading **only its own** secrets, nothing else. | Blast radius stays tiny if anything goes wrong. |
| **No static secrets** | Nothing permanent is stored in the platform. Even AAP's one bootstrap value (its AppRole `secret_id`) is short-lived, single-use, and IP-locked. | Removes the thing attackers hunt for. |
| **Signed SSH certificates** | To log into a server, Vault signs a **short-lived SSH certificate** instead of using a static key. | No static SSH keys sitting on servers. |

**One namespace for everything:** all three platforms use a single Vault
Enterprise namespace called **`AUT`** (owned by the Automation team). Inside it,
each platform is separated by its own auth method, role, policy, and secret path —
not by extra namespaces.

```
AUT/                         # the one namespace you work in
├── auth/
│   ├── jwt-ci/              # CloudBees CI logs in here (per-build JWT)
│   ├── jwt-cdro/            # CloudBees CD/RO logs in here (ZeroTrust plugin JWT)
│   └── approle/             # AAP logs in here (hardened AppRole)
├── secret/                  # your secrets (KV v2)
│   ├── ci/<app>/…
│   ├── cdr/<release>/…      # CD/RO reads its own release path (ZeroTrust plugin)
│   └── aap/<app>/…
└── ssh/                     # signs short-lived SSH certificates
    ├── roles/svc-ci
    └── roles/svc-aap
```

> Every Vault command in these guides runs **inside `AUT`**. You set that once
> per shell with `export VAULT_NAMESPACE=AUT` (or add `-namespace=AUT` to each
> command). If you ever see `namespace not found`, this is why.

---

## 2. Prerequisites checklist

Before starting guide 01, confirm you have:

**Access & accounts**
- [ ] A Vault token (or login) with rights to configure the `AUT` namespace — or a
      teammate on the **Vault team** who applies your changes (see §4).
- [ ] Admin access to each **CloudBees CI controller** (Manage Jenkins).
- [ ] Admin access to **CloudBees CD/RO** (to create procedures/credentials).
- [ ] Admin access to the **AAP** automation controller (to create credentials +
      job templates).

**Information to have written down**
- [ ] Vault API address, e.g. `https://<vault-vip>:8200`.
- [ ] Each CI controller's real external URL, e.g. `https://ctrlA.ci.corp.example.com`.
- [ ] The IP address/range of your **AAP hosts** (for locking the AppRole to them).
- [ ] Your app/secret naming, e.g. `payments`, `db`.
- [ ] Your internal **CA certificate bundle** file path (for Vault's TLS), e.g.
      `/etc/pki/vault/ca.crt`.

---

## 2.1 Software requirements & compatibility (CI agents + controllers)

Exactly what must be present to run the Jenkinsfiles and the Python helper scripts,
and how it maps to a typical airgapped baseline.

### Your baseline vs. what's required

The reference baseline below is a common airgapped RHEL agent. Confirm yours matches:

| On the agent | Baseline | Needed? | Verdict |
|---|---|---|---|
| `python3` | **3.6.8** (`/usr/bin/python3`) | Only to run the `tools/*.py` helpers | ✅ The helpers are written for **Python 3.6+**, standard library only |
| `pip3` | present (`/usr/bin/pip3`) | **Not needed** — helpers use zero third-party packages | ✅ No `pip install`, no internet |
| `vault` CLI | **1.15.1** | Only for the vault-CLI pipeline variant (C) | ✅ Older CLI → newer server (1.20.8+ent) is fine for the commands used (see note) |
| `curl` | present | For the curl pipeline variant (A) + CD/RO broker | ✅ |
| `jq` | present | Required by variant C; optional in variant A | ✅ |
| `openssh-clients` (`ssh`,`ssh-keygen`) | present | Only for the SSH deploy stage | ✅ |
| `bash` | `/bin/bash` (and `/bin/sh`→bash) | Pipelines use heredocs + `set -o pipefail` | ✅ Ensure the `sh` step resolves to bash, not dash |

> **vault CLI version skew:** CLI **1.15.1** talking to server **1.20.8+ent** is supported
> for every command these guides use (`auth/<mount>/login`, `kv get`, `token lookup`,
> `token revoke -self`, `ssh/sign`, `write -wrap-ttl`, `unwrap`) — all stable and
> namespace-aware since ≤1.10. Aligning the CLI closer to the server is good hygiene but
> not required here.

### CI controllers (all pipeline variants)

- **OpenID Connect Provider plugin** `oidc-provider` **`111.v29fd614b_3617`** (already the
  SECURITY-3574 fix — see [02](02-cloudbees-ci.md)).
- Correct **Jenkins URL** per controller (becomes the JWT `iss`).
- **Configuration as Code (JCasC)** for the `idToken` credential + (optional) global claim
  templates.
- **HTTP Request plugin** — **only** for pipeline variant B (`Jenkinsfile.vault-oidc-nocli`).
  That variant also needs a one-time **In-process Script Approval** for `JsonSlurperClassic`
  (or run it from a *trusted* shared library). Pipeline Utility Steps is **not** needed.
- **No other plugins required.** The examples were made plugin-free: workspace cleanup uses the
  **core** `deleteDir()` step (not `cleanWs()`), and `timestamps()` was removed. Optional niceties
  if you have them installed: **Timestamper** (re-enable `options { timestamps() }` for per-line
  log timestamps) and **Workspace Cleanup** / `ws-cleanup` (swap `deleteDir()` back to `cleanWs()`
  for pattern-based cleanup). Neither is needed for the pipelines to run.

### CI agents — by pipeline variant (pick one)

| Variant (file) | Needs on the agent | Controller plugin |
|---|---|---|
| **A. curl** ([`Jenkinsfile.vault-oidc-curl`](../vault-integrations/examples/Jenkinsfile.vault-oidc-curl)) *(recommended default)* | `curl`, `bash`; `jq` optional | OIDC Provider only |
| **B. HTTP Request** ([`Jenkinsfile.vault-oidc-nocli`](../vault-integrations/examples/Jenkinsfile.vault-oidc-nocli)) | *nothing* (calls run via the plugin) | OIDC Provider **+ HTTP Request** |
| **C. vault CLI** ([`Jenkinsfile.vault-oidc`](../vault-integrations/examples/Jenkinsfile.vault-oidc)) | `vault` (1.15.1 ✅), `jq` (**required**), `bash` | OIDC Provider only |
| SSH deploy stage (any variant) | `ssh`, `ssh-keygen` | — |
| CD/RO broker job — **fallback only** (runs as a CI job) | `curl` **or** `vault`+`jq` | OIDC Provider only |
| `tools/inspect_jwt_claims.py`, `tools/check_oidc_discovery.py` | `python3` **3.6+** (stdlib only) | — |

**CD/RO agents — ZeroTrust plugin (guide [03](03-cloudbees-cdro.md), pick one tier):**

| Tier (template) | Needs on the CD/RO agent | CD/RO plugin |
|---|---|---|
| **1. curl** ([`cdro-zerotrust-curl.sh`](../vault-integrations/examples/cdro-zerotrust-curl.sh)) *(recommended default)* | `curl` (`jq` optional) | ZeroTrust |
| **2. native plugin** ([`cdro-zerotrust-native.dsl`](../vault-integrations/examples/cdro-zerotrust-native.dsl)) | *nothing* (the plugin does the HTTP) | ZeroTrust |
| **3. vault CLI** ([`cdro-zerotrust-cli.sh`](../vault-integrations/examples/cdro-zerotrust-cli.sh)) | `vault` + `jq` | ZeroTrust |

> The ZeroTrust plugin has **no** OIDC discovery endpoint, so `check_oidc_discovery.py` is **not** used
> for CD/RO — only `inspect_jwt_claims.py` (to decode a captured token). Same `--cacert` TLS rule applies.
>
> **One-time key generation:** the plugin's signing key pair is made with **`openssl`** (ships on RHEL
> 8.10 — `openssl version` to confirm), per [03a — Generate the signing key pair](03a-zerotrust-key-generation.md).
> No `pip`/downloads; Python stdlib can't generate asymmetric keys, so `openssl` is the airgap-native tool.

**Recommended default:** **variant A (curl)** — it needs only `curl` + the OIDC Provider
plugin (no extra controller plugin), and the JWT is sent via stdin so it never lands in a
process list. With `jq` and `vault` also on your agents, **variant C works too**; choose B
only if you prefer to avoid shell binaries entirely and can add the HTTP Request plugin.

**TLS (all variants):** the Vault endpoint's private-CA bundle must be trusted — pass
`--cacert /etc/pki/vault/ca.crt` (curl/vault) or import the CA into the Jenkins truststore
(HTTP Request variant).

### Not CI (for completeness)

CD/RO and AAP **hosts** (separate from CI) also need `vault` or `curl` to log in / unwrap —
covered in [03](03-cloudbees-cdro.md) and [04](04-aap-approle-ssh.md). The CD/RO ZeroTrust tiers are
listed above; those hosts are otherwise out of scope for this CI-agent/controller requirements list.

### Confirm it on the agent image

```bash
python3 --version     # -> 3.6.x or newer
which bash            # -> /bin/bash  (sh step must resolve to bash for `set -o pipefail`)
curl --version        # any recent build (supports --data @- and --cacert)
jq --version          # needed for variant C; optional for A
vault version         # 1.15.1 is fine against a 1.20.8+ent server
ssh -V                # openssh-clients (only for the SSH deploy stage)
# The Python helpers need NO pip packages — this must succeed with no network:
python3 tools/inspect_jwt_claims.py --help
```

---

## 3. Network flows to request (airgapped = nothing is open by default)

Your systems sit in separate firewall zones. **Every** path below must be
explicitly opened by your network team, or logins fail — often *silently*. Give
this table to whoever manages firewalls.

| # | From | To | Port | What it's for |
|---|---|---|---|---|
| 1 | **Vault nodes** | each **CI controller** `/oidc/**` | 443 | Vault fetches CI's signing keys to validate JWTs. **Most commonly forgotten.** |
| 2 | CI controllers/agents | Vault `<vault-vip>` | 8200 | CI logs in, reads secrets, signs SSH |
| 3 | **CD/RO servers/agents** | Vault `<vault-vip>` | 8200 | **CD/RO logs in (ZeroTrust JWT) + reads secrets** (primary) |
| 3b | CI broker build *(fallback)* | Vault `<vault-vip>` | 8200 | Broker reads + wraps secrets for CD/RO |
| 4 | CD/RO servers/agents *(fallback)* | a CI controller | 443 | CD/RO triggers the broker job |
| 5 | CI (job result) *(fallback)* | CD/RO | 443/8443 | Return the wrapped secret |
| 6 | CD/RO servers/agents *(fallback)* | Vault `<vault-vip>` | 8200 | Unwrap the wrapped secret only |
| 7 | AAP controllers/EEs | Vault `<vault-vip>` | 8200 | AppRole login + read + SSH sign |
| 8 | AAP / CI agents | managed nodes | 22 | SSH using signed certs |
| 9 | Vault nodes | SIEM/syslog | 514/6514 | Audit log stream |
| 10 | AAP node-trust playbook | Vault `/v1/AUT/ssh/public_key` | 8200 | Fetch the SSH CA public key for nodes |

> **Flow #1 is the classic trap.** If Vault can't reach a controller's
> `/oidc/.well-known/openid-configuration`, JWT logins fail with confusing
> "signature/validation" errors no matter how correct your role config is.
> Guide [02](02-cloudbees-ci.md) validates it first, and
> [`tools/check_oidc_discovery.py`](../../tools/check_oidc_discovery.py) checks it
> for you.

> **CD/RO is different — no Vault→CD/RO flow.** The ZeroTrust plugin signs its JWT locally and Vault
> validates it against a **static public key**, so there is **no** discovery/JWKS call back to CD/RO
> (nothing like flow #1 for CD/RO). Flow #3 (CD/RO → Vault login) is all you open for the primary path;
> flows #3b–#6 apply only if you use the CI-broker fallback.

---

## 4. Who does what

You (the **Automation team**) author the configuration; the **Vault team** may be
the ones who actually apply it to the `AUT` namespace. Know your split before you
start.

| Task | Usually owned by |
|---|---|
| Create the `AUT` namespace | Vault team |
| Apply auth methods / secret engines / policies in `AUT` | Vault team (from your change request / YAML) |
| Author the requested Vault config | **You** (Automation team) |
| Configure CloudBees CI (plugin, credential, pipelines) | **You** |
| Configure CD/RO (ZeroTrust plugin config + procedures; broker only as fallback) | **You** |
| Install/manage the CD/RO **ZeroTrust** plugin + its signing key | CD/RO admins |
| Configure AAP (credentials, playbooks, job templates) | **You** |

> If the Vault team applies changes via a self-service pull request, guide 01 also
> shows the equivalent **YAML** you submit, not just the raw commands.

---

## 5. Mini-glossary

- **JWT / OIDC ID token** — a short-lived, signed token a CI build creates to prove
  its identity. "Claims" inside it (like `iss`, `aud`, `sub`, `job`) say who issued
  it and which build it is.
- **AppRole** — a Vault login method using a `role_id` (public) + `secret_id`
  (secret). We harden it so the `secret_id` is single-use, short-lived, and locked
  to AAP's IPs.
- **KV v2** — Vault's versioned key/value secret store. Your static secrets live at
  `secret/data/<platform>/<app>/<name>`.
- **Policy** — Vault's permission rule. Ours grant read on *only* the relevant path.
- **Response wrapping** — Vault hides a secret inside a **single-use** token; the
  receiver "unwraps" it once. If someone unwrapped it first, your unwrap fails —
  which is your tamper alarm.
- **Signed SSH certificate** — Vault signs a public key so you can SSH into a node
  for a short time, without a static private key on that node.
- **Namespace (`AUT`)** — the isolated slice of Vault Enterprise you operate in.

You're ready. Continue to **[01 — Set up Vault](01-vault-setup.md)**.
