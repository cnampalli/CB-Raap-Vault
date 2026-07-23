# Getting Started: Zero-Trust Vault Integration (Beginner Series)

This is a **step-by-step, copy-paste** guide series for connecting three
platforms to **HashiCorp Vault Enterprise** so they can fetch secrets **without
storing any static password or long-lived token**:

- **CloudBees CI** (Jenkins controllers)
- **CloudBees CD/RO** (release orchestration)
- **Ansible Automation Platform (AAP)**

You do **not** need to be a Vault expert. Each page tells you exactly what to
type, what you should see back, and what to do if it fails. If you can open a
terminal and a web UI, you can follow this.

> **Already an architect?** The deeper design rationale, decision records, and
> firewall matrices live in the reference series at
> [`../vault-integrations/`](../vault-integrations/). This beginner series is the
> "how do I actually do it" layer; that one is the "why it's built this way" layer.

---

## What "zero trust" means here (in one paragraph)

Instead of putting a password or a permanent Vault token inside CI/CD/RO/AAP
(which could be stolen), each platform **proves who it is at the moment it needs
a secret** and receives a **short-lived** token that expires in minutes. CI
proves itself with a per-build signed **JWT** (OpenID Connect). AAP proves itself
with a hardened **AppRole**. CD/RO proves itself with its **own** signed JWT, minted
by the **ZeroTrust** plugin inside a procedure step (a CI broker is kept only as a
fallback). Nothing long-lived is stored, everything is logged, and access to servers
uses **short-lived signed SSH certificates** instead of static keys.

---

## Your confirmed environment

These guides are written against **your** versions. If any of these change,
re-check the affected guide.

| Component | Version | Auth method to Vault |
|---|---|---|
| CloudBees CI | Client Controller `2.528.3.35200-rolling` | OIDC per-build **JWT** |
| — OpenID Connect Provider plugin | `111.v29fd614b_3617` | (this version is safe — see [02](02-cloudbees-ci.md)) |
| CloudBees CD/RO | `2024.09.0.176472` (airgapped VMs) | **ZeroTrust plugin** JWT (`iss=ZeroTrust`, static-pubkey); CI broker = fallback |
| HashiCorp Vault Enterprise | `1.20.8+ent`, namespace `AUT` | — |
| Ansible Automation Platform | **2.4** (automation controller `4.5.25`) | **AppRole** (hardened) |

> **Note on AAP version:** automation controller `4.5.25` ships in **AAP 2.4**
> (AAP 2.5 ships controller `4.6.x`). AAP's *native* OIDC login is a Technology
> Preview in **2.7**, so on 2.4 the simplest zero-trust-aligned method is a
> **hardened AppRole**. See [04](04-aap-approle-ssh.md).

---

## Read in this order

1. **[00 — Before you begin](00-before-you-begin.md)** — prerequisites, the few
   concepts you need, the network flows to request, and who does what.
2. **[01 — Set up Vault (the `AUT` namespace)](01-vault-setup.md)** — the shared
   foundation. Do this first; everything else builds on it.
3. **[02 — CloudBees CI](02-cloudbees-ci.md)** — connect CI with per-build JWT,
   inspect the token's claims, and pick one of three pipeline styles.
4. **[03 — CloudBees CD/RO](03-cloudbees-cdro.md)** — mint a ZeroTrust JWT in a
   procedure and read release-scoped secrets directly (CI broker kept as fallback).
   - *First-time setup:* **[03a — Generate the ZeroTrust signing key pair](03a-zerotrust-key-generation.md)**
     (`openssl`) — the private key for the plugin, the public key for Vault.
5. **[04 — Ansible Automation Platform](04-aap-approle-ssh.md)** — hardened AppRole
   login + Vault-signed SSH to managed nodes.
   - *Alternative path:* **[04a — AAP fetches secrets with a CD/RO-handed JWT](04a-aap-jwt-from-cdro.md)**
     — a CD/RO release mints a ZeroTrust JWT and an AAP job uses it to read KV +
     **dynamic** secrets (EC-AnsibleTower hand-off).
6. **[05 — Verify & troubleshoot](05-verify-and-troubleshoot.md)** — prove it works
   and fix the common failures.

---

## Airgapped ground rules (read before you start)

Your environment has **no internet access**. These guides respect that:

- **No downloads mid-procedure.** Every command uses tools already on the host
  (`vault`, `curl`, `ssh`, the platform UIs) or explicitly lists what the airgapped
  image must already contain.
- **Private CA everywhere.** Vault's TLS is signed by your internal CA, so commands
  pass `--cacert`/import the CA into truststores. Replace `/etc/pki/.../ca.crt`
  paths with your real CA bundle location.
- **Placeholders are yours to fill.** `<vault-vip>`, `<ci-ctrl>`, `AUT`,
  `10.20.0.0/24`, `corp.example.com`, `payments` are examples — swap in your real
  hostnames, namespace, IP ranges, and app names.
- **Two optional helper scripts** live in [`../../tools/`](../../tools/)
  (`inspect_jwt_claims.py`, `check_oidc_discovery.py`). They are pure Python 3
  standard library (no `pip install`, no internet) so they run on an airgapped
  jump host. They are conveniences — every guide also shows the manual way.

If something in a guide assumes a binary or plugin you don't have, that guide's
**Requirements** box will say so, and there is almost always a plainer alternative.
