# 03a — Generate the ZeroTrust signing key pair

The ZeroTrust plugin **signs** each JWT with a **private key**, and Vault **validates** it with the
matching **public key**. You create both halves here — once — then install each in its place:

- the **private** key goes into the CD/RO **Credential** the plugin signs with ([03 Step 1](03-cloudbees-cdro.md#step-1--create-the-zerotrust-plugin-configuration));
- the **public** key (`zerotrust-pub.pem`) goes into Vault's `jwt_validation_pubkeys` ([03 Step 3](03-cloudbees-cdro.md#step-3--configure-the-vault-jwt-mount-static-public-key)).

> **Do this on the RHEL host, offline.** Everything uses **`openssl`** (`1.1.1k`, ships on RHEL 8.10) —
> no downloads, no `pip`. Generate the keys on a trusted machine, never in the repo, and never commit
> them (`.gitignore` blocks `*.pem`).

> **New here? Two words:** an **asymmetric key pair** is a private key (kept secret, used to sign) plus a
> public key (shareable, used to verify). Anyone with the public key can check a signature; only the
> holder of the private key can create one. See the [glossary](00-before-you-begin.md#5-mini-glossary).

---

## Step 1 — Pick the algorithm (match the plugin's `Algorithm`)

The key **type** must match the `Algorithm` you set in the plugin configuration ([03 Step 1](03-cloudbees-cdro.md#step-1--create-the-zerotrust-plugin-configuration)).
Pick one row and use its command in Step 2.

| Plugin `Algorithm` | Key to generate | Why / notes |
|---|---|---|
| **`RS256`** *(recommended default)* / `RS384` / `RS512` | **RSA** 3072-bit | Widest compatibility; the suite's default. |
| `PS256` / `PS384` / `PS512` | **RSA** 3072-bit (same as RS*) | PS* is RSA with PSS padding — **reuse the same RSA key**. |
| `ES256` / `ES384` / `ES512` | **EC** P-256 / P-384 / P-521 | Smaller keys; curve must match (ES256→P-256, ES384→P-384, ES512→P-521). |
| `EdDSA` | **Ed25519** | Modern, fixed-strength; no size to choose. |
| `HS256` / `HS384` / `HS512` | *(not used)* | Symmetric — Vault can't validate with a **public** key. Do **not** use for this integration. |

> Unsure? Use **`RS256` + RSA 3072** — it works everywhere and is what the rest of these guides assume.

---

## Step 2 — Generate the private key

Run the **one** command for your chosen algorithm, then lock the file down so only you can read it.

**RSA (for `RS256/384/512` and `PS256/384/512`) — recommended default:**
```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out zerotrust-private.pem
chmod 600 zerotrust-private.pem
```

**EC (for `ES256` → P-256; use `P-384`/`P-521` for `ES384`/`ES512`):**
```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out zerotrust-private.pem
chmod 600 zerotrust-private.pem
```

**Ed25519 (for `EdDSA`):**
```bash
openssl genpkey -algorithm ED25519 -out zerotrust-private.pem
chmod 600 zerotrust-private.pem
```

**Expected result:** a file `zerotrust-private.pem` beginning with `-----BEGIN PRIVATE KEY-----`,
readable only by you (`-rw-------`).

---

## Step 3 — Extract the public key

Vault needs only the **public** half. Derive it from the private key (this never exposes the private key):

```bash
openssl pkey -in zerotrust-private.pem -pubout -out zerotrust-pub.pem
```

**Expected result:** `zerotrust-pub.pem` beginning with `-----BEGIN PUBLIC KEY-----`. This is the exact
PEM you paste into Vault's `jwt_validation_pubkeys`.

---

## Step 4 — Verify the pair

Confirm the type and size are what you intended before installing them.

```bash
# Private key: shows key type + size (e.g. "Private-Key: (3072 bit, 2 primes)")
openssl pkey -in zerotrust-private.pem -noout -text | head -1

# Public key: shows the public half (e.g. "Public-Key: (3072 bit)")
openssl pkey -pubin -in zerotrust-pub.pem -noout -text | head -1
```

**Expected result:** the sizes/curves match your chosen algorithm (RSA 3072, EC P-256, or ED25519).

---

## Step 5 — Install each half

- **Private key → CD/RO Credential.** In [03 Step 1](03-cloudbees-cdro.md#step-1--create-the-zerotrust-plugin-configuration),
  the plugin configuration's **`Credential`** field references a CD/RO credential that holds
  `zerotrust-private.pem`. Store it there (a *Secret file* or *Secret text* credential); lock its ACL so
  only the plugin configuration can read it.
- **Public key → Vault.** In [03 Step 3](03-cloudbees-cdro.md#step-3--configure-the-vault-jwt-mount-static-public-key),
  copy `zerotrust-pub.pem` to the Vault host (e.g. `/etc/pki/vault/zerotrust-pub.pem`) and pass it as
  `jwt_validation_pubkeys=@/etc/pki/vault/zerotrust-pub.pem`.

**Hardening checklist**

- [ ] Key type matches the plugin `Algorithm` (RS/PS→RSA, ES→matching EC curve, EdDSA→Ed25519).
- [ ] `zerotrust-private.pem` is `chmod 600`, generated **offline**, and **never committed** (`.gitignore` blocks `*.pem`).
- [ ] Only the **public** key leaves the trusted host; the private key goes **only** into the CD/RO Credential.
- [ ] The signing Credential's ACL is restricted to the plugin configuration.
- [ ] When rotating, the **old private key is destroyed** once retired (see below).

**Verify:** decode a JWT the plugin mints with your new key (`tools/inspect_jwt_claims.py`) — its header
`alg` matches your algorithm — and a Vault login with that token **succeeds** while a token signed by any
other key **fails**.

---

## Rotating the key

To rotate, generate a **new** pair with these same commands, then follow the coordinated cutover in
[03 Step 7 — Manual key-rotation runbook](03-cloudbees-cdro.md#step-7--manual-key-rotation-runbook)
(add the new **public** key to Vault first, swap the **private** key in the CD/RO Credential, then remove
the old public key after the token-lifetime overlap). Reference-layer detail:
[`../vault-integrations/03-cdro-zerotrust-jwt.md`](../vault-integrations/03-cdro-zerotrust-jwt.md) §7.

Next: **[03 — CloudBees CD/RO](03-cloudbees-cdro.md)** — use the key pair you just made.
