# 06 — Folders and policy

**Who:** Venafi team, signed in as the right admin (chunk 02)
**Needs:** `svc-vault-pki` (chunk 04), the CA template (chunk 05a, A10)
**Gives:** policy folders (A7, A8), CA turnaround time

TPP folder policy is what limits **which names** Vault can get certificates for. Vault cannot enforce
this on its own (guide 08 §9), so **Allowed Domains** in Step 3 matters.

## Step 1 — Create the folders

1. 🖱 TPP → **Policy Tree**.
2. 🖱 Select `\VED\Policy\Certificates` → **Add** ► **Policy** (folder) → name `Vault`.
3. 🖱 Under `Vault`, add `AUT`.
4. 🖱 Under `AUT`, add `Web`, `Hosts`, `K8s` (A8).

**Expected:** `\VED\Policy\Certificates\Vault\AUT\{Web,Hosts,K8s}` visible in the tree.

## Step 2 — Give the service account rights on `AUT` only

1. 🖱 Select `AUT` → **Permissions** → **Add** → search `svc-vault-pki` → select.
2. 🖱 Tick: **View**, **Read**, **Write**, **Create**, and **Revoke** (only if A5 includes revoke).
3. 🖱 Leave **unticked**: Delete, Admin, Private Key Read, Private Key Write.
4. 🖱 **Save**. The three leaf folders inherit these rights.

**Expected:**
- 🖱 `AUT` → Permissions → Effective permissions → `svc-vault-pki`: the rights above.
- 🖱 `Vault` (the parent) → Effective permissions → `svc-vault-pki`: **nothing**.

## Step 3 — Certificate tab on each leaf folder

Do this for `Web`, `Hosts` and `K8s`.

1. 🖱 Select the folder → **Settings** ► **Certificate** tab.
2. 🖱 Set every field in the table below, in order.
3. 🖱 **Lock** each value marked 🔒 (click the padlock next to it). A locked value can't be overridden
   by a request or a sub-folder. An unlocked value is only a default.
4. 🖱 **Save** / **Apply**.

| Section | Field | Set to | 🔒 | Why |
|---|---|---|---|---|
| General Information | **Contacts** | your PKI team group | | Who gets expiry and error notices |
| | **Approvers** | leave default; attach **no** approval workflow | | An approval holds each Vault request until it times out (180 s) |
| | **Management Type** | **Enrollment** | 🔒 | TPP requests the certificate; Vault installs it, not TPP |
| | **Managed by** | blank | | Not Aperture-only or User Portal-only |
| CSR Handling | **CSR Generation** | **User Provided CSR** | | Vault always sends a CSR. See note below |
| | **Generate Key/CSR on Application** | **No** | | Not used |
| | **Hash Algorithm** | **SHA-256** | 🔒 | |
| Subject DN | **Organization** | your company name | 🔒 | Same on every certificate, whatever Vault sends |
| | **Organization Unit** | e.g. `Automation` | 🔒 | |
| | **City, State/Province, Country** | your values | 🔒 | |
| Domain White List | **Allowed Domains** | per folder, see the next table | 🔒 | **The name control.** Blank = every domain allowed |
| | **Allow Wildcards** | **No** | 🔒 | No `*.domain` certificates |
| | **Allow Duplicate Common and Subject Alternate Names** | **Yes** (default) | | Renewals and re-issues reuse the same name |
| Private Key | **Reuse Private Key for Service Generated CSRs** | **No** | 🔒 | Not used |
| | **Allow Users to Import Duplicate Certificates and Reuse Private Keys** | **unticked** | 🔒 | |
| Allowed Algorithms | **Allowed Algorithms** | per folder, see the next table | 🔒 | Vault role `key_type`/`key_bits` must be in this list |
| | **Default Algorithm** | **RSA 2048** | | |
| Other Information | **CA Template** | **A10** (chunk 05a, e.g. `Vault-AUT-MSCA`) | 🔒 | Which CA signs. Without it nothing is issued |
| | **Key Generation**, **Encryption Key** | leave default | | Only for TPP-held keys |
| | **Disable Automatic Renewal** | **Yes** | 🔒 | Vault consumers and cert-manager renew; TPP must not |
| | **Allow Simple Passwords for Private Key Downloads** | **No** | | |
| | **PKCS#12 Encryption Algorithm**, **Private Key PBE algorithm** | leave default | | No key downloads |
| | **Renewal Window** | leave default (30) | | Unused when renewal is disabled |
| Validation | **Disable SSL/TLS Validation** | **Yes** | | These certs aren't on fixed hosts TPP can scan |
| | **Network Port**, **Use certificate's Common Name / DNS SANs**, **Validate the chain…** | leave default | | Ignored when validation is off |
| Active Directory Certificate Authentication | **Allow certificates with AD Security Identifier (SID)** | **No** | 🔒 | A SID would let a TLS certificate log in to AD as the requester. The other AD fields then don't apply |

**Values that differ per folder:**

| Field | `Web` | `Hosts` | `K8s` |
|---|---|---|---|
| Allowed Domains | `aut.corp.example.com` | your host domain | `k8s.aut.corp.example.com` |
| Allowed Algorithms | RSA 2048, 3072, 4096 | RSA 2048, 3072, 4096, EC P-256 | RSA 2048, 3072, 4096 |

Use the domains from A9. An entry allows that domain **and its subdomains**.

**Validity is not on this tab.** It comes from the CA template (chunk 05a): the Microsoft template's
validity, or what Vault asks for if chunk 05a Step 3 was done.

**Expected:** each leaf shows the values above, with padlocks on the 🔒 rows.

> **Why User Provided CSR, not Service Generated.** *Service Generated* means TPP creates the private
> key and keeps it. Vault never works that way. With `issue/`, the plugin creates the key on the Vault
> node. With `sign/` (cert-manager), the key stays in the cluster. Either way TPP only receives a CSR,
> and a folder set to Service Generated rejects it. It also keeps private keys out of TPP, which is
> why Step 2 gives no Private Key rights.

> **Different screen?** Some versions show this as **Configuration ► Folders** → folder → **Certificate
> Policy**, with the same settings under different names: *CSR Provided By* (= CSR Generation),
> *CSR Signature Algorithm* (= Hash Algorithm), *Key Algorithm* + *Key size* (= Allowed Algorithms),
> *Allow wildcard Common and Subject Alternative Name* (= Allow Wildcards), *Renew automatically*
> (leave empty = no automatic renewal), *SAN Types Allowed* (set **DNS** only).

## Step 4 — Negative test: a bad name is rejected

1. 🖱 In `Web` → **Add** ► **Certificate** → Common Name `evil.example.com` → **Save** / **Submit**.

**Expected:** TPP **rejects** it with a policy / domain error. Screenshot it (evidence E10).

## Step 5 — Positive test: time the CA

1. 🖱 In `Web` → **Add** ► **Certificate** → Common Name `test-<date>.aut.corp.example.com` → submit.
   Start a timer.
2. 🖱 Wait until its status is **Issued**. Stop the timer.
3. 🖱 Open the certificate → details. Check the issuer is your CA (A10), the CN is also a SAN, and note the
   **CRL distribution point** and **OCSP** URL.
4. 🖱 Revoke and delete this test certificate.

**Expected:** issued in **under 60 s**, CN present as a DNS SAN, CRL/OCSP URLs present.

## Done when

- [ ] Folders exist; `svc-vault-pki` has rights on `AUT` only
- [ ] Certificate tab set and locked on all three leaves
- [ ] `evil.example.com` rejected (screenshot)
- [ ] Test certificate issued; turnaround time sent to the Vault team (they raise `server_timeout` if it
      is over 120 s)

## If it fails

| You see | Fix |
|---|---|
| Can't add `svc-vault-pki` to Permissions | Signed in as local admin for an AD account. Use your AD admin (chunk 02) |
| CA Template list is empty | No CA template yet. Do chunk 05a |
| Can't change a field (greyed out) | Locked on a parent folder. Change it there, or ask its owner |
| `evil.example.com` was issued | Allowed Domains empty or not locked on that folder. Fix Step 3, revoke the cert |
| Test cert stuck at *pending* / CSR stage error | CA template settings. See chunk 05a *If it fails* |
| Issuance takes minutes | Raise with the CA team. Vault waits 180 s at most |

Source for the field names: Venafi TPP 25.1 docs, *Policy object certificate settings* and *Setting
policy on a folder*. Labels may differ slightly in other versions.
