# 04a — AAP fetches secrets with a JWT handed over by CloudBees CD/RO

This guide covers a **different** way for an AAP job to get secrets than guide
[04](04-aap-approle-ssh.md). Instead of AAP proving itself with its **own** AppRole,
a **CloudBees CD/RO** pipeline mints a short-lived **ZeroTrust JWT**, hands it to an
AAP job, and the job uses that JWT to log in to Vault and fetch its secrets.

Use this when the *work* lives in AAP but the *trigger and the identity* live in
CD/RO — for example, a CD/RO release calls an AAP job to do a deploy, and that job
needs **dynamic** secrets (fresh database credentials, an SSH cert, a PKI cert) that
CD/RO's own KV-only reads can't produce.

> **This is the beginner "how do I actually do it" version.** The architect
> reference — the plugin field tables, the exact Vault role/policy, and the design
> rationale — is [`../vault-integrations/07-aap-ansibletower-jwt-consumer.md`](../vault-integrations/07-aap-ansibletower-jwt-consumer.md).
> The ready-to-copy files are in [`../vault-integrations/examples/`](../vault-integrations/examples/).

---

## When to use this vs. guide 04

| | **Guide 04** (AppRole) | **This guide, 04a** (CD/RO JWT) |
|---|---|---|
| Who starts the job | anyone (AAP schedule, survey, etc.) | a **CD/RO pipeline task** |
| How AAP proves identity to Vault | AAP's **own** hardened AppRole | a **JWT minted by CD/RO** for this one run |
| Best for | AAP-owned automation | CD/RO releases that call AAP and need **dynamic** secrets |
| Secret types | KV + signed SSH | KV **and** dynamic (DB creds / SSH / PKI) |

You can run **both** in the same AAP — they don't conflict.

---

## Requirements (check these first)

- **Guide [01](01-vault-setup.md)** done — the `jwt-cdro` Vault mount exists (static
  public key, `bound_issuer=ZeroTrust`). If not, do guide 01 and
  [03](03-cloudbees-cdro.md) first — this reuses that mount.
- **Guide [03](03-cloudbees-cdro.md)** done — the CD/RO **ZeroTrust** plugin is
  installed and configured, and the signing key pair from
  [03a](03a-zerotrust-key-generation.md) is in place.
- The **EC-AnsibleTower** plugin is installed in CD/RO.
- You can edit a Vault policy, a CD/RO pipeline, and an AAP job template.
- **AAP 2.4** (controller `4.5.25`) — works fine; no native OIDC needed because the
  JWT→Vault login happens **inside the playbook**.

Placeholders to swap in throughout: `<vault-vip>`, `AUT` (namespace),
`corp.example.com`, `payments-app` (release name), `aap.corp.example.com`.

---

## The picture (what you're building)

```
CD/RO pipeline
  Task 1  ZeroTrust plugin  → mint JWT (aud=vault-aap) → store in a SECURE property
  Task 2  EC-AnsibleTower   → "Launch a Job Template", pass the JWT as an extra_var
                                      │
                                      ▼
AAP job template "vault-jwt-consumer" runs a playbook that:
  1. logs in to Vault:  POST /v1/auth/jwt-cdro/login { role: aap-consumer, jwt: … }
  2. reads its secrets (KV + dynamic)
  3. uses them, then revokes its token
```

CD/RO never sees the secret. AAP borrows CD/RO's short-lived identity for one job.

---

## Step 1 — Add a Vault role and policy for the AAP job

On your Vault admin host. This reuses the `jwt-cdro` mount from guide 03 but adds a
**separate role** (`aap-consumer`) bound to its **own audience** (`vault-aap`) so this
path can't be mixed up with CD/RO's own KV reads.

**1a. Create the role:**

```bash
export VAULT_NAMESPACE=AUT
vault write auth/jwt-cdro/role/aap-consumer \
    role_type="jwt" user_claim="sub" \
    bound_audiences="vault-aap" \
    bound_claims_type="glob" bound_claims='{"sub":"aap_job","job_name":"*"}' \
    claim_mappings='{"job_name":"release"}' \
    token_policies="aap-consumer" \
    token_ttl="15m" token_max_ttl="15m"
```

**1b. Write the policy** (KV read scoped to the release, plus one dynamic DB path).
Find your mount accessor first, then substitute it:

```bash
vault auth list -detailed        # copy the Accessor for the jwt-cdro/ mount
```

Create `aap-consumer.hcl` (replace `<jwt-cdro-accessor>` with that value):

```hcl
# KV v2 — this run can only read its own release's secrets
path "secret/data/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/cdr/{{identity.entity.aliases.<jwt-cdro-accessor>.metadata.release}}/*" {
  capabilities = ["read", "list"]
}

# Dynamic database credentials (the reason to hand off to AAP)
path "database/creds/app-readonly" {
  capabilities = ["read"]
}
```

Then load it:

```bash
vault policy write aap-consumer aap-consumer.hcl
```

**What you should see:** `Success! Uploaded policy: aap-consumer`.

> Only add the dynamic paths this job actually uses. If you don't use dynamic DB
> creds yet, delete that `database/creds/...` block — you can add it later.

---

## Step 2 — Tell the CD/RO ZeroTrust plugin to mint an AAP-targeted JWT

In CD/RO, open (or create) a **ZeroTrust plugin Configuration** for this — call it
`vault-aut-aap`. The one field that matters here is **customClaims**. Set it so the
audience matches the Vault role you just made:

```json
{"sub":"aap_job","aud":"vault-aap","job_name":"$[/myRelease/name]"}
```

Keep the other fields as in guide 03 (`Issuer=ZeroTrust`, `Algorithm=RS256`,
`Token lifetime=900`).

- `aud=vault-aap` **must equal** the role's `bound_audiences` from Step 1a.
- `job_name` becomes the `release` that scopes the KV policy.

---

## Step 3 — Create the AAP job template (and the one setting people forget)

1. In the AAP automation controller, make a **Project** pointing at the repo that
   holds the playbook (Step 4).
2. Create a **Job Template** named **`vault-jwt-consumer`** that runs that playbook on
   a suitable inventory / execution environment.
3. **Open the template → Variables → tick "Prompt on launch."**

> ⚠️ **This tick is mandatory.** Without it (or an equivalent Survey field), AAP
> **silently ignores** the `extra_vars` that CD/RO sends — the JWT never reaches your
> playbook and you'll get a confusing "vault_jwt is undefined" error. This is the #1
> thing that goes wrong.

---

## Step 4 — Add the playbook

Two ready-to-use playbooks are in the reference examples folder — **copy one** into
your AAP project repo:

- **Normal execution environment:**
  [`../vault-integrations/examples/aap-vault-jwt.yml`](../vault-integrations/examples/aap-vault-jwt.yml)
  (uses the `community.hashi_vault` collection).
- **Airgapped EE without that collection:**
  [`../vault-integrations/examples/aap-vault-jwt-nocollection.yml`](../vault-integrations/examples/aap-vault-jwt-nocollection.yml)
  (pure `ansible.builtin.uri`, no dependencies).

Edit the `vars:` block at the top to your site values (`vault_addr`,
`vault_namespace: AUT`, `vault_validate_certs`, and the dynamic DB role if you use
one). Point the job template at whichever file you copied.

**What the playbook does, in plain terms:** it checks the JWT arrived, logs in to
Vault once, reads the KV secret for this release, generates fresh DB credentials,
uses them, and revokes its token at the end. Every step that touches a secret has
`no_log: true` so nothing leaks into the job output — **leave that in**.

---

## Step 5 — Wire the two CD/RO tasks together

In your CD/RO pipeline, add two tasks (full example:
[`../vault-integrations/examples/cdro-ansibletower-jwt.dsl`](../vault-integrations/examples/cdro-ansibletower-jwt.dsl)):

**Task 1 — mint the JWT (ZeroTrust plugin → `IssueJwtAndStoreInProperty`):**

- Configuration: `vault-aut-aap`
- Store the token in a **secure/masked** property, e.g. `/myPipelineRuntime/jwtToken`.

**Task 2 — launch the AAP job (EC-AnsibleTower → "Launch a Job Template"):**

- **Configuration name:** your EC-AnsibleTower config (e.g. `aap-prod`)
- **Job template name/ID:** `vault-jwt-consumer`
- **Job template parameters:**

```json
{
  "extra_vars": {
    "vault_jwt":  "$[/myPipelineRuntime/jwtToken]",
    "vault_role": "aap-consumer",
    "release":    "$[/myRelease/name]"
  }
}
```

Make Task 2 depend on Task 1 so the property is filled first.

> **Set up the EC-AnsibleTower config once** if you haven't: CD/RO → Plugin
> Management → Plugin configurations → add **EC-AnsibleTower** with **Ansible Tower
> Server** = `https://aap.corp.example.com/api/controller/v2`, an **Auth scheme**
> (Bearer token or Basic Auth) for a least-privilege AAP service account, the **AAP
> version** (`2.4`), and **Debug level = Info**.

---

## Step 6 — Run it and check

Run the CD/RO pipeline. Then confirm:

```bash
export VAULT_NAMESPACE=AUT
vault read auth/jwt-cdro/role/aap-consumer   # bound_audiences=vault-aap, user_claim=sub
vault policy read aap-consumer               # templated cdr/<release>/* + your dynamic path
```

- The AAP job finishes green and its output shows lines like
  `KV read OK — keys present: [...]` and `Dynamic DB user issued: v-...` —
  **but never a password** (that's the `no_log` working).
- In Vault's audit log / SIEM, the read is attributed to the **AAP job's JWT**
  (release `payments-app`), not to a broker or the CD/RO server.
- The CD/RO property holding the JWT is **masked** in the pipeline log.

---

## If it doesn't work

| What you see | Most likely cause | Fix |
|---|---|---|
| `vault_jwt is undefined` in the AAP job | Step 3 tick missing | Enable **Variables → Prompt on launch** (or add a Survey field `vault_jwt`). |
| Vault login `400 invalid audience` | `aud` ≠ role audience | Make both `vault-aap` (Step 1a and Step 2). |
| Login OK but read is `403` | policy not scoped to this release, or dynamic path not granted | Fix `aap-consumer.hcl` (Step 1b); recheck the accessor. |
| `invalid signature` / `no key to validate` | wrong/old public key or algorithm | Re-check guide [03](03-cloudbees-cdro.md) §2 and the key pair from [03a](03a-zerotrust-key-generation.md). |
| The JWT appears in AAP job output | Debug/Trace level, or `no_log` removed | Set Debug level = Info; restore `no_log: true`. |
| `community.hashi_vault` not found | airgapped EE without it | Use the `...-nocollection.yml` playbook. |

---

## What's next

- Need AAP's own standing identity instead (no CD/RO trigger)? That's guide
  [04](04-aap-approle-ssh.md) (hardened AppRole + signed SSH).
- Full field-level detail and the "various ways" to use the hand-off:
  [`../vault-integrations/07-aap-ansibletower-jwt-consumer.md`](../vault-integrations/07-aap-ansibletower-jwt-consumer.md).
- Prove the whole chain and fix common failures:
  **[05 — Verify & troubleshoot](05-verify-and-troubleshoot.md)**.
