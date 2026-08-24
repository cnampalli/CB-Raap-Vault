# 10 — Venafi CodeSign Protect: Concepts Primer

> **Purpose:** teach the Venafi mental model, so the runbooks in `01`–`09` read as obvious rather than as
> magic incantations. Read this **before** `01` if Venafi is new to you.
>
> **Audience:** anyone delivering or operating this solution. No prior Venafi knowledge assumed.
>
> This is a learning document, not a runbook. Nothing here is a step to execute.

---

## 1. Where CodeSign Protect sits

**Venafi Trust Protection Platform (TPP)** is a machine-identity management platform. It is one product
with several capability modules, licensed separately:

| Module | Manages |
|---|---|
| **TLS Protect** | TLS/SSL certificates — discovery, issuance, renewal, installation |
| **SSH Protect** | SSH keys |
| **CodeSign Protect** | **Code signing keys and certificates** ← this is what we use |

They share the same server, database, identity integration, permissions model and audit log. If your
organisation already runs Venafi for TLS certificates, CodeSign Protect is a module on the same platform,
not a separate product to install.

> **Naming, because you will meet all of these:** the platform is *Trust Protection Platform* / *TPP*.
> CyberArk acquired Venafi, and from 25.3 the product is rebranded **Code Sign Manager - Self-Hosted**,
> with the client renamed **Code Sign Client**. Same software. Documentation URLs still say `venafi.com`.
> On 24.1 (our version) you will see the Venafi names throughout.

---

## 1a. The three administration consoles

Before any concept, an orientation fact that costs people more time than anything else in this document.

**TPP is not one application with one UI.** It has three administration surfaces:

| Console | What it is | Reached by | Owns |
|---|---|---|---|
| **Aperture** (renamed **OneVenafi**) | Web console | Browser | *"Most activities (including non-admin activities)"* — TLS Protect, and CodeSign Protect **projects and environments** |
| **Policy Tree** (formerly **WebAdmin**) | Web console | Browser | Classic admin: configuring CAs, applications, workflows, all reporting. *"Gradually being retired"* as features move to Aperture |
| **Venafi Configuration Console (VCC)** | **An MMC snap-in — a Windows desktop application** | Installed from an MSI, opened via `mmc` | Platform settings, the Event Viewer, and **CodeSign Protect administration** |

> **VCC is not a website.** There is no URL for it. It is a Windows MMC snap-in — *"a powerful MMC snap-in
> console that allows you to administer the settings of the Venafi Platform installation, as well as work
> with CodeSign Protect and the Venafi Event Viewer."* If you are in a browser, you are not in VCC.

**Why this matters more than it sounds like it should.** CodeSign Protect administration is *split across
two consoles*:

- **CA templates** and **environment templates** → the MMC snap-in
- **Projects** and **environments** → Aperture

Neither console tells you the other exists.

### The vocabulary collision

TLS Protect and CodeSign Protect both use the words **certificate**, **template**, **policy folder**, **CA**
and **environment** — for entirely different objects, on different policy-tree branches, administered
through different consoles.

A "certificate template" in TLS Protect has nothing to do with a "certificate environment template" in
CodeSign Protect. They are not related, not interchangeable, and not visible to each other.

> **The practical consequence:** it is entirely possible to spend an afternoon configuring TLS certificate
> policy in a browser while believing you are configuring code signing — and the errors you get will look
> like code-signing errors. The tell is the error mentioning **domains** or **hostnames**: code-signing
> Common Names are not hostnames, so a domain-shaped complaint means you are on the TLS side.
> `01 §3.1` covers the diagnosis.

---

## 2. The problem it solves

Traditional code signing has a structural weakness: **the signing key is a file**. It sits on a build
server or a developer laptop, and whoever can read that file can sign anything, forever, invisibly.

The consequence is what makes it serious. If a signing key is stolen, you must revoke the certificate —
and revocation *"invalidates the digital signature of all authorized software"* previously signed with it.
One stolen file invalidates years of legitimately signed releases.

CodeSign Protect's answer is to **never let the key be a file you hold**. Per Venafi's own summary, it lets
you:

> - "Protect code signing keys, either in the Trust Protection Platform Secret Store or on an HSM"
> - "Restrict the use of keys only for specific purposes"
> - "Allow keys to be used only by specific users"
> - "Allow keys to be used only from specific IP addresses"
> - "Provide approval flows around the use of keys"
> - "Audit the use of keys over time"

Read that list as the feature set you are buying. Our design uses all six.

---

## 3. The single most important sentence

> **IMPORTANT** — The role of Venafi CodeSign Protect is to protect private code signing keys and to
> govern the use of those keys. **Venafi CodeSign Protect itself does not sign code.**

Internalise this and the whole architecture follows.

CodeSign Protect is not a signing tool. It is a **key custodian with an API**. Your existing signing tool
— cosign, signtool, jarsigner, gpg — still does the signing. What changes is *where the private key
operation happens*:

```
Traditional:   cosign ──[reads key file]──> signs locally
CodeSign Protect:  cosign ──[sends hash]──> TPP ──[signs with key it holds]──> returns signature
                                                    key never moves
```

TPP *"receives code signing requests"* and *"returns signed hash to the requesting workstation"*. That is
the entire interaction. Everything else — building the signature envelope, writing it to the registry,
understanding OCI — remains cosign's job.

**This is why the integration is a PKCS#11 driver and not a "Venafi signing plugin".** The driver
impersonates a hardware token so that any PKCS#11-aware tool works unchanged, while quietly forwarding
every cryptographic operation over HTTPS to TPP.

---

## 4. Where keys actually live

Two options, and only two:

| Option | Where the key is | Serviced by |
|---|---|---|
| **CodeSign Protect Secret Store** | Encrypted inside TPP | Venafi software encryption driver |
| **Hardware Security Module** | On the HSM | The HSM; TPP stores a *reference* to the key |

> "All code signing private keys are stored in either the CodeSign Protect Secret Store or in an attached
> HSM." An HSM is *"Optionally"* connected.

**Our environment uses the Secret Store** — no HSM. This is a supported, first-class configuration, not a
downgrade or a workaround.

### The SoftHSM confusion (worth understanding properly)

People conflate three different things:

| Thing | What it is | Key location | Our stance |
|---|---|---|---|
| **Hardware HSM** | Physical/network crypto appliance | Tamper-resistant hardware | Not used |
| **CodeSign Protect Secret Store** | TPP's encrypted server-side key store | On the TPP server, access-controlled and audited | **This is what we use** |
| **SoftHSM2** | Open-source software PKCS#11 token (OpenSC) | A **file on the client machine** | Prohibited by our standards |

The prohibition on "SoftHSM" targets the third: a software token holding key material on the machine doing
the signing — which reintroduces exactly the key-is-a-file problem. The Secret Store is the opposite: the
key is on the server, the client never receives it.

**Both a hardware HSM and the Secret Store satisfy "the key never reaches the build agent."** The HSM adds
tamper-resistant hardware and FIPS attestation for the key at rest. If your compliance regime demands
hardware key protection, you need an HSM; if it demands that build agents never hold signing keys, the
Secret Store is sufficient. Know which one you are being asked for — the two get muddled constantly.

---

## 5. The object model

This is the part that confuses newcomers most, because the words are generic.

```
Environment Template          (defined by the Code Signing Administrator)
   │  blueprint: which CA, which algorithms, which key storage,
   │  which subject fields, who may use it — and whether the
   │  project owner may override any of it
   │
   └──> Project                (requested by a user, approved by the Administrator)
          │  an embodiment of a code signing need
          │
          ├──> Environment      (the container that holds a key + certificate)
          ├──> Environment
          │
          └──> Users & Approvers
```

### Project

> "code signing projects are an embodiment of a general code signing need"

A project groups related signing needs. It can hold **multiple environments** — for example dev builds
signed with one certificate and release builds with another, in the same project.

Anyone who can log into Aperture *and has access to at least one environment template* can request a
project. Requests go to the **Code Signing Administrator** for approval; if rejected, the project returns
to draft for amendment. **The requester becomes the Owner.**

> Note the access-control implication: if you hand out environment templates broadly, you have made
> project creation broadly available. Template visibility *is* a permission.

### Environment

> "Environments are the containers for the keys and certificates associated with the project."

An environment holds **one key/certificate** (single) or **many user-specific ones** (per-user).

| Category | Holds | Typical use |
|---|---|---|
| **Single** | One certificate, GPG key, or .NET strong-naming key | Organisational keys — binaries, RPMs, **container images** |
| **Per-user** | Many user-based certificates or GPG keys, differentiated by template macros | Individual developers — git commit signing, macro signing |

Environment types include **Certificate**, **Key Pair**, **GPG**, **.NET**, and **Apple**.

> **We use a Single Certificate Environment.** Single because a container signing key belongs to the
> organisation, not a person. Certificate because it yields a code-signing certificate (not just a bare
> key pair), which keeps CA-anchored verification and the Venafi cosign KMS plugin available as future
> options.
>
> **"Environment" does not mean dev/test/prod.** It is a key container. We happen to create
> `container-dev` and `container-prod` environments, which makes the word look like it means deployment
> tier — it doesn't. You could equally have `windows-driver-signing` and `linux-rpm-signing`.

### Environment Template

> "Code Signing Environment Templates allow the Code Signing Administrator to suggest or require specific
> values to be used in CodeSign Protect Project Environments."

Templates are the **governance layer**. They control:

- Which **CA** may issue
- Which **key algorithms** are permitted
- Which **key storage** locations are available (including HSM connectors)
- **Subject DN** components — CN, O, OU, L, ST, C
- **Email / SAN** values
- **Request instance fields** — how signing requests are uniquely identified
- **Visibility** — which users or groups can see and use the template

The suggest-vs-require distinction is a checkbox:

> "A number of the tabs include a **Do not allow users to enter their own values in projects** checkbox.
> Checking this will restrict the Owner's ability to enter any value other than what is specified in the
> template."

**This is where organisational policy is actually enforced.** If you want every code-signing certificate to
carry a particular OU and use EC P-256 from one specific CA, you lock those in the template. Project owners
then cannot deviate — not by mistake, not deliberately.

> **Environment Templates are not the only thing enforcing policy.** The TPP **policy folder** the objects
> live in applies its own certificate policy *in addition* — and that policy is inherited from parent
> folders, which are usually configured for TLS Protect. Two systems enforce overlapping rules, and **where
> they disagree, creation fails** with an error that names neither system clearly.
>
> The classic example: a TLS-oriented **Domain Whitelist** on a parent folder rejects a code-signing Common
> Name because it is not a hostname. See `01 §4.4` for the diagnosis and both fixes. When something is
> rejected and the Environment Template looks correct, check the policy folder.

Templates get an automatic suffix in the UI (`- Single`, `- Per User`) so the environment type is visible
at selection time.

---

## 6. Roles and separation of duties

> "various tasks associated with signing code are spread across multiple roles, which allows separation of
> duties so that **no single person can create and manage code signing projects and sign code using the
> private keys**"

| Role | Does |
|---|---|
| **Code Signing Administrator** | Configures global code signing defaults; creates Environment Templates and Flows; **approves or denies new project requests** |
| **Project Owner** | Requests the project; selects the Environment Template; maintains the project once approved |
| **Key Use Approver** | When a Flow requires it, approves or denies each use of a private key |
| **Key User** | Actually signs — holds a grant and requests signing operations. Assigned on the **project**, in Aperture → Properties → Users & Approvers |

The separation is deliberate: an administrator defines what is *possible*, an owner defines what is
*configured*, an approver authorises *use*, and a user *signs*. No one role spans all four.

### Where the identities filling those roles come from

Roles are assigned to identities, and CodeSign Protect does not create identities — it consumes them.
TPP's identities arrive from **identity providers**: most often a read-only Active Directory or LDAP
connection, occasionally TPP's own local directory. Venafi puts the ordering plainly: *"in order to assign
users to the various roles involved in a code signing project, those users must first exist [in] Trust
Protection Platform."* Assignment is the second act, never the first.

Two properties of that model explain most of the confusion people hit when assigning a Key User. First,
an AD connection is **read-only and real time** — TPP reads users and groups from AD as it needs them, so
there is no import, no sync job, and no window during which a new account is "on its way in". Second,
directories are **closed systems**: *"users can only see other users within their own directory."* A
person signed in as a local identity cannot see AD identities, and an AD-authenticated user sees only
their own AD source. The picker is not broken; it is scoped.

That scoping is not merely cosmetic — it governs what you can *do*: *"you can only **add** users and
groups that are part of your identity provider… **local users can't add Active Directory users or
groups**, nor can Active Directory users add local users or groups."* Removal, notably, **is**
permitted across providers. So the asymmetry is: you can always take an identity out of a role, but
you can only put one in if it shares your directory. No setting reverses this. The cross-directory
option on the Local Identity node runs the other way — it *"permits external identities to see local
identities"*, which is the opposite of what someone hitting this usually needs.

The practical consequence is an ordering constraint, not a configuration one: **whoever will own the
work must be signed in from the same directory as the identities they will assign.** Get that wrong
and the project is built by an account that can never finish it.

> **Consequence worth internalising: there is no object that binds a directory account to a project.**
> The connection makes the account visible to TPP; adding it to the Key User field is the entire mapping.
> Looking for anything more elaborate is the reason this step feels missing. Procedure in `01 §2`;
> recovery from a project built by the wrong account in `01 §2.6`.

> **In our design, CI is a Key User and nothing more.** The `svc-container-signer` identity can use the key
> and read the certificate. It cannot create environments, cannot approve, cannot export the private key,
> cannot modify the project. That is `01 §7`, and this is the concept behind it.

> **⚠ Key Users are scoped to the *project*, not the environment.** *"Users & Approvers are project level
> settings, so Key Users will be given access to the keys managed by all environments in the project."*
> There is no per-environment key access. To give different people access to different keys, you need
> **different projects** — which is why `01 §1` specifies one project per trust tier.
>
> Two consequences that bite later: a Key User **may not hold any other role** in the same project — the
> rule evaluates *"members of a Key User group"*, not just directly-assigned users — and *"user roles in
> the project are checked when the key is used, not when the project is created or edited"* (because group
> membership is dynamic, so key-use time is the only reliable moment to validate). A mistake here surfaces
> as a failed build, not a configuration error. `01 §7.5`.

> **Roles may be group-only.** A global setting can require that *"all roles must be assigned to groups"*,
> in which case individual users cannot be assigned at all — the picker offers only groups. Set in VCC →
> Code Signing → Properties → Global Configuration, a third admin surface separate from the template nodes.
> `01 §3.3`.

---

## 7. Flows — approval requirements

> "Code Signing Flows in Venafi CodeSign Protect define the approvals that must be granted before a signing
> can take place using a given private key" — ensuring keys "are used only in ways that the Code Signing
> Administrator authorizes."

Flows range from **no approvals at all** to **multiple levels of approval**. They attach to Environment
Templates — *"any Environment that uses that Environment Template is subject to the restrictions set in the
Flow"* — and can also be selected directly on an Environment.

Flows can be configured around a defined approver or approver group, or around the Project Owner and Key
Use Approver roles.

> **Why our CI environment has no approval Flow.** An interactive approval requirement would hang every
> unattended build waiting for a human click. This is the correct trade-off *for an automated pipeline*,
> but you must replace the control, not simply drop it. We substitute: a restricted identity, least-
> privilege key use, IP restriction, a locked-down signing job, and audit-log alerting (`01 §7`, `01 §9`).
>
> For **human**, low-volume, high-value signing — a quarterly firmware release, say — a Flow with real
> approvers is exactly right. Use the tool where it fits.

---

## 8. Restrictions on key use

Beyond approvals, an environment can constrain *who*, *from where*, and *for what*:

- **By user** — only named identities may use the key.
- **By IP address** — *"the Owner can specify which IP addresses or IP address range are permitted (or
  allow all by not specifying any addresses)."*
- **By purpose** — restrict what the key may be used for.

> **Use the IP restriction.** Scoping the production key to the signing agent pool's addresses means a
> stolen credential is useless from anywhere else — a cheap, high-value control. `01 §7` and Gate 1 in
> `09 §4` both call for it.
>
> Note the behaviour on the *human* client path: a permitted IP causes the code signing certificate to be
> installed into the user's certificate store; signing in from a disallowed IP causes it to be removed.

---

## 9. The client side

### Connectors

The **Venafi Code Signing Clients** link signing machines to the CodeSign Protect server, communicating
*"over a TLS-encrypted REST API"*. Available connectors:

| Platform | Connectors |
|---|---|
| Windows | CSP/KSP, PKCS#11, GPG |
| **Linux** | **PKCS#11, GPG** |
| macOS | PKCS#11, Keychain Access, GPG |

CodeSign Protect supports RSA, elliptic curve, and experimental post-quantum keys.

> **This table decides our architecture.** Linux offers PKCS#11 and GPG. GPG is not a cosign signing
> backend. Therefore PKCS#11 — not a preference, an inevitability (`00 §3`).

### The two endpoints

TPP exposes two endpoints for the clients:

| Endpoint | Purpose |
|---|---|
| `/vedauth` | **Authentication** — obtaining and refreshing grants |
| `/vedhsm` | **Virtual HSM** — the signing operations themselves |

Splitting them means you can reason about, firewall, and monitor "who is logging in" separately from "what
is being signed." Both must be reachable from a signing machine (`02 §2`).

### Grants

A **grant** is the client's authenticated session with TPP — an access token, usually with a refresh token,
stored in the client's configuration. It is *not* a password and *not* the key.

The lifecycle: **acquire** (`getgrant`) → **use** (any number of signing operations) → **revoke**
(`revokegrant`). You can check status with `checkgrant`, which returns 0 for valid and 1 for
missing/expired — the docs say it exists precisely so *"automated systems, such as a builder or monitoring
system"* can preflight.

At configuration time you choose whether the grant is for the current **user**, the local **machine**, or
both.

> **Grants are the security boundary in an automated pipeline.** While a grant is live, whoever controls
> that machine can request signatures. This is why `04` acquires a grant as late as possible and revokes it
> in `post { always { } }`, and why `07 §6` alerts on grants outliving their build. Understanding this is
> understanding the residual risk in `00 §5`.

---

## 10. What actually happens when you sign

Signing one container image, step by step:

1. cosign resolves the image to a **digest** — `sha256:abc…`. This is the content-addressed identity.
2. cosign builds the payload to be signed (a small JSON document referencing that digest).
3. cosign hashes the payload.
4. cosign asks the PKCS#11 module to sign that hash with the object labelled `container-prod`.
5. The **Venafi PKCS#11 module does not have the key**. It packages the hash and sends it to `/vedhsm`.
6. TPP checks: is this identity permitted to use this key? From this IP? Does a Flow require approval?
7. TPP signs the hash with the Secret Store key and **returns the signature**. It writes an audit record.
8. cosign assembles the signature into an OCI artifact and pushes it to Harbor as `sha256-<digest>.sig`.

**Only a hash goes out; only a signature comes back.** The image never touches TPP — which is also why
signing a 2GB image is as fast as signing a 2KB one. If someone worries about build artefacts leaving the
network, this step list is the answer.

The token being named **`Remote Token`** (`02 §8`) is the visible artefact of steps 5–7.

---

## 11. Audit

TPP *"authenticates users"*, *"enforces permitted uses of private code signing keys"*, *"manages code
signing request flows"*, and logs it all. Every signing request is recorded against the requesting
identity.

This is what makes the residual risk in `00 §5` acceptable: a compromised agent with a live grant can
request signatures, **but cannot do so invisibly**. Incident response (`07 §5`) reconciles Venafi's signing
events against CloudBees builds — any signing event without a matching build *is* the incident.

> Key theft is *prevented*. Key **misuse** is *detected*. Different controls, and you need both.

---

## 12. How the concepts map to our design

| Concept | Our choice | Where |
|---|---|---|
| Module | CodeSign Protect on TPP 24.1 | `00 §6` |
| Key storage | Secret Store (no HSM) | `00 §2` |
| Project | `container-signing` | `01 §5.1` |
| Environment category | Single | `01 §1` |
| Environment type | Certificate | `01 §1` |
| Environments | `container-dev`, `container-prod` | `01 §4` |
| Key algorithm | EC P-256 | `01 §1` |
| Roles | CI is Key User only | `01 §7` |
| Flow | None on the CI environment — compensated | `01 §7`, §7 above |
| Restrictions | By user + by IP | `01 §7`, §8 above |
| Connector | PKCS#11 (Linux) | `00 §3` |
| Auth | Grant via JWT Mapping, per build | `01 §6.3`, `02 §5` |
| Signing tool | cosign | `04` |

---

## 13. Misconceptions to unlearn

| Belief | Reality |
|---|---|
| "Venafi signs our containers." | Venafi signs a **hash**. cosign builds the signature and writes it to the registry. |
| "The PKCS#11 token holds our key." | It holds nothing. It is a remote shim — hence `Remote Token`. |
| "Secret Store is just SoftHSM." | Different technology, different location, different threat model. §4. |
| "No HSM means the keys are unprotected." | Keys are encrypted server-side with access control, restrictions and audit. An HSM adds hardware protection, not the *only* protection. |
| "CodeSign Protect is a certificate authority." | It requests certificates from your CA and stores them. The CA is separate and is chosen in the Environment Template. |
| "An Environment is a deployment tier." | It is a key container. Our naming coincidence. §5. |
| "A grant is a password." | It is a token-based session with a lifecycle, revocable independently of the credential that created it. |
| "Adding an approval Flow always improves security." | For unattended CI it converts to an outage. Compensate with identity, IP, permission and audit controls instead. §7. |
| "The Venafi Configuration Console is a page in the web UI." | It is a **Windows MMC snap-in** — a desktop application with no URL. §1a. |
| "A certificate template is a certificate template." | TLS Protect and CodeSign Protect use the same words for unrelated objects in different consoles. §1a. |
| "If cosign verifies, the image is safe." | It proves *who signed it*, not that the content is good. The scan gate (`04 §1`) is what makes the signature mean something. |

---

## 14. Where to go next

- **Vocabulary:** `11-venafi-glossary.md`
- **Hands-on:** `12-hands-on-lab.md` — sign your first image in a sandbox
- **Build it:** `01-venafi-codesign-setup.md`

---

## Sources

- [Understanding CodeSign Protect](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/cco-codesigning-understaning-in-tpp.php)
- [CodeSign Protect architecture](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/c-codesigning-architecture.php)
- [Projects and Environments](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php)
- [Create Environment Templates](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-managing-environment.php)
- [Create Flows](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-managing-flows.php)
- [Setting up PKCS#11 clients](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-working-with-pkcs11.php)
- [pkcs11config reference](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/r-codesigning-pkcs11config.php)
