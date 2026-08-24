# 02 — Signing Agent Build (static Linux VM agents)

> **Prereqs:** `01` complete. Static, long-lived CloudBees CI Linux VM agents under configuration
> management (Ansible/Puppet/Chef). TPP `/vedauth` and `/vedhsm` reachable from the agent subnet.
>
> **Ownership:** **Platform engineering** builds and maintains the agent image/role. **PKI team**
> supplies the client package and the TPP CA bundle. **CI engineering** consumes via an agent label.

---

## 1. Dedicate a signing agent label

Do **not** install the signing client on every agent. Create a dedicated label, e.g. `container-signer`,
applied to a small pool.

Why this matters: any agent that can hold a grant can request signatures while that grant is live. A
small, hardened, separately-audited pool shrinks that blast radius and makes the Venafi audit log's
source-host alerting (`01 §9`) meaningful.

Harden the pool:

- No general-purpose jobs — restrict via job/folder-to-label binding.
- `Job/Configure` restricted on the signing job (this is also the SECURITY-3574 mitigation noted in
  `../vault-integrations/02-cloudbees-ci-oidc.md §1`).
- Shell access limited to platform engineering; sudo audited.
- Host-level EDR and file-integrity monitoring on `/etc/venafi/` and the cosign binary.

---

## 2. Network prerequisites

| From | To | Port | Purpose |
|---|---|---|---|
| Signing agent | `https://<tpp>/vedauth` | 443 | Grant acquisition / refresh / revocation |
| Signing agent | `https://<tpp>/vedhsm` | 443 | Signing operations (virtual HSM) |
| Signing agent | Harbor | 443 | Image and signature push/pull |
| Signing agent | Prisma Console | 443 | twistcli scan |
| Signing agent | Vault (`AUT`) | 8200 | Secret retrieval |
| TPP | CI controller `/oidc/**` | 443 | JWKS fetch — **only if using JWT Mapping (`01 §6.3`)** |

TLS to TPP must validate. Deploy the internal CA bundle and reference it via the client's **CA Trust**
setting (§4). **Never** set **Chain Validation** to `No`/`Disabled`/`0` — the vendor states plainly it
*"must not be used in production environments"*, and disabling it makes the signing channel
man-in-the-middleable.

---

## 3. Install cosign — the correct binary

> **This is the single most common failure in this integration.** The stock `cosign-linux-amd64` release
> asset is built **without PKCS#11 support**. It will fail on a `pkcs11:` key URI with an unhelpful error.

You must use the release asset with **`pivkey-pkcs11key`** in its filename:

```bash
COSIGN_VERSION="v2.4.1"          # pin; verify against your approved-software list
COSIGN_ASSET="cosign-linux-pivkey-pkcs11key-amd64"

curl -fsSLo /usr/local/bin/cosign \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${COSIGN_ASSET}"

# Verify the checksum against the release's checksums file before trusting it
curl -fsSLo /tmp/cosign_checksums.txt \
  "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign_checksums.txt"
grep " ${COSIGN_ASSET}\$" /tmp/cosign_checksums.txt | sha256sum -c -

chmod 0755 /usr/local/bin/cosign
```

Confirm PKCS#11 support is actually present:

```bash
cosign version
cosign pkcs11-tool --help    # must not error; absence of this subcommand = wrong binary
```

> **Mirror it.** Vendor this asset to your internal artifact repository and install from there. Pulling
> a signing tool from the public internet at agent-build time is a supply-chain dependency inside your
> supply-chain control.
>
> **Version floor.** Venafi documents cosign 1.3+. Use a current 2.x. If you later pilot the
> `sigstore-kms-venafi` plugin (`07 §8`), that requires **v2.4.3+**.

---

## 4. Install and configure the CodeSign Protect client

Install the Venafi Code Signing client (21.4 or newer; pin one version fleet-wide) from the PKI team's
package — `venafi-codesigningclients-<version>-linux-x86_64.rpm` / `.deb`.

Configuration lives in two places on Linux:

| Scope | Path |
|---|---|
| Machine configuration | `/etc/venafi/libhsm.conf` |
| User configuration (PKCS#11) | `~/.venafipkcs11config` |

Set the server URLs and CA trust once, at agent build time, via configuration management:

```bash
# Point the client at TPP's two endpoints
pkcs11config seturls \
    --authurl:https://tpp.corp.example.com/vedauth \
    --hsmurl:https://tpp.corp.example.com/vedhsm

# Trust the internal CA that issues TPP's TLS certificate
pkcs11config trust --certfile:/etc/pki/ca-trust/source/anchors/corp-root-ca.pem

# Sanity check
pkcs11config health
pkcs11config version
```

Relevant configuration values you may need to tune (`pkcs11config option`):

| Value | Default | Note |
|---|---|---|
| Auth Server Url | — | `/vedauth` |
| Hsm Server Url | — | `/vedhsm` |
| CA Trust | — | Absolute path in machine config; relative to `$HOME` in user config |
| Chain Validation | enabled | **Leave enabled.** |
| Network Timeout | 30000 ms | Raise only if TPP is genuinely slow; a raised timeout lengthens build hangs |
| **Request Timeout** | *server-side* | **Not a client setting.** Configured in VCC → Code Signing → Properties → Global Configuration and *"pushed from server to clients"* (`01 §3.3`). If signing times out in CI and the client timeouts look correct, check this |
| First Error Timeout | 15000 ms | Cascading timeout on first failure |
| Multiple Error Timeout | 2000 ms | Prevents long hangs when TPP is unreachable |

> **Note the option syntax.** `pkcs11config` uses `--option:value` (colon), not `--option=value`. Both
> single and double dashes appear in vendor examples. Mixing this up produces confusing parse errors.

Record the client version in the agent's software inventory — `07` covers the upgrade path.

---

## 5. The grant model

A **grant** is the client's authenticated session with TPP. No grant, no signing. Grants are per-user (or
per-machine with `--machine`) and are stored in the client configuration.

| Command (24.1 / 24.3) | Purpose |
|---|---|
| `pkcs11config getgrant` | Obtain or refresh a grant |
| `pkcs11config checkgrant` | Check grant validity — **RC 0 = valid, RC 1 = missing/expired** |
| `pkcs11config revokegrant` | Revoke the grant |
| `pkcs11config list` | List available objects (certificates/keys) |
| `pkcs11config getpublickey` | Export a public key |

> **⚠ Command names changed after 24.3.** In 25.3/26.1 these are `login`, `checklogin`, `logout`,
> `settoken`. Options are otherwise identical. When you upgrade, update the pipeline's shared library in
> `04` — this is the only code change an upgrade requires. Keep the command names in one shell function
> so the change is a single edit.

Acquire a grant (Option B, JWT — preferred):

```bash
pkcs11config getgrant --force --jwtfile:"${JWT_FILE}"
```

Acquire a grant (Option A, username/password):

```bash
pkcs11config getgrant --force \
    --hostname:tpp.corp.example.com \
    --username:"${VENAFI_USER}" \
    --password:"${VENAFI_PASS}"
```

> `--force` obtains a genuinely new grant. Without it, a stored refresh token is used to renew and
> *"any other provided credentials are ignored"* — which silently masks credential rotation. Use
> `--force` in CI so each build's identity is real.

Pre-flight check, exactly as the vendor intends it — the docs state `checkgrant` is *"designed to allow
automated systems, such as a builder or monitoring system, to programmatically check if the grant is
still valid in preflight checks"*:

```bash
if ! pkcs11config checkgrant --days:1 >/dev/null 2>&1; then
    echo "No valid Venafi grant — acquiring"
    pkcs11config getgrant --force --jwtfile:"${JWT_FILE}"
fi
```

Revoke on teardown — **always**, including on failure (see the `post { always { ... } }` block in `04 §8`):

```bash
pkcs11config revokegrant --force --clear
```

`--clear` removes stored configuration after revoking, leaving nothing reusable on the agent.

---

## 6. Concurrency isolation — `LIBHSMINSTANCE`

Static agents run multiple executors. Two concurrent builds sharing one user configuration
(`~/.venafipkcs11config`) will fight over the grant: one build's `revokegrant` in `post{}` kills the
other's in-flight signing.

The client supports this natively. **`LIBHSMINSTANCE`** *"sets an instance for the configuration to
use"* — each instance carries its own independent grant. The vendor's own example:

```bash
export LIBHSMINSTANCE=foo
pkcs11config getgrant -hsm server1.company.com -user user1
export LIBHSMINSTANCE=bar
pkcs11config getgrant -hsm server2.company.com -user user2
pkcs11config list
# <results for user2 on server2>
export LIBHSMINSTANCE=foo
pkcs11config list
# <results for user1 on server1>
```

**Set a unique instance per build.** In the pipeline (`04 §4`):

```bash
export LIBHSMINSTANCE="ci-${BUILD_TAG}"      # BUILD_TAG is unique per build
```

Belt and braces — also isolate `HOME` per build so the on-disk user configuration cannot collide:

```bash
export HOME="${WORKSPACE}/.agenthome"
mkdir -p "${HOME}"
```

> Without this, the failure mode is intermittent and nightmarish: signing works under low load and fails
> sporadically under parallel builds. Configure it from day one.

---

## 7. The PIN in the key URI

Venafi's documented cosign key URI includes `pin-value=`:

```
pkcs11:token=Remote%20Token;slot-id=0;id=%44%65%76;object=container-prod?module-path=/usr/local/lib/venafipkcs11.so&pin-value=<pin>
```

Two observations:

1. **The vendor's own examples use throwaway values** — `pin-value=34` and `pin-value=sdf`. Authentication
   to TPP is carried by the **grant**, not by the PKCS#11 PIN. The PIN field appears to be a placeholder
   the PKCS#11 layer requires syntactically.
2. Regardless, **never interpolate a real secret into that URI on a command line.** It lands in the
   process table (`ps`), in `set -x` output, and in the Jenkins console log — which is retained and
   broadly readable.

Handling, in order of preference:

- Use a non-secret placeholder PIN, and rely on the grant for authentication. **Confirm this in your
  environment during the `08` validation run** — if a real PIN is required, fall through to the next option.
- Use RFC 7512 `pin-source=/path/to/file` pointing at a file on tmpfs with mode `0600`, deleted in
  `post{}`. *Confirm the Venafi module honours `pin-source`.*
- If a literal `pin-value` is unavoidable, build the URI inside a `set +x` block, pass it via an
  environment variable rather than a Groovy string, and confirm it is masked in console output.

---

## 8. Discover the key URI

Run once per environment, after a grant exists, and record the result — it is stable and belongs in the
pipeline configuration (not discovered at build time):

```bash
cosign pkcs11-tool list-tokens --module-path /usr/local/lib/venafipkcs11.so
cosign pkcs11-tool list-keys-uris --module-path /usr/local/lib/venafipkcs11.so
```

Expected shape:

```
Object 0
  Label: container-prod
  ID:    636f6e7461696e65722d70726f64
  URI:   pkcs11:token=Remote%20Token;slot-id=0;id=%63%6f%6e...;object=container-prod?module-path=/usr/local/lib/venafipkcs11.so&pin-value=1234
```

> **`token=Remote Token` is the confirmation that signing is remote** and no key material is local. If
> you see a different token name, you are talking to a local token — stop and investigate.
>
> **Module path varies by platform:** `/usr/local/lib/venafipkcs11.so` and
> `/usr/lib/venafi/venafipkcs11.so` both appear in vendor docs; macOS uses
> `/Library/Venafi/CodeSigning/lib/venafipkcs11.so`. Confirm the path your package installs and pin it
> in configuration management.

---

## 9. Configuration-management role — what to converge

```
role: container-signing-agent
  packages:
    - venafi-codesigningclients (pinned version)
    - podman (site standard)
  files:
    - /usr/local/bin/cosign                     # pivkey-pkcs11key build, checksum-verified
    - /usr/local/bin/twistcli                   # from Prisma Console, pinned
    - /etc/pki/.../corp-root-ca.pem
  exec (idempotent):
    - pkcs11config seturls --authurl:... --hsmurl:...
    - pkcs11config trust --certfile:...
  assertions:
    - pkcs11config health           exits 0
    - cosign pkcs11-tool --help     exits 0
    - podman --version              exits 0
  monitoring:
    - file integrity: /etc/venafi/, /usr/local/bin/cosign
```

**No grant is provisioned at build time.** Grants are per-build and short-lived. An agent at rest holds
no Venafi session.

---

## 10. Acceptance checklist

- [ ] `container-signer` label exists; job binding restricts what can run there
- [ ] Firewall flows open to `/vedauth`, `/vedhsm`, Harbor, Prisma, Vault
- [ ] cosign is the `pivkey-pkcs11key` build; `cosign pkcs11-tool --help` succeeds; checksum verified; mirrored internally
- [ ] Client installed and pinned; `pkcs11config health` passes; Chain Validation enabled
- [ ] Manual `getgrant` → `list` → `getpublickey` → `revokegrant` cycle succeeds end to end
- [ ] `cosign pkcs11-tool list-keys-uris` returns `token=Remote Token` and the expected object label
- [ ] Key URI recorded in pipeline configuration
- [ ] `LIBHSMINSTANCE` isolation verified with two concurrent grants on one agent
- [ ] No grant persists on the agent at rest

---

## Sources

- [Sigstore cosign integration (24.3)](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-integration-sigstore.php)
- [pkcs11config utility reference (24.3)](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/r-codesigning-pkcs11config.php)
- [Configuration values and environment variables](https://docs.venafi.com/Docs/current/TopNav/Content/CodeSigning/r-codesigning-pkcs11-config-values.php)
- [Setting up PKCS#11 clients](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-working-with-pkcs11.php)
- [cosign releases](https://github.com/sigstore/cosign/releases)
