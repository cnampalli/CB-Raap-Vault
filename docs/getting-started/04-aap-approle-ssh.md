# 04 — Ansible Automation Platform → Vault (hardened AppRole + signed SSH)

Here you'll connect **AAP 2.4** (automation controller `4.5.25`) to Vault so job
templates can read secrets and log into managed nodes with **short-lived signed SSH
certificates** — with no static credential sitting in AAP.

AAP 2.4 has no native OIDC login (that's a 2.7 Technology Preview), so it logs in
with a **hardened AppRole**. The one bootstrap value — the `secret_id` — is made
single-use, short-lived, and locked to AAP's IP range, then delivered **response-
wrapped** so it never appears in the clear.

Do guide [01](01-vault-setup.md) first — it created the `approle` method, the
`aap-automation` role, the `aap-kv-read`/`aap-ssh-sign` policies, and the
`ssh/roles/svc-aap` signer.

---

## Step 1 — Confirm the Vault side

```bash
export VAULT_NAMESPACE=AUT
vault read auth/approle/role/aap-automation   # -> shows the hardened settings from guide 01
vault read ssh/roles/svc-aap                  # -> the SSH signing role
vault kv put secret/aap/payments/db password="example-not-a-real-password"  # a test secret
```

You should see the hardening on `aap-automation`: `secret_id_num_uses 1`,
`secret_id_ttl 10m`, `token_ttl 20m`, `token_bound_cidrs` and
`secret_id_bound_cidrs` set to your AAP range, `token_policies [aap-kv-read
aap-ssh-sign]`.

---

## Step 2 — Get the RoleID (not secret)

The `role_id` identifies the role. It is **not** a secret — it's safe to store in
AAP's credential config.

```bash
vault read auth/approle/role/aap-automation/role-id
# Key        Value
# ---        -----
# role_id    d1f8...-....-....  (a stable UUID)
```

Copy the `role_id` value; you'll paste it into AAP in Step 4.

---

## Step 3 — Generate a response-wrapped SecretID and deliver it safely

The `secret_id` **is** secret. Never print it in the clear. Instead, generate it
**wrapped**: Vault returns a single-use wrapping token, and you unwrap it once on
the AAP host to reveal the real `secret_id`.

**On your Vault admin host — create the wrapped SecretID:**

```bash
export VAULT_NAMESPACE=AUT
vault write -wrap-ttl=120s -f auth/approle/role/aap-automation/secret-id
# Key                              Value
# ---                              -----
# wrapping_token                   hvs.CAES...        <- give THIS to the AAP host
# wrapping_token_ttl               2m
# wrapping_token_creation_path     auth/approle/role/aap-automation/secret-id
```

- `-f` (force) is needed because the endpoint takes no required fields.
- `-wrap-ttl=120s` gives the AAP admin 2 minutes to unwrap before it self-destructs.
- You get back a **wrapping token**, *not* the secret_id.

**On the AAP host — unwrap once to reveal the real SecretID:**

```bash
export VAULT_NAMESPACE=AUT
# (optional) pre-flight tamper check: confirms it hasn't been used and where it came from
vault write sys/wrapping/lookup token="<wrapping_token>"

# Unwrap — returns the real secret_id. Fails if anyone unwrapped it first (your alarm).
vault unwrap "<wrapping_token>"
# Key                   Value
# ---                   -----
# secret_id             a9c2...-....-....   <- paste THIS into AAP, then discard from screen
# secret_id_accessor    ...
```

> **Why this matters:** only a single-use *reference* travels between hosts, never
> the secret itself. If it's intercepted and unwrapped by an attacker, your unwrap
> **fails** — and that failure tells you the secret was exposed, so you rotate it.
> Because guide 01 set `secret_id_bound_cidrs` to AAP's IPs, a leaked secret_id is
> also useless from anywhere else.

---

## Step 4 — Create the AAP Vault credentials

In the AAP automation controller, create **two** credentials. Both authenticate to
Vault with the RoleID + SecretID (AppRole). The plugin selects AppRole automatically
**because you fill role_id + secret_id and leave Token empty.**

> **Field names below are exact** for the AAP 2.4 / controller 4.5.x HashiCorp Vault
> credential plugin. A few auth options (Username/Password, JWT, Workload Identity)
> only exist in newer controllers — if you don't see them on 2.4, that's expected.

### 4a. HashiCorp Vault Secret Lookup (read KV v2 secrets)

**Credentials → Add → Credential type: "HashiCorp Vault Secret Lookup".** Fill:

| Field (exact UI label) | Value |
|---|---|
| **Server URL** | `https://<vault-vip>:8200` |
| **Token** | *(leave empty — forces AppRole)* |
| **AppRole role_id** | the `role_id` from Step 2 |
| **AppRole secret_id** | the unwrapped `secret_id` from Step 3 |
| **Namespace name (Vault Enterprise only)** | `AUT` |
| **Path to Auth** | `approle` *(the AppRole mount; this is the default)* |
| **CA Certificate** | paste your Vault CA bundle (PEM) |
| **API Version** | `v2` *(KV v2)* |

### 4b. HashiCorp Vault Signed SSH (get signed SSH certs)

**Credentials → Add → Credential type: "HashiCorp Vault Signed SSH".** Same auth
fields (Server URL, AppRole role_id, AppRole secret_id, Namespace `AUT`, Path to
Auth `approle`, CA Certificate). There is **no** API Version field on this type.

**Expected result:** both credentials save without a validation error.

> **Rotating the SecretID:** because `secret_id` is single-use/short-lived, plan how
> AAP gets a fresh one. In practice you either (a) issue a longer-lived,
> CIDR-locked, multi-use `secret_id` reserved for AAP's credential store and rotate
> it on a schedule, or (b) automate re-wrapping + updating the AAP credential via
> `ansible.controller`. Keep whichever you choose CIDR-bound and out of git.

---

## Step 5 — Attach the credentials to a Job Template

- Attach **HashiCorp Vault Signed SSH** to the job template's **machine credential**
  so playbooks receive a Vault-signed `svc-aap` certificate at run time. Its
  metadata fields per link:
  - **Unsigned Public Key** — the SSH public key to sign
  - **Path to Secret** — the sign path, `ssh/sign/svc-aap` *(this field doubles as
    "path to sign"; there is no separate "Path to Sign" field)*
  - **Role Name** — `svc-aap`
  - **Valid Principals** — `svc-aap`
- Attach **HashiCorp Vault Secret Lookup** and map a job-template field/survey input
  to a KV key. Its metadata per link:
  - **Name of Secret Backend** — `secret`
  - **Path to Secret** — `aap/payments/db`
  - **Key Name** — `password`
  - **Secret Version (v2 only)** — leave empty for latest
- Mark any survey input holding a secret **sensitive** so it's masked in job output.

---

## Step 6 — Make managed nodes trust the Vault SSH CA

Signed SSH certs only work if the target nodes trust Vault's SSH CA. Run this
playbook (as a job template) against your managed hosts. It's idempotent — re-runs
fix any drift (flow #10 fetches the public CA key; flow #8 is the SSH itself).

```yaml
# playbooks/vault_ssh_trust.yml
- name: Trust Vault SSH CA for signed SSH
  hosts: managed
  become: true
  vars:
    vault_addr: "https://<vault-vip>:8200"
    vault_namespace: "AUT"
  tasks:
    - name: Fetch Vault SSH CA public key
      ansible.builtin.uri:
        url: "{{ vault_addr }}/v1/ssh/public_key"
        headers: { X-Vault-Namespace: "{{ vault_namespace }}" }
        return_content: true
        validate_certs: true
      register: ssh_ca

    - name: Install trusted CA keys file
      ansible.builtin.copy:
        content: "{{ ssh_ca.content }}"
        dest: /etc/ssh/trusted-user-ca-keys.pem
        owner: root
        group: root
        mode: "0644"

    - name: Configure sshd to trust the Vault CA
      ansible.builtin.blockinfile:
        path: /etc/ssh/sshd_config
        block: |
          PubkeyAuthentication yes
          TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
        marker: "# {mark} VAULT SSH CA (managed by AAP)"
      notify: restart sshd

    - name: Ensure svc-aap login user exists
      ansible.builtin.user: { name: svc-aap, shell: /bin/bash, create_home: true }

  handlers:
    - name: restart sshd
      ansible.builtin.service: { name: sshd, state: restarted }
```

> `/v1/ssh/public_key` is unauthenticated **by design** — it's a public key. The
> playbook's own SSH into the nodes uses the Vault-signed `svc-aap` cert from the
> machine credential in Step 4b/5.

---

## Step 7 — How a job runs (the whole picture)

```
Job template launches
  ├─ machine cred (Signed SSH): AAP → Vault AppRole login → ssh/sign/svc-aap → short-lived cert
  ├─ (optional) Secret Lookup cred: AAP → Vault AppRole login → secret/data/aap/<app>/… → value
  └─ playbook runs → SSH to managed node as svc-aap using the signed cert (node trusts Vault CA)
```

---

## Step 8 — Verify

```bash
# From an AAP host, prove AppRole login works and returns the right policies:
export VAULT_NAMESPACE=AUT
ROLE_ID=$(vault read -field=role_id auth/approle/role/aap-automation/role-id)
WRAP=$(vault write -wrap-ttl=120s -field=wrapping_token -f auth/approle/role/aap-automation/secret-id)
SECRET_ID=$(vault unwrap -field=secret_id "$WRAP")
vault write auth/approle/login role_id="$ROLE_ID" secret_id="$SECRET_ID"
# -> a token with policies [aap-kv-read aap-ssh-sign], short ttl

# Prove single-use: unwrapping the SAME wrap token again must FAIL
vault unwrap "$WRAP"    # expected: error (already used) — this is correct
```

- Run a job template using **Signed SSH**; confirm it gets a cert and connects as
  `svc-aap` to a node running the trust playbook.
- Run a job template using **Secret Lookup**; confirm a KV field resolves at launch
  (value masked in the log).
- Confirm reuse of a single-use `secret_id` is rejected.

---

## Step 9 — When you upgrade to AAP 2.7 (future)

AAP 2.7 adds **native OIDC** workload identity (Technology Preview). At that point
you can drop AppRole and give AAP its own JWT identity like CI has:

- Switch the credentials to the OIDC variants.
- Add a Vault `jwt` mount (`jwt-aap`) trusting AAP's OIDC discovery endpoint, with
  roles bound on org/job-template claims — **no secret_id stored at all**.
- The SSH data plane (this guide's Steps 5–6) is **unchanged**.

Until then, the hardened AppRole above is the simplest zero-trust-aligned option for
2.4. Next: **[05 — Verify & troubleshoot](05-verify-and-troubleshoot.md)**.
