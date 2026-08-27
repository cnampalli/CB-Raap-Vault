# 01 — Venafi CodeSign Protect: Identity, Project, Environment & CI Key

> **⛔ Read §2 before you create anything.** Identity is a gate, not a later step. Everything you
> build in CodeSign Protect is owned by whoever you were signed in as, and **a TPP Local identity can
> never hand its work to an Active Directory account.** Build the project as the wrong user and the
> only fix is a role grant on the server (§2.6). This is the most expensive mistake in this document
> and it is invisible until the end.
>
> **Prereqs:** TPP **24.1** with CodeSign Protect enabled and licensed; the **Venafi CodeSign Protect
> Administration MMC snap-in** (a Windows desktop application, not a web console — install in §3.2)
> with **Code Signing Administrator** rights; Aperture access; a Code Signing Administrator to
> approve the project. **No HSM** — keys go to the CodeSign Protect Secret Store.
>
> **Ownership:** the **PKI / Venafi team** performs everything here. **CI engineering** is consulted
> on naming and supplies the service-account requirements. Nothing here is self-service.
>
> **Documentation baseline.** We run **24.1**, but Venafi has withdrawn all 24.1 documentation — the
> HTML and the PDF both 404, and the version switcher offers only 26.1 / 25.3 / 25.1 / 24.3. **All
> citations here reference 24.3, the oldest published version.** Behaviour is expected to be
> identical; where a screen differs, trust your instance and record the difference. Download the
> [24.3 PDF Code Signing Guide](https://docs.venafi.com/Docs/24.3PDF/Code_Signing_Guide.pdf) before
> it is retired too.
>
> **Terminology:** on 25.3+ this is *Code Sign Manager - Self-Hosted* and the client is the *Code
> Sign Client*. Commands and behaviour are unchanged. This document uses 24.x names.

---

## 0. Which tool for which task

Every task here happens in one of five places. **Nothing is done in a single console.**

| Task | Tool | Section |
|---|---|---|
| **Connect TPP to Active Directory / LDAP** (makes directory accounts visible at all) | **VCC — on the TPP server** → Connectors | **§2.2** |
| **Grant CodeSign Protect Administrator / Master Admin** | **VCC — on the TPP server** → System Roles | **§2.6** |
| Create a **directory service account** | **Active Directory / LDAP** — outside TPP entirely | §2.4 |
| Create a **TPP Local identity** | **Policy Tree** → Identity tree → Local → Users & Groups | §2.5 |
| License and enable CodeSign Protect; start platform components | **VCC** (MMC snap-in) | §3.1 |
| **Global code signing settings** (group-only roles, key storage, archive retention) | **VCC** → Code Signing → Actions → Properties → Global Configuration | **§3.3** |
| Create **CA templates** | **VCC** → Certificate Authority Templates | §4.2 |
| Create **Environment Templates** | **VCC** → Environment Templates | §4.3 |
| Create a **Project** | **Aperture** → Code Signing | §5.1 |
| Create an **Environment** in a project | **Aperture** → Code Signing → project | §5.2 |
| **Map a service account to signing keys** (Key User) | **Aperture** → project → Properties → Users & Approvers | **§6** |
| Set **IP restrictions** / time constraints | **Aperture** → environment | §7.3, §5.2 |
| Set the **Allowed Domains** certificate policy | **Aperture** → Configuration → Folders → Certificate Policy | §4.4 |
| Create a **JWT Mapping** | **Aperture** → Access Management → JWT | §6.3 |
| Obtain a grant, export the public key | **`pkcs11config`** on a signing agent | §8, `02` |

> **VCC is a Windows desktop application; Aperture and Policy Tree are web consoles.** Full
> explanation once, in §3.1. Two VCC nodes — **Connectors** and **System Roles** — additionally
> require running VCC **on the TPP server itself**, not on your workstation.

---

## 1. Design decisions to make first

| Decision | Recommendation | Why |
|---|---|---|
| Environment category | **Single environment** | Container signing keys belong to the organisation/product, not to individuals. Per-user environments exist for user certs. |
| Environment type | **Certificate Environment** | Produces a code-signing certificate + key. Required for the `sigstore-kms-venafi` plugin, which supports Certificate environments only. Enables CA-anchored verification later. |
| Private key source | **Create a new key** (Secret Store) | No HSM. TPP generates and retains the key; the software encryption driver services signing. |
| **Key storage location** | **Software** | Implements the no-HSM design (`00 §2`). Set on the Environment Template (§4.3) and locked. Vendor: *"If you do not have any connected HSMs, then the only option shown is **Software**, which is the Trust Protection Platform Secret Store."* |
| **CA template** | **Self-Signed** and **Microsoft CA** — both being proven | Self-signed carries no CA dependency and suffices because cosign verifies a public key, not a chain. Microsoft gives a real enterprise chain at the cost of an ADCS dependency. §4.2 |
| Key algorithm | **EC P-256** (preferred) or **RSA-3072** | cosign signs with ECDSA-P256-SHA256 natively; P-256 signatures are smaller and faster. RSA only if a consumer demands it. |
| **Project granularity** | **One project per trust tier** — `container-signing-dev` and `container-signing-prod` | **Not** two environments in one project. Key Users are granted at **project** level and reach *every* environment in it (§7.1), so dev and prod can only be separated by separating projects. |
| Environment granularity | **One environment per project** — `container-dev`, `container-prod` | Per-application environments multiply key-rotation and key-distribution work with no security gain. |
| **Project Owner identity** | **An AD group**, never a person and never a local account | An individual owner orphans the project when they leave; a *local* owner can never assign AD Key Users at all (§2.1). |
| Approvers | **Not required on the CI environment** | Interactive approval blocks unattended pipelines. Govern with permissions and audit instead — §7.4 |

> **Naming.** Fix the convention now; it appears in the PKCS#11 object label, the cosign key URI, the
> Vault path and the ClusterImagePolicy.
>
> | Project | Environment / object label |
> |---|---|
> | `container-signing-prod` | `container-prod` |
> | `container-signing-dev` | `container-dev` |

---

## 2. Identity foundation — do this before you create anything

### 2.1 The gate: sign in as the identity that will own the work

> **There is no step that maps an Active Directory account to a code signing project. That is why you
> cannot find one.**

TPP never links an AD account to a project. Two moves, and neither is the "mapping" people look for:

| # | Move | Where | Who |
|---|---|---|---|
| **1** | An **identity provider connection** makes AD users and groups *exist inside TPP* — estate-wide, once | **VCC, on the TPP server** → Connectors | Master Admin / platform team |
| **2** | The Project Owner picks one of those identities in the **Key User** field | **Aperture** → project → Properties → Users & Approvers | Project Owner |

Move 2 *is* the mapping — §6, and that is the whole of it. There is no import to run and no
per-project directory setting.

**The rule that governs everything else in this document:**

> *"You can only **add** users and groups that are part of your identity provider… **local users
> can't add Active Directory users or groups**, nor can Active Directory users add local users or
> groups."* Removing users and groups **is** possible across identity providers.

So a TPP Local identity — `tpp_admin`, the built-in `Admin`, any local account — **cannot add an AD
user or group to any role**: not Key User, not Approver, not Owner. It cannot even hand the project
over, because reassigning Owner is itself an *add*.

> **⚠ There is no setting that reverses this.** The cross-directory option on the Local Identity node
> (Policy Tree → Identity tree → Local Identity → Provider → Options → Permissions) runs the **other
> way**: it *"permits external identities to see local identities."* It lets AD users see local
> accounts. It does nothing for a local user trying to see AD. Reaching for it is a wasted afternoon.

**Therefore:** decide now which identity owns this work, sign in as it, and build everything from
that session. In our design that is an **AD group**. If you have already built under a local account,
go to §2.6.

### 2.2 The AD connector — verify it, do not build it

> *"In order to assign users to the various roles involved in a code signing project, those users
> must first exist [in] Trust Protection Platform. In most cases, identities and groups are added…
> by a connection to either Active Directory or an LDAP Identity Provider."*

**In an existing estate this connection already exists** — it is how everyone logs in to TPP. Your
job is to verify it, not build it. Specifically: confirm the OU holding `svc-container-signer` falls
under a configured **Search Root**.

Creating it is a platform-level task: VCC **on the TPP server**, as a **Master Admin** — not Code
Signing Administrator. Recorded here so you can review an existing connection intelligently.

**VCC → Connectors → Actions pane → Active Directory Connector**

| Wizard page | Setting | Why it matters |
|---|---|---|
| Authentication Credentials | AD account TPP binds with. *"The username must be in the **User Principal Name (UPN) format**."* | TPP's *own* read account — **not** `svc-container-signer`. Do not conflate them |
| Connection | AD host **FQDN**; Simple (unencrypted) or Secure; Concurrency | Use Secure |
| Root Selection | **Search roots** — *"you must select one or more search roots that contain the identities you want to be able to access"* | **The highest-value thing to check.** An account outside every search root is invisible, with no error anywhere |
| Options | Nested group resolution | Relevant only if the Key User group nests others. Our design says it must not (§2.4) |

Global catalogs and domain controllers are discovered by referral, so a DC change needs no connector
change.

> **The connection is read-only and real-time.** *"Trust Protection Platform reads the User and Group
> data directly from Active Directory in real time."* There is **no import job and no propagation
> delay** — *"wait for a sync"* is never the correct diagnosis.

> **Do not add a second connector to cover a missing OU.** Venafi is explicit that *"you should not
> create Active Directory connections that overlap"*, and an overlap can leave the provider unable to
> resolve the user at all. Ask for the existing connector's search roots to be **extended**.

Review without changing: **Policy Tree → Identity tree → the AD object → Provider tab** (read-only).
Change: **VCC → Connectors → the connector → Re-Run Wizard.**

### 2.3 The three ways a valid account stays invisible

All three present identically — the account is simply not in the picker — and none produce an error.

| Symptom | Cause | Fix, and who owns it |
|---|---|---|
| Picker shows **local users only**, zero AD identities | **You are signed in as a local identity** (§2.1). Nothing about the connector is wrong | Sign in as an AD account. If you cannot yet, §2.6 |
| **One** account missing, others resolve | Its OU is **outside every search root** | Platform/AD team **extends search roots on the existing connector** — never adds a second |
| Group is Key User and the account is a member, but signing is denied | **Nested group not resolved** — nested groups *"are expanded until the provider encounters a group that belongs to a different forest"*. Or the account holds a second project role | Check §7.5 first — it is the more common of the two. Then flatten to a single-member group (§2.4) |

> **Read the first two rows as a decision.** *Zero* AD identities means the session is wrong. *Some*
> AD identities but not yours means the search root is wrong. They are different problems with
> different owners, and the picker looks identical either way.

### 2.4 Create the service account and the Key User group

| # | Step | Where | Depends on |
|---|---|---|---|
| **1** | Create `svc-container-signer` | **Active Directory** — outside TPP | §2.2: the search roots must cover the OU. **Agree the OU with the platform team before the account is created** |
| **2** | Create a **single-purpose group** — `CodeSign-ContainerProd-KeyUsers` — with the service account as its **only** member | **Active Directory** | Step 1. **Required if "Role members must be in groups" is set** (§3.3), and recommended regardless |
| **3** | Confirm TPP resolves both — search for them in Aperture | **Aperture**, signed in as AD | Steps 1–2. If they do not appear, the problem is never CodeSign Protect — it is §2.3 |

> **Keep the group single-purpose and single-member.** The Key User exclusivity rule (§7.5) evaluates
> *"members of a Key User group"* — so if the service account belongs to any *other* group holding a
> project role, it still cannot sign. One group, one member, makes the evaluation trivial and the
> membership auditable.

### 2.5 AD account or TPP Local identity?

**Use the AD account.** Local identities are the documented fallback, not the default — Venafi calls
adding code signing users to the local directory *"uncommon"*.

| | **AD service account** (our path) | **TPP Local identity** |
|---|---|---|
| Password policy, rotation, joiner/leaver | Inherited from directory governance | Manual, and easy to forget |
| Auditability outside TPP | Visible to existing IAM reporting | TPP-only |
| Isolation consequence | Project Owner must also be an AD identity | Project Owner must be a local identity — **and can never assign AD Key Users** |
| Dependency added | The AD connector must exist and be correctly scoped | None |

> **One open item to settle in your instance.** With **Option B (JWT)** there is no password to
> govern, so the strongest argument for AD weakens. Whether a **JWT Mapping can resolve to a TPP
> Local identity** is **not confirmed in the 24.3 documentation and we have not tested it** — do not
> design around it either way. Until proven, §6 assumes the AD account.

### 2.6 Recovering from a project built by a local admin

If a project (and its environment and key) already exists under `tpp_admin` or another local account,
you cannot repair it from that account — every fix is an *add*. And your AD account cannot see the
project, because *"the Owner, Code Signing Administrator, and Master Admin can make changes to the
project"* and it is none of those yet.

**The escape is a system role, granted on the server:**

1. **VCC on the TPP server → System Roles → Actions → Add CodeSign Protect Administrator** → search
   for an **AD group** you belong to. Roles here *"can be assigned to a group (either a local group,
   or an LDAP group)."*
2. Log out of Aperture completely, then sign back in **as your AD account**. The project should now
   be visible.
3. Project → Properties → Users & Approvers: set **Owner** to an AD group, add the Key User group,
   and **remove the local account from every role**. You are now an AD identity adding AD identities,
   which is permitted — and removals cross providers freely.
4. **VCC → Environment Templates → the template → Visibility**: clear it, or set it to the AD owner
   group. Otherwise AD users cannot see the template and cannot create the next project (§4.3).

**The key survives.** It was generated correctly into the Secret Store and has signed nothing;
project ownership does not taint it. This is a role change, not a rebuild.

> **⚠ Whether a local admin can search AD from the VCC System Roles picker is not documented either
> way.** It is plausible that it can — VCC on the server runs in the server's Windows context against
> the platform services, rather than as an authenticated web session. **Test it first; it is the
> pivot.** If only local identities appear, this becomes a platform-team request: *CodeSign Protect
> Administrator granted to AD group `<group>`, performed from an AD-authenticated session.* Check
> whether an AD group already holds **Master Admin** — in an AD-first estate one usually does.

---

## 3. The consoles, and the settings that constrain everything

### 3.1 Which console are you in?

TPP has **three separate administration surfaces** and this document spans all three.

| Console | What it is | Owns |
|---|---|---|
| **Aperture** (renamed **OneVenafi**) | Web console | *"Most activities (including non-admin activities)"* — TLS Protect, and CodeSign Protect **projects and environments** |
| **Policy Tree** (formerly **WebAdmin**) | Web console | Configuration and administration; being *"gradually retired."* Required for CA configuration, applications, workflows, reporting |
| **Venafi Configuration Console (VCC)** | **An MMC snap-in — a Windows desktop application** | Platform settings, **CodeSign Protect** templates, and the Venafi Event Viewer |

> ### ⚠ If you are in a browser, you are not in VCC.
>
> **VCC is not a website.** It is a Windows MMC snap-in, installed from an MSI and opened from the
> Start menu or `mmc`. There is no URL for it. Every instruction below that says "VCC" means that
> desktop application. **This is the single most common way to lose an afternoon in this document** —
> everywhere else it is referenced, it points back here.

**The trap.** TLS Protect and CodeSign Protect both use the words **certificate**, **template**,
**policy folder**, **CA** and **environment** — for *different objects, on different policy branches,
in different consoles*. Nothing warns you that you are in the wrong place, so it feels entirely right
while you are in it. Two symptoms that mean you are in TLS Protect: the `does not end with a valid
domain name` error (§4.4), and an environment template CodeSign Protect never shows.

**Two VCC scopes.** The CodeSign Protect snap-in runs from **any Windows workstation** — *"without
having to be signed in to the Trust Protection Platform server."* But the **Connectors** (§2.2) and
**System Roles** (§2.6) nodes are *platform* nodes that require running VCC **on the TPP server
itself**, as a Master Admin. Same product, different scope, different owner.

### 3.2 Install the CodeSign Protect snap-in

Without this you cannot reach the Certificate Authority Templates or Environment Templates nodes.

1. Obtain **`VenafiMmc-<version>.msi`** (the *Venafi MMC Snap-In Collection*).
2. You will need the **`vedsdk`** URL, the **`vedauth`** URL, and valid TPP credentials.
3. Run the MSI, then **Windows+R → `mmc` → File → Add/Remove Snap-In**.
4. Select **Venafi CodeSign Protect Administration** → **Add** → OK.
5. **File → Save** as an `.msc`. Double-clicking it later opens MMC with the snap-in loaded.

### 3.3 Global Code Signing Configuration

> **VCC → Code Signing node → Actions Panel → Properties → Global Configuration tab.**
> **Performed by:** Code Signing Administrator.

A **third** code-signing admin surface, separate from the template nodes and absent from Aperture
entirely. These settings apply estate-wide and override what Project Owners can do.

| Setting | What it does | Matters because |
|---|---|---|
| **Role members must be in groups** | *"Disallows Owners from selecting individual users to fill roles in code signing. All roles must be assigned to groups."* | **If ticked, you cannot assign a service account directly as a Key User** — the picker offers only groups. This is expected, not a fault; §6.2 |
| **Key Users may not have other roles** | *"Restricts users assigned as Key Users **or members of a Key User group** from having any other role on the code signing project"* | Silently prevents signing — §7.5 |
| **Private Key Generation and Storage** | Which key locations Owners may choose | **Vendor confirmation of the no-HSM design** (`00 §2`). Worth capturing for the control narrative |
| **Signing Archive Options** | Retention of code signing event records — or **disable archiving entirely** | **Our audit evidence depends on this.** See the warning below |
| **Request Timeout** | Seconds before CSP timeout, *"pushed from server to clients"* | A CI signing timeout may originate here, not on the agent — `02 §4` |
| **Default Containers** | Default storage locations for CA Templates, Credentials, Certificates | Useful when hunting for where an object was created |

> **⚠ Check Signing Archive Options before you rely on the audit trail.** §9, `07 §5` and `08` test
> `V-44` all assume code signing events are retained. If archiving is disabled or retention is
> shorter than your investigation window, **the evidence pack is empty at exactly the moment you need
> it** — and nothing else compensates. Record the retention period in the control narrative.

### 3.4 The three-level chain

Creating an environment is the **last** of three steps. Two prerequisites must exist, and **neither
is created in Aperture**:

```
Level 1 — CA Template            VCC → Code Signing → Certificate Authority Templates
                                 Defines WHICH CA issues, validity period, key usage.
                                 DN: \VED\Policy\Code Signing\Certificate Authority Templates\<name>
                                        │ referenced by
                                        ▼
Level 2 — Environment Template   VCC → Code Signing → Environment Templates
                                 → Actions → "Add Single Template" → Certificate
                                        │ populates the Template dropdown in
                                        ▼
Level 3 — Project Environment    Aperture → Code Signing → <project> → add environment
                                 THIS is the screen most people start on.
```

| Symptom | Missing level | Go to |
|---|---|---|
| You are in a browser and cannot find these nodes | **Wrong console** — Levels 1–2 are in the MMC snap-in | §3.1 |
| Template dropdown greyed out or empty | Level 2 | §4.3 |
| Environment Template's CA tab offers no CA templates | Level 1, or wrong policy branch | §4.1, §4.2 |
| Both exist and the dropdown is still greyed out | Template exists but is not **visible** to your identity | §4.5 |

**Roles:** Levels 1–2 require **Code Signing Administrator** and VCC. Level 3 is the **Project
Owner** in Aperture.

---

## 4. Templates — Levels 1 and 2

### 4.1 Verify your existing CA templates first

Many estates already have code-signing CA templates. A CA template usable by CodeSign Protect must
sit under:

```
\VED\Policy\Code Signing\Certificate Authority Templates\<template name>
```

> **⚠ The TLS Protect look-alike trap.** A TLS Protect Certificate Authority object and a CodeSign
> Protect CA template expose the **same field names** — Hostname, Service Name, Credential — because
> both use the Microsoft CA connector. They are **different objects on different branches**, and a
> TLS Protect CA object can *never* be selected by a Code Signing Environment Template.

If your existing templates pass the DN test, skip to §4.3 — Level 1 is done.

### 4.2 Level 1 — Create the CA template

**VCC → Certificate Authority Templates → Create → \<connector\>**

Name the template first; **that name is what appears in Aperture**. Connectors include Self-Signed,
Microsoft CA, Microsoft CA Pool, Entrust, Out-of-band and Adaptable CA. We use two.

#### 4.2a Self-Signed CA Connector

Venafi issues the certificate itself — **no external CA dependency**. Recommended for proving the
chain and for getting container signing working while an enterprise CA is unavailable.

| Tab | Setting |
|---|---|
| *(name)* | e.g. `Self-Signed Code Signing CA` |
| **Settings** | Description; Contact; **Validity Period** |
| **Key Usage** | Tick **Digital Signature** and **Code Signing** — and nothing else |

The Key Usage tab offers fourteen options. Venafi: *"Standard code signing certificates have Digital
Signature and Code Signing checked."* For cosign those two suffice; do not tick extras speculatively.

**Is self-signed good enough?** Yes. cosign verifies against the **public key**, not a chain (`12`
Exercise 10), and Policy Controller is configured with the public key (`06 §4`). Revisit only if you
later need CA-anchored verification.

#### 4.2b Microsoft CA Connector

Issues from an existing ADCS CA — a real enterprise chain, at the cost of an ADCS dependency.

| Field | Detail |
|---|---|
| **Hostname** | IP or DNS name of the Microsoft CA server |
| **Service Name** | *"Will match the Common Name (CN) of the CA's certificate"* — **not** the server hostname |
| **Credential** | Account with **Read, Issue, Manage Certificates and Request Certificates**. Enterprise CAs also require **Read and Enroll** on the templates |
| **Template** | The ADCS template to associate. Click **Retrieve** to populate |
| **Manual Approvals** | **Leave unticked for CI** — it will hang unattended builds |
| **SAN Enabled** / Include CN in SAN | Not needed for code signing |

**ADCS-side prerequisites:** the CA reachable and operational, the credential holding the permissions
above, and the template configured to **accept the subject name supplied in the request**.

> **⚠ The difference that will bite you.** The Microsoft connector has **no Key Usage tab**. Key usage
> and EKU come from the **ADCS-side certificate template**. If that template lacks the Code Signing
> EKU (`1.3.6.1.5.5.7.3.3`), **no Venafi setting can add it** — issuance either fails or produces a
> certificate that cannot sign code. This is the most likely silent failure on the Microsoft path,
> and it is diagnosed on the Windows CA, not in TPP.

### 4.3 Level 2 — Create the Environment Template

**This is the layer that populates the greyed-out dropdown.**

**VCC → Environment Templates → Actions → "Add Single Template" → Certificate**

("Add Single Template" also offers Apple, .NET, GPG and Key Pair. Choose **Certificate** — §1.)

> **⚠ Record the exact type you pick and check it against Aperture first.** *"The environment type you
> choose will only allow environment templates of the same type."* VCC offers *Certificate*;
> Aperture's Type dropdown may read *"certificate and key"*. **If the types do not correspond, the
> template is invisible in Aperture with no error at all** — identical to never having created it.
> Open Aperture's Add Environment dialog, note what its Type dropdown offers, and create the
> corresponding type.

Name it — **this name is what Project Owners see**. Suggested: `Container Signing – Certificate`.

| Tab | Setting for container signing |
|---|---|
| **Certificate Authority** | Add the §4.2 template. Use the Search box, click **Add**, then **Apply** — two separate actions. Add both self-signed and Microsoft if proving both |
| **Keys** | Offer **EC P-256** (§1). Untick **Use System Defaults** if the defaults exclude it |
| **Key Storage** | **Software** — implements the no-HSM Secret Store design (`00 §2`). Do **not** select HSM |
| Subject DN fields | Set the organisational values you want enforced. **If the Common Name is rejected, see §4.4** |
| **Visibility** | Which users/groups may use this template. *"Leaving this field empty makes this template available to all users."* **Leave empty, or name the AD Project Owner group** |
| Settings / E-mail / Request Instance Fields | Description identifying this as the container image signing template; the rest not required |

> **Visibility has two sharp edges.** *"If an end-user does not have visibility to any Environment
> Templates, they will not be able to create new projects"* — populating it wrongly locks people out
> of project creation entirely. And it obeys the identity-provider rule (§2.1): a local admin cannot
> *add* AD identities here either, only clear the field. Clearing is a removal, which is permitted.

**Locking values.** Several tabs carry **"Do not allow users to enter their own values in projects"**.
Tick it for **Key Storage** and **Keys** at minimum — that makes "software-stored in the Secret Store,
EC P-256" a template-enforced guarantee rather than a convention (`10 §5`).

**Verifying via the API.** The object is `CertificateSignEnvironmentTemplate`:

| Field | Expected |
|---|---|
| `CertificateAuthorityDN` | `Items` array containing your §4.2 CA template path |
| `KeyStorageLocation` | `Software` |
| `VisibleTo` | Empty, or containing the Project Owner identity |

### 4.4 If the Common Name is rejected (Domain Whitelist)

```
Common Name - code-sign-certificate does not end with a valid domain name for this folder.
Valid domains have been configured in the Domain Whitelist
```

**This usually means you are in TLS Protect, not CodeSign Protect.** Domain whitelisting is a TLS
control over *"which domain suffixes can be used in new certificate requests"* — it exists to stop
someone issuing a TLS certificate for `google.com`. If you are in a browser you are not in VCC
(§3.1); if the object is not under `\VED\Policy\Code Signing\` it is not a CodeSign Protect object.
Wrong console? Stop here and start again — the fixes below are unnecessary.

**If you are genuinely in CodeSign Protect**, a TLS policy has been inherited onto the Code Signing
branch, where a CN is an organisational identifier rather than a hostname. Two fixes:

- **Fix A (correct) — clear the whitelist.** Aperture → **Configuration → Folders** → the folder
  named in the error → **Certificate Policy → Advanced Settings → Allowed Domains** → leave blank.
  The field is labelled **"Allowed Domains"**, not "Domain Whitelist"; searching for the latter
  wastes time. Blank permits all domains. If it will not accept an edit, the policy is **locked at a
  higher level** — raise it with the parent folder's owner as *a TLS control being enforced on the
  code-signing branch, where Common Names are not hostnames.*
- **Fix B (immediate) — use a domain-shaped CN.** `CN=container-signing.corp.example.com`. Not a
  compromise: cosign verifies the **public key**, never the subject (`12` Exercise 10).

> **While you are in there:** if Allowed Domains was inherited onto this branch, other TLS policy
> probably was too — key algorithms, permitted CAs, subject DN requirements, approval workflows. Each
> surfaces as an equally opaque error at a less convenient moment. Review the whole Certificate Policy
> on that folder once, now. **Policy-folder settings apply *in addition to* Environment Template
> constraints**, and where they disagree, creation fails.

### 4.5 "I created the Environment Template but it does not appear in Aperture"

Work through in this order — cheap tests first, so you do not rebuild a template that was fine.

| # | Check | Why it is here |
|---|---|---|
| **0** | **Right console?** If you were in a browser, you were in Aperture or Policy Tree, and what you created is not a CodeSign Protect Environment Template | **The most common cause by far** — §3.1 |
| 1 | **Clear the Visibility tab entirely** and retry | Seconds to test. If it now appears, the cause was visibility — then name the Project Owner group rather than leaving it open |
| 2 | **Compare the template type against Aperture's Type dropdown** | VCC *Certificate* vs Aperture *certificate and key*. **A mismatch shows no error; the template is simply absent** |
| 3 | **Re-open the template; confirm every tab persisted** | Especially **Certificate Authority**, which needs **Add** *then* **Apply**. If you hit §4.4 during creation, it may have saved partially |
| 4 | **Log out of Aperture and back in** | VCC changes do not reliably surface in an existing session |

> Steps 3 and 4 are checks to perform, not documented behaviour — Venafi does not state whether an
> incomplete template can be saved. Both are cheap and both have resolved this in practice.

Everything else is in `07 §4`.

---

## 5. Projects and environments — Level 3

> **Console: Aperture.** **⛔ Signed in as the AD identity that will own the project** — §2.1.
> **Depends on:** §4.2 and §4.3 complete, or you cannot add an environment.

### 5.1 Create the projects

**Create two projects, not one** — `container-signing-prod` and `container-signing-dev`. Key Users are
project-scoped (§7.1), so this is the only way to keep production signing CI-only.

In **Aperture → Code Signing**, for each:

1. **Create Project** → name `container-signing-prod`.
2. Add a description stating purpose and owning team — this is audit evidence.
3. Submit. The request goes to the **Code Signing Administrator** for approval; if rejected it
   returns to draft for amendment.
4. **The requester becomes the Owner.** Set the owner to an **AD group**, not an individual and never
   a local account (§1, §2.1).

> Anyone who can log in to Aperture with access to at least one environment template can request a
> project. Restrict environment templates accordingly, or project creation becomes uncontrolled.

### 5.2 Create the environment and generate the key

Within the approved project, add an environment. Two tabs:

**Base tab**

| Field | Value | Notes |
|---|---|---|
| **Name** | `container-prod` | Becomes the PKCS#11 `object=` value in the cosign key URI (`02 §8`). Fix this now — it appears in the key URI, the Vault path and the ClusterImagePolicy |
| **Type** | Certificate | `Code Signing Certificate Environment` |
| **Template** | `Container Signing – Certificate` | **From §4.3.** Greyed out until that exists |
| **Time constraint** | *leave unset* | A build at 02:00 must still sign |
| **IP restrictions** | Signing agent pool addresses | §7.3. **Specifying none permits all** |

**Key properties tab**

| Field | Value |
|---|---|
| Key algorithm | **EC P-256** (§1) |
| Key storage | **Software** — Secret Store, no HSM |
| Certificate subject | Identify the *system*, not a person. If Allowed Domains is set (§4.4) use `CN=container-signing.corp.example.com`; if clear, `CN=Container Image Signing (Production), OU=Platform Engineering, O=<Org>` is preferable |
| CA template | The §4.2 template, if the Environment Template offers a choice |

The private key is generated into the Secret Store and serviced by the software encryption driver —
no HSM reference is created. This is the *"Create New Key with Trust Protection Platform Management"*
key source (`10 §7.1`). Repeat for `container-dev`.

> **The CN is not what cosign verifies.** Signature validity depends on the public key alone (`12`
> Exercise 10). Do not let a CN debate hold up the build.

> **Key ceremony evidence.** Capture the approval record, the CA and Environment Template
> configuration, the environment configuration and the certificate details at creation time, and file
> them with the control narrative. Retrofitting this for an audit is painful.

---

## 6. Map the service account to the keys

> ### The answer in one line
>
> **Aperture → Code Signing → the project → Properties → Users & Approvers → Key User field → add the
> group.**
>
> *"Anyone that needs to sign code using an environment must be listed as a **Key User** on the
> project (or be a member of a group given Key User authority)."*
>
> It is a **project** action in **Aperture** — not an environment action, and not done in VCC. And it
> must be performed **from an AD-authenticated session** (§2.1).

### 6.1 Step-by-step

| # | Step | Console | Performed by | Depends on |
|---|---|---|---|---|
| **1** | Service account + single-purpose group exist and resolve in TPP | AD; verified in **Aperture** | Directory team | **§2.4** |
| **2** | **Add the group as Key User** → Properties → Users & Approvers | **Aperture** → `container-signing-prod` | Project Owner (AD identity) | §5.1. **This is the step that grants key access** |
| **3** | Verify it holds **no other role** in that project, directly or via group membership | **Aperture** → same page | Project Owner | Step 2 — see §7.5, this fails silently at signing time |
| **4** | *(Option B only)* Create the **JWT Mapping** | **Aperture** → Access Management → JWT | TPP admin | CI controller OIDC endpoints reachable from TPP |
| **5** | *(Option A only)* Store the credentials in Vault | **Vault CLI / self-service PR** | Vault team | `03 §2` |
| **6** | Prove it end to end: obtain a grant and list objects | **`pkcs11config`** on a signing agent | Platform engineering | `02 §5`. **Do this before writing any pipeline** |

> **Step 2 is the one people miss.** Creating the identity, or granting it TPP object permissions,
> does **not** give it the ability to sign. Only Key User membership on the project does.

> **⚠ At step 2 you will not be offered the service account itself — and should not look for it.**
> With "Role members must be in groups" enabled (§3.3), the picker returns **groups only**. Adding
> `CodeSign-ContainerProd-KeyUsers` *is* the step; there is no second action that attaches the
> individual account. See §6.2 before concluding anything is broken.

### 6.2 Why a group, not the service account directly

**First, work out which of two things you are looking at.** They present almost identically — the
account you want is not in the picker — but they have different causes and different owners:

| What the picker returns | Cause | Action |
|---|---|---|
| Groups, but **no individual at all** — not the service account, not your own account, not anyone | *"Role members must be in groups"* is enabled (§3.3) | **Expected behaviour.** Assign the group and move on. Do not disable the setting |
| **Some** individuals resolve, but not `svc-container-signer` | Its OU falls outside every configured **search root** on the AD connector | Platform/AD team extends the search roots on the **existing** connector — §2.2 |
| **No AD identities at all**, only local ones | You are signed in as a local identity | §2.1 — and if the project is invisible too, §2.6 |

Search for a colleague's name to tell the first two apart. It takes seconds and it decides whether
this is your problem or the AD team's.

**If the setting is the cause, assign a group rather than unchecking it.** That is what the control
exists to enforce, it survives service-account rotation without touching the project, and it matches
Venafi's rationale — the option *"eliminates having to maintain and update projects directly due to
employee turnover."* Disabling a global control to accommodate one account weakens it estate-wide.

> **When the Key User is a group, §7.5 gets sharper.** The exclusivity rule evaluates *"members of a
> Key User group"*, not only directly-assigned users — so the single-purpose, single-member group
> from §2.4 stops being a tidiness preference and becomes the thing that makes the rule evaluable.
> A service account sitting in any *other* group that holds a project role still cannot sign.

### 6.3 Two authentication options — pick B if you can

**Option A — service account with password (baseline).** Credentials stored in Vault and delivered
per build (`03`). Simple, works everywhere, but a long-lived shared secret exists.

**Option B — JWT Mapping (recommended, no stored password).** `pkcs11config getgrant` accepts
**`--jwtfile:<jwt>`**, which *"replaces username and password"*. This lets the **CloudBees CI OIDC ID
token authenticate directly to Venafi** — the same mechanism already used for Vault in
`../vault-integrations/02-cloudbees-ci-oidc.md`. No Venafi password is stored anywhere.

**Aperture → Access Management → JWT**, performed by a TPP admin:

1. Create a **JWT Mapping** with:
   - **Issuer URI:** `https://<ci-controller>/oidc`
   - **JWKS URI:** `https://<ci-controller>/oidc/jwks`
   - **Audience:** a Venafi-specific value, e.g. `venafi-codesign` — **do not reuse the `vault-AUT`
     audience.** A token minted for Vault must not be replayable against Venafi.
   - **Subject/claim mapping:** map to the `svc-container-signer` identity, constrained on the `job`
     claim so only the intended pipeline maps successfully.
2. **The JWT Mapping does not grant key access.** The mapped identity must still be a Key User —
   step 2 above. The mapping only decides *who the token authenticates as*.
3. **Firewall:** TPP must reach each CI controller's `/oidc/**` endpoint to fetch JWKS.

> **Strongly prefer Option B.** It removes the only long-lived credential in the design and makes the
> signing identity per-build and independently revocable. If Option A ships first for schedule
> reasons, record Option B as a tracked follow-up in `07`.

---

## 7. Least privilege, and the traps that fail at signing time

> **Console: Aperture** → project → **Properties → Users & Approvers**. **Performed by:** Project
> Owner. **Depends on:** §6.

### 7.1 Key Users are project-scoped, not environment-scoped

> *"Users & Approvers are **project level settings**, so Key Users will be given access to the keys
> managed by **all environments in the project**."*

There is **no way to grant a Key User access to one environment but not another within the same
project.** This is why §1 specifies **two projects**:

| Project | Environment | Key Users |
|---|---|---|
| `container-signing-prod` | `container-prod` | **`svc-container-signer` only** — no humans |
| `container-signing-dev` | `container-dev` | Developers who need to sign locally |

That separation is the control that makes *"only CI can produce a production signature"* true.
Collapse the two projects into one and the control is gone — silently, with no error.

### 7.2 The permission model

| Grant | Where | Mechanism |
|---|---|---|
| Use key / sign | Aperture → project → Users & Approvers → **Key User** | Project role |
| Read certificate / public key | Same — comes with Key User | Project role |
| Approve signing requests | Same → **Approver** field | Project role — **do not give this to the CI account** (§7.5) |
| Create / delete environments, modify the project | Project **Owner**, or CodeSign Protect Administrator | Project role / TPP system role |
| Export private key | **Not possible for anyone** | No such capability exists (`10 §4`) |

For the CI service account: **Key User on the production project, and nothing else.**

### 7.3 Restrict key use by IP address

CodeSign Protect can *"allow keys to be used only from specific IP addresses"*. **Specifying none
permits all**, which is the default and is not what we want. Scope `container-prod` to the
`container-signer` agent pool addresses only (`02 §1`).

> **High-value, low-cost.** Combined with the per-build identity, a leaked credential is useless from
> anywhere except a small set of hardened, monitored hosts. It also makes the "signing from an
> unexpected source host" alert in §9 a backstop for a control already enforced server-side.

Record the permitted ranges in the agent pool's change record, and add a step to the agent
build/decommission procedure. **A pool expansion that forgets this will fail signing on the new
agents** — easy to prevent, annoying to diagnose.

### 7.4 Flows — and why we do not use one here

A **Flow** *"defines the approvals that must be granted before a signing can take place using a given
private key"*. We deliberately configure **no approval Flow** on the CI environment, because an
interactive approval hangs unattended builds. That removes a control, so it must be replaced:

| Control removed | Compensating control |
|---|---|
| Human approval per signing | Restricted service identity (§6) |
| | Least-privilege key use (§7.2) |
| | IP restriction to the agent pool (§7.3) |
| | Restricted `Job/Configure` on the signing job (`04 §2`) |
| | Scan gate precedes signing (`04 §1`) |
| | Audit-log alerting on volume and source anomalies (§9) |

> Flows remain the right tool for **human, low-volume, high-value** signing — a quarterly firmware
> release, a driver, an installer. If those arrive, create a separate project with a real approver
> Flow rather than reusing the CI environment. Concept detail in `10 §7`.

### 7.5 Two traps that fail at signing time, not at setup

**Trap 1 — Key Users may not hold another role.** A global option (§3.3) *"restricts users assigned as
Key Users **or members of a Key User group** from having any other role on the code signing project."*
Note the wording: it evaluates **members of a Key User group**, not only directly-assigned users. So a
service account that is also the project Owner — or sits in *any other* group holding a project
role — **cannot sign**, even though it appears correctly listed as a Key User. This is why §2.4
specifies a single-purpose, single-member group.

**Trap 2 — roles are evaluated late.** *"User roles in the project are checked **when the key is
used**, not when the project is created or edited."* Nothing validates this at setup; it surfaces as a
permissions failure in a build log.

> **Debugging rule:** if signing fails with a permissions error but the configuration looks correct,
> check whether the service account holds a second role — **including one inherited from a group** —
> before checking anything else. Most common cause, least visible. Test it deliberately in `08` phase
> B, not for the first time in a real pipeline.

---

## 8. Export the public key for verification

Downstream verification (Harbor operators, Policy Controller in `06`) needs the **public key**. Once
the environment exists and a grant is available:

```bash
# List available objects to confirm the label
pkcs11config list

# Export the public key in PEM
pkcs11config getpublickey \
    --label:container-prod \
    --filename:/tmp/container-prod.pub \
    --format:PEM \
    --force
```

To export the certificate and its chain instead (for CA-anchored verification):

```bash
pkcs11config getcertificate \
    --label:container-prod \
    --file:/tmp/container-prod.pem \
    --chainfile:/tmp/container-prod-chain.pem
```

> If `--chainfile` and `--file` name the same file, the certificate is written first followed by the
> chain, and PEM is used regardless of `--format`.

Publish `container-prod.pub` where the Kubernetes platform team can consume it. **It is a public key —
it is not a secret**, but its *integrity* is critical: if an attacker substitutes it, they can make
their own signatures verify. Store it in version control with signed commits and mandatory review.

---

## 9. Audit logging

CodeSign Protect logs every signing request against the requesting identity. Confirm before go-live:

- **Signing Archive retention is configured and long enough** (§3.3). It can be shortened or disabled
  entirely. `07 §5` incident response and `08` test `V-44` depend on these records existing.
  **Verify this first** — the rest of this section is meaningless without it.
- Signing events for `container-prod` appear with the `svc-container-signer` identity.
- Events are forwarded to the SIEM (consistent with `../vault-integrations/01-vault-foundation-AUT.md §2`).
- An alert exists for **signing volume anomalies** on `container-prod` — the primary detection for
  grant abuse during a live window (`00 §5`).
- An alert exists for **any grant issued to `container-prod` from an unexpected source host**.

Correlate Venafi audit events to CloudBees builds using the build number; `04 §9` covers emitting the
correlation record.

---

## 10. Acceptance checklist

Before proceeding to `02`:

**Identity — verify these first; everything else depends on them**

- [ ] **AD connector confirmed to exist**, and its **search roots cover the OU** holding both
      `svc-container-signer` and the Key User group (§2.2) — verified by the platform team, not assumed
- [ ] **Every identity assignment was performed from an AD-authenticated session** (§2.1) — not
      `tpp_admin`, not the built-in `Admin`, not any local identity
- [ ] **Project Owner is an AD group**, in the same directory as the service account (§1, §2.1)
- [ ] **No local identity holds any role** on `container-signing-prod` (§2.6)
- [ ] Single-purpose group (e.g. `CodeSign-ContainerProd-KeyUsers`) created with `svc-container-signer`
      as its **only** member (§2.4)
- [ ] Nested group resolution confirmed **if** the Key User group nests any other group — our design
      says it must not (§2.4)

**Templates and environments**

- [ ] **CA template** DN is under `\VED\Policy\Code Signing\Certificate Authority Templates\` (§4.1)
- [ ] For the Microsoft connector: the **ADCS-side template carries the Code Signing EKU** (§4.2b)
- [ ] **Environment Template** created, CA template attached, **Key Storage = Software**, value locked (§4.3)
- [ ] Environment Template **Visibility** is empty, or names an identity the AD Project Owner holds (§4.3)
- [ ] **Two projects** approved — `container-signing-prod` and `container-signing-dev`
- [ ] Environments `container-prod` and `container-dev` created **in their respective projects**, keys
      generated into the Secret Store; key algorithm confirmed (EC P-256 unless justified)

**Access and operations**

- [ ] **The group is a Key User on `container-signing-prod`** (§6.1) — creating the identity alone
      grants nothing
- [ ] **"Role members must be in groups" state recorded** (§3.3). If enabled, Key Users are groups by
      construction — expected, not a fault — and the single-member rule in §2.4 becomes load-bearing
- [ ] **`svc-container-signer` holds no other role** in that project, directly or via any other group (§7.5)
- [ ] `svc-container-signer` identity exists; JWT Mapping configured (Option B) or password vaulted (Option A)
- [ ] **No human identities are Key Users on `container-signing-prod`**
- [ ] **IP restriction** on `container-prod` scoped to the signing agent pool (§7.3)
- [ ] Compensating controls for the absent Flow recorded in the control narrative (§7.4)
- [ ] **Signing Archive retention** confirmed and recorded (§3.3, §9) — the audit evidence depends on it
- [ ] Public key exported, published, integrity-protected
- [ ] Audit events confirmed reaching the SIEM, alerts configured
- [ ] TPP `/vedauth` and `/vedhsm` reachable from the signing agents (firewall request raised — `02 §2`)

---

## Sources

> All links are **24.3** — see the documentation-baseline note at the top.

**Identity (§2)**

- [Connect to Active Directory or LDAP Identity Provider (CodeSign Protect)](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-managing-activedirectory.php) — the platform-level note and the *"must first exist"* dependency
- [Working with Active Directory](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/c-identities-ActiveDirectory-overview.php) — read-only and real-time behaviour
- [Creating an Active Directory connection](https://docs.venafi.com/Docs/24.3/TopNav/Content/Directory/t-directory-creatingActiveDirectoryConnection.php) — the wizard, the UPN-format requirement
- [Additional configuration options for the AD connection](https://docs.venafi.com/Docs/24.3/TopNav/Content/Directory/r-AD-additionalConfigOptions-tpp.php) — **search roots**, nested group resolution
- [Managing local identities directly in Trust Protection Platform](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/c-identities-internal-overview.php) — **directory isolation**, the non-overlap rule
- [Allowing AD and LDAP users to see teams and local users](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/t-identities-allow-external-see-local_webadmin.php) — the **AD→local** direction only; see the §2.1 warning
- [Viewing external identities and assigning the Master Admin role](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/t-Identity-LDAP-externalIdentities-viewing2.php) — *"You must log in as an AD user in the current directory to view other users or groups in that AD directory"*
- [Understanding system roles](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/c-identities-Roles-about.php) — which roles exist and which console grants each
- [Managing system role assignments in VCC](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/t-identities-Roles-manageCollectively-Aperture.php) — **§2.6**, the System Roles node
- [Creating local user identities](https://docs.venafi.com/Docs/24.3/TopNav/Content/Identity/t-identities-creatingLocalUserIdentities.php) — §2.5

**Projects, templates and environments (§3–§7)**

- [Understanding CodeSign Protect Projects and Environments](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php) — project roles, Owner, Key User
- [Editing existing CodeSign Protect Projects](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-edit-projects.php) — **§2.6**, who may change an approved project
- [CodeSign Protect architecture](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/c-codesigning-architecture.php)
- [Create Environment Templates](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-managing-environment.php) — §4.3, Visibility and the identity-provider constraint
- [Create a self-signed CA template](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-create-self-signed.php) — §4.2a
- [Create a Microsoft CA template](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-create-msca.php) — §4.2b
- [Global Code Signing Configuration tab](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-global-configuration.php) — §3.3
- [Enabling CodeSign Protect](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-enableUpgrade.php) — §3.1
- [Create Flows](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-managing-flows.php) — §7.4
- [About Domain Whitelisting](https://docs.venafi.com/Docs/24.3/TopNav/Content/Certificates/c-cert-domain_whitelisting.php) — §4.4
- [Setting policy on a folder](https://docs.venafi.com/Docs/24.3/TopNav/Content/Policies/r-certificate-policy-configuring-Aperture-tpp.php) — §4.4, the **Allowed Domains** field
- [Certificate environment template (Code Sign Admin REST)](https://docs.venafi.com/Docs/currentSDK/TopNav/Content/SDK/CodeSignSDK/r-SDKc-Codesign-TemplateCertificateSign.php) — API fields, §4.3
- [Certificate Environment (Code Sign Admin REST)](https://docs.venafi.com/Docs/25.3/TopNav/Content/SDK/CodeSignSDK/r-SDKc-Codesign-EnvironmentCertificate.php) — API fields, §5.2
- [pkcs11config utility reference](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/r-codesigning-pkcs11config.php)
- [24.3 PDF Code Signing Guide](https://docs.venafi.com/Docs/24.3PDF/Code_Signing_Guide.pdf) — offline reference
