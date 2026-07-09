# 04 — AAP ⇄ Vault via mTLS Cert Auth + Signed SSH (ALTERNATIVE)

> **⚠️ This is the documented *alternative*. The primary AAP auth method is now hardened AppRole** —
> see **[`../getting-started/04-aap-approle-ssh.md`](../getting-started/04-aap-approle-ssh.md)**. AppRole
> was chosen because it avoids the AD CS enrollment/renewal automation this cert-auth path depends on (see
> the decision record in `00-architecture-overview.md` §8). Use this cert-auth page only if you already
> operate automated AD CS enrollment and prefer host-cert identity.
>
> AAP is **2.4 (automation controller 4.5.25)** on **VMs** → **no native OIDC** (that arrived in 2.7 as
> Technology Preview). This alternative uses **TLS client-cert auth** with your **AD CS**-issued certs.
> AAP consumes **signed SSH certificates** for managed nodes and **KV v2 static secrets** (Secret Lookup
> plugin).
>
> **Control plane:** AAP → Vault `auth/cert-aap` (mTLS). **Data plane:** Vault SSH CA signs short-lived
> certs; managed nodes trust the CA via `TrustedUserCAKeys`.
>
> **Dependency / known gap (why AppRole is preferred):** automated **AD CS enrollment + renewal** of the
> client cert onto the AAP controller/EE hosts. Until that lands, cert auth works with a manually placed
> cert but won't rotate — which is exactly the blocker AppRole sidesteps.

---

## 1. Vault side (from guide `01`, recap)

- `auth/cert-aap` trusts the **AD CS chain** (`certificate=@adcs-chain.pem`), bound to the AAP host cert
  names (`allowed_common_names="aap-*.corp.example.com"`), granting `aap-ssh-sign` + `aap-kv-read`.
- `ssh/roles/svc-aap` signs client certs with principal `svc-aap`, TTL ≤ 2 h.
- `secret/` (KV v2) holds `secret/data/aap/<app>/…`.

Confirm:
```bash
export VAULT_NAMESPACE=AUT
vault read auth/cert-aap/certs/aap
vault read ssh/roles/svc-aap
```

---

## 2. Client certificate on the AAP hosts (AD CS)

The AAP controller (and execution nodes/EEs that talk to Vault) each need an AD CS-issued **client
certificate** whose CN/SAN matches `allowed_common_names`.

- **Now:** enroll via AD CS (autoenrollment / `certreq` / NDES/SCEP / ACME) to `aap-*.corp.example.com`
  with EKU **Client Authentication**. Place cert+key where AAP can read them for the credential.
- **Renewal (the gap):** wire AD CS autoenrollment or your enrollment tool to rotate before expiry.
  Vault trusts the CA, so re-issued certs keep working with no Vault change.
- **Venafi (future):** when AD CS is replaced, only the trust anchor in `auth/cert-aap/certs/aap`
  (`certificate=…`) and `allowed_*` bindings change; roles/policies are unchanged.

---

## 3. AAP credentials (`ansible.controller` collection)

### 3.1 Signed-SSH credential (auth via TLS/cert)

```yaml
- name: Vault Signed SSH (cert auth)
  ansible.controller.credential:
    name: "vault-signed-ssh"
    credential_type: "HashiCorp Vault Signed SSH"
    organization: "AUT"
    inputs:
      url: "https://vault-vip.corp.example.com:8200"
      namespace: "AUT"                       # Vault Enterprise namespace
      default_auth_path: "cert-aap"          # the cert auth mount
      role: "aap"                            # cert auth role
      client_cert_public: "{{ lookup('file', '/etc/pki/aap/client.crt') }}"
      client_cert_private: "{{ lookup('file', '/etc/pki/aap/client.key') }}"
      cacert: "{{ lookup('file', '/etc/pki/aap/vault-ca.crt') }}"
```

Attach it to the **machine credential** used by job templates so playbooks receive a Vault-signed SSH cert
for `svc-aap` at run time. Configure the SSH secret engine path/role to `ssh` / `svc-aap`.

### 3.2 KV v2 Secret Lookup credential (same cert auth)

```yaml
- name: Vault KV Lookup (cert auth)
  ansible.controller.credential:
    name: "vault-kv-lookup"
    credential_type: "HashiCorp Vault Secret Lookup"
    organization: "AUT"
    inputs:
      url: "https://vault-vip.corp.example.com:8200"
      namespace: "AUT"
      default_auth_path: "cert-aap"
      role: "aap"
      client_cert_public: "{{ lookup('file', '/etc/pki/aap/client.crt') }}"
      client_cert_private: "{{ lookup('file', '/etc/pki/aap/client.key') }}"
      cacert: "{{ lookup('file', '/etc/pki/aap/vault-ca.crt') }}"
      api_version: "v2"
```

Then map job-template credential fields to KV keys (metadata: `secret_path=aap/<app>/…`, `secret_key=…`).
Mark survey inputs sensitive so they're masked in job output.

> **Version check:** confirm your controller 4.5.x Signed-SSH/Secret-Lookup plugin exposes the TLS
> (`client_cert_public`/`client_cert_private`) fields. If a field name differs on your build, adjust to
> the plugin's input schema — the auth method (`cert`) and Vault side are unchanged.

---

## 4. Managed-node SSH trust (AAP playbook, ongoing)

An AAP job template runs this against all managed nodes; it fetches the Vault SSH CA public key and
configures sshd. Re-runs converge and self-heal drift.

```yaml
# playbooks/vault_ssh_trust.yml
- name: Trust Vault SSH CA for signed SSH
  hosts: managed
  become: true
  vars:
    vault_addr: "https://vault-vip.corp.example.com:8200"
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
        owner: root; group: root; mode: "0644"

    - name: Configure sshd to trust the Vault CA + allow pubkey auth
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

> `/v1/ssh/public_key` is unauthenticated by design (it's a public key). The playbook's own SSH into the
> nodes uses the Vault-signed `svc-aap` cert from the machine credential in §3.1.

---

## 5. End-to-end job flow

```
Job template launches
  ├─ machine cred (vault-signed-ssh): AAP → Vault cert-aap login → ssh/sign/svc-aap → signed cert
  ├─ (optional) kv lookup cred: AAP → Vault cert-aap login → secret/data/aap/<app>/… → field value
  └─ playbook runs → SSH to managed node as svc-aap using the signed cert (node trusts Vault CA)
```

---

## 6. Future: cut over to native OIDC (AAP 2.7)

When AAP is upgraded to **2.7+**:
- Switch the credentials to **HashiCorp Vault Signed SSH (OIDC)** / **Secret Lookup (OIDC)**.
- Configure a Vault `jwt` mount (`jwt-aap`) trusting AAP's OIDC discovery endpoint; roles bound on
  org/job-template claims — no client cert stored.
- The **SSH data plane is unchanged** (same SSH engine, `svc-aap` role, node trust).
- Note 2.7 OIDC-for-Vault is Technology Preview at time of writing — confirm support stance.

---

## 7. Verification

```bash
# Vault sees the cert-auth login work (from an AAP host):
curl --cert /etc/pki/aap/client.crt --key /etc/pki/aap/client.key \
     --cacert /etc/pki/aap/vault-ca.crt \
     -H "X-Vault-Namespace: AUT" \
     -X POST https://vault-vip.corp.example.com:8200/v1/auth/cert-aap/login \
     -d '{"name":"aap"}' | jq '.auth.policies'
# → ["aap-ssh-sign","aap-kv-read"], short lease_duration
```

- Run the node-trust playbook; confirm `/etc/ssh/trusted-user-ca-keys.pem` + sshd config on nodes.
- Run a job template using `vault-signed-ssh`; confirm it obtains a signed cert and connects as `svc-aap`.
- Run a job template using `vault-kv-lookup`; confirm a KV field resolves at launch (value masked in log).
- Confirm cert renewal (once AD CS enrollment automation is in place) rotates without a Vault change.
