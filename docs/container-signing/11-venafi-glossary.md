# 11 — Glossary

> Terminology across Venafi, Sigstore/cosign, Harbor and the surrounding toolchain. Entries marked **⚠**
> are ones that are commonly misunderstood — read those first if you are new.

---

## Venafi / CodeSign Protect

**Aperture** ⚠ — the modern **web** console for Trust Protection Platform, renamed **OneVenafi**. Handles
*"most activities (including non-admin activities)"*, including TLS Protect and CodeSign Protect **projects
and environments**. It does **not** handle CA templates or environment templates — those are in the *Venafi
Configuration Console*.

**MMC snap-in** — a module loaded into the Windows Microsoft Management Console (`mmc`). The CodeSign
Protect administration surface is one of these. Installed from `VenafiMmc-<version>.msi`; requires the
`vedsdk` and `vedauth` URLs plus credentials; loaded via **File → Add/Remove Snap-In → Venafi CodeSign
Protect Administration**. Installable on any Windows workstation — no need to sign in to the TPP server.

**OneVenafi** — the current name for *Aperture*.

**Policy Tree** — the classic **web** admin console, formerly **WebAdmin**. *"Most of the features in this
experience are configuration and administrative activities"*, and it is *"gradually being retired"* as
features move to Aperture. Still required for configuring a CA, applications, workflows, and all reporting.

**Code Sign Client** — 25.3+ name for the Venafi Code Signing Client. See *Venafi Code Signing Client*.

**Code Sign Manager - Self-Hosted** — 25.3+ name for CodeSign Protect, following the CyberArk acquisition.
Same product.

**Code Signing Administrator** — the role that configures global code signing defaults, creates Environment
Templates and Flows, and approves or denies new project requests.

**CodeSign Protect** — the TPP module that protects and governs code signing keys. ⚠ **It does not sign
code** — it holds keys and returns signatures to a signing tool.

**CodeSign Protect Secret Store** ⚠ — TPP's encrypted, server-side store for code signing private keys,
serviced by the Venafi software encryption driver. One of the two supported key locations (the other is an
HSM). **Not** SoftHSM — see *SoftHSM2*.

**Environment** — the container holding a key and certificate within a project. Either *Single* (one
key/cert) or *Per-user* (many, differentiated by template macros). ⚠ Does **not** mean "deployment tier".

**Environment Template** — the Code Signing Administrator's blueprint controlling which CA, algorithms, key
storage, subject DN fields and users are permitted in environments created from it. Can *suggest* values or
*require* them via the "Do not allow users to enter their own values in projects" checkbox. This is where
organisational policy is enforced.

**Flow** — defines the approvals required before signing may occur with a given key. Ranges from no
approvals to multiple levels. Attaches to Environment Templates or directly to Environments.

**Grant** ⚠ — the client's authenticated session with TPP: an access token (usually with a refresh token)
stored in client configuration. Not a password, not a key. Acquired with `getgrant`, checked with
`checkgrant`, revoked with `revokegrant`. Can be scoped to the current user, the local machine, or both.

**Key User** — the role that actually signs: holds a grant and requests signing operations. Our CI service
account is only this.

**Key Use Approver** — the role that approves or denies individual key uses when a Flow requires it.

**Per-user environment** — an environment holding multiple user-specific certificates or GPG keys,
differentiated by macros in the template. For git commit signing, macro signing, etc.

**Project** — "an embodiment of a general code signing need"; groups one or more environments plus users
and approvers. Requested by a user, approved by the Code Signing Administrator; the requester becomes the
Owner.

**Project Owner** — requests the project, selects the Environment Template, and maintains the project after
approval.

**Single environment** — an environment holding exactly one certificate, GPG key, or .NET strong-naming
key. What we use for container signing.

**TPP / Trust Protection Platform** — the Venafi platform hosting the TLS Protect, SSH Protect and
CodeSign Protect modules. 25.3+ documentation may refer to *Trust Protection Foundation*.

**`/vedauth`** — TPP's authentication endpoint. Grants are obtained and refreshed here.

**`/vedhsm`** — TPP's virtual HSM endpoint. Signing operations go here.

**`/vedsdk`** — TPP's general REST API endpoint (platform/certificate operations; not used by the PKCS#11
signing path).

**Venafi Configuration Console (VCC)** ⚠ — **an MMC snap-in, i.e. a Windows desktop application, not a web
page.** *"A powerful MMC snap-in console that allows you to administer the settings of the Venafi Platform
installation, as well as work with CodeSign Protect and the Venafi Event Viewer."* This is where **CA
templates** and **environment templates** live. There is no URL for it — if you are in a browser, you are
not in VCC.

**Venafi Code Signing Client** — the software installed on signing machines that links them to the
CodeSign Protect server over a TLS-encrypted REST API. Provides the connectors: CSP/KSP, PKCS#11 and GPG on
Windows; **PKCS#11 and GPG on Linux**; PKCS#11, Keychain Access and GPG on macOS.

**Venafi software encryption driver** — services signing operations for keys held in the Secret Store (as
opposed to an HSM driver).

**`LIBHSMINSTANCE`** — environment variable that "sets an instance for the configuration to use", giving
each instance an independent grant. Our mechanism for isolating concurrent CI builds.

**`pkcs11config`** — the CLI utility that configures the PKCS#11 driver and manages grants. ⚠ Commands were
renamed after 24.3: `getgrant`→`login`, `checkgrant`→`checklogin`, `revokegrant`→`logout`,
`setgrant`→`settoken`.

**`venafipkcs11.so`** — the Venafi PKCS#11 shared library. ⚠ A remote shim, not a local key store.

---

## PKCS#11 and cryptography

**HSM (Hardware Security Module)** — a tamper-resistant hardware device that generates and stores keys and
performs crypto operations. Optional in our CodeSign Protect design; not used.

**PKCS#11** — the standard C API for talking to cryptographic tokens. Because it is a standard, any
PKCS#11-aware tool works with any compliant module — which is how cosign talks to Venafi without any
Venafi-specific code.

**PKCS#11 URI (RFC 7512)** — the string identifying a key through a PKCS#11 module, e.g.
`pkcs11:token=Remote%20Token;object=container-prod?module-path=/opt/venafi/codesign/lib/venafipkcs11.so&pin-value=…`.

**`pin-source`** — RFC 7512 URI attribute pointing at a *file* containing the PIN, instead of the inline
`pin-value`. Preferred when a real PIN is required, to keep it off the command line.

**Remote Token** ⚠ — the PKCS#11 token name the Venafi module presents. Seeing this confirms signing is
serviced remotely by TPP and no key material is local. A different token name means you are using a local
token.

**Slot / Token / Object** — PKCS#11 hierarchy. A *slot* is a reader, a *token* is the device in it, an
*object* is a key or certificate on it. In the Venafi module these are all remote abstractions.

**SoftHSM2** ⚠ — an open-source software PKCS#11 token (OpenSC) that holds key material **in a file on the
client machine**. Prohibited by our standards. Frequently and incorrectly conflated with the Venafi Secret
Store, which is server-side. See `10 §4`.

---

## Sigstore / cosign

**Accessory** — Harbor's term for an artifact attached to another, such as a cosign signature.

**Attestation** — signed metadata *about* an artifact (SBOM, build provenance) as distinct from a signature
*of* it. `cosign attest` / `cosign verify-attestation`.

**ClusterImagePolicy (CIP)** — the Policy Controller CRD defining which images are verified and against
which authorities. ⚠ Multiple matching CIPs are **AND**ed; authorities within one CIP are **OR**ed — so
adding an authority *weakens* a policy.

**cosign** — the Sigstore CLI for signing and verifying container images and artifacts. ⚠ The stock
`cosign-linux-amd64` release has **no PKCS#11 support**; you need the `pivkey-pkcs11key` build.

**Fulcio** — Sigstore's CA issuing short-lived certificates from OIDC identity (keyless signing). Not used
here — we use a long-lived enterprise key from Venafi.

**Keyless signing** — signing with an ephemeral key and a Fulcio certificate tied to an OIDC identity, with
the record in Rekor. Not our model.

**OCI (Open Container Initiative)** — the standards body defining container image and registry formats. A
cosign signature is itself an OCI artifact.

**Policy Controller** — Sigstore's Kubernetes admission controller enforcing signature policy. ⚠ By default
validates only namespaces labelled `policy.sigstore.dev/include: "true"` — a real bypass unless inverted.

**Rekor** ⚠ — Sigstore's transparency log. cosign 2.x verifies Rekor entries **for key-based signatures
too**, not just keyless — which is the root of the risk in `06 §1`. We sign with `--tlog-upload=false`
because we have no public log; verification therefore needs `--insecure-ignore-tlog=true` or a private
Rekor.

**SCT (Signed Certificate Timestamp)** — proof of inclusion in a certificate transparency log, used when
verifying Fulcio certificates. Not applicable to our key-based model.

**`sha256-<digest>.sig`** — the tag scheme cosign uses to store a signature alongside the image it signs.

**Signature envelope** — the structure cosign builds around the raw signature (payload, signature,
optional certificate and chain) and pushes to the registry.

**`--insecure-ignore-tlog`** ⚠ — tells cosign not to require a transparency-log entry. **Misleading name**:
it means "not using transparency logs", *not* "not verifying the signature". Signature verification against
the key is fully enforced. Expect to explain this in audit review — see `04 §10`.

**`--tlog-upload=false`** — tells cosign not to publish to a transparency log. Correct for private images
signed with an internal enterprise key.

---

## Platform and pipeline

**AppRole** — a Vault auth method using a role ID and secret ID. Not used here; we use JWT/OIDC instead, to
avoid a long-lived secret.

**`bound_claims`** — Vault JWT role constraint restricting which token claims may authenticate. ⚠ The
load-bearing control that stops any job on a controller from reading the signing secrets.

**CloudBees CI** — the Jenkins-based CI platform. Controllers act as OIDC providers, minting per-build ID
tokens.

**Digest** — the content-addressed identifier of an image, `sha256:…`. ⚠ Always sign the digest, never the
tag — tags are mutable.

**Harbor** — the CNCF container registry. 2.5+ understands cosign signatures as accessories.

**ID token** — the short-lived JWT minted by the CloudBees OIDC provider, exchanged for a Vault token or (via
a TPP JWT Mapping) a Venafi grant. ⚠ Use **separate audiences** per consumer so a token for one service
cannot be replayed against another.

**JWT Mapping** — the TPP configuration mapping incoming JWT claims to a TPP identity, enabling
`pkcs11config getgrant --jwtfile` and removing the need for a stored Venafi password.

**podman** — the container engine used to build, tag and push. ⚠ Writes credentials to
`${XDG_RUNTIME_DIR}/containers/auth.json`, **not** where cosign looks — see `04 §6`.

**Prisma Cloud / twistcli** — the vulnerability scanner gating the pipeline. Formerly Twistlock.

**Robot account** — Harbor's non-human account type. ⚠ The build robot needs **push**, because writing a
signature is a push.

**Vault Enterprise** — HashiCorp's secrets manager. Brokers access to *services*; ⚠ holds no signing key
material, because the key never leaves TPP.

---

## Quick disambiguation

| If you hear… | It means | Not to be confused with |
|---|---|---|
| "Secret Store" | TPP's server-side key store | SoftHSM2; Vault's KV store |
| "Environment" | A Venafi key container | A deployment tier |
| "Grant" | A TPP session token | A permission, or the key |
| "Remote Token" | Proof signing is server-side | A local PKCS#11 token |
| "Authority" | A CIP verification rule | A certificate authority |
| "Accessory" | A Harbor attached artifact | An attestation |
| "insecure-ignore-tlog" | Skip transparency log | Skip signature verification |
| "Flow" | A Venafi approval workflow | A pipeline stage |
| "Configuration Console" | A Windows MMC desktop app | Any web console |
| "Certificate template" | Depends entirely on the module | TLS Protect's and CodeSign Protect's are unrelated objects |
| "Policy folder" | Depends entirely on the module | TLS and Code Signing branches are separate |

> **⚠ TLS Protect vs CodeSign Protect.** Both modules use *certificate*, *template*, *policy folder*, *CA*
> and *environment* for different objects, on different policy branches, in different consoles. Nothing in
> either UI warns you. If an error mentions **domains** or **hostnames** while you believe you are doing
> code signing, you are almost certainly on the TLS side — code-signing Common Names are not hostnames.
> See `10 §1a` and `01 §3.1`.
