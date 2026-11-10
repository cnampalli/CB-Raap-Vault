# 05a — CA template

**Who:** Microsoft CA admin (Steps 1–3), Venafi team (Steps 4–5)
**Needs:** nothing · **Gives:** A10, the CA template that chunk 06 selects on each folder

A **CA template** is the TPP object that tells TPP which CA to send a request to, which certificate
template to ask for, and which account to log in to the CA with. Every certificate TPP issues needs
one. Without it, chunk 06 can't be completed.

**Skip this chunk** if a CA template for your Microsoft CA already exists and folders that issue
certificates today use it. Write its name into A10 and check Step 5.

This chunk covers a **Microsoft CA** (ADCS). Other CAs have a different CA template type.

## Step 1 — CA admin: certificate template on the Microsoft CA

1. 🖱 On the CA, open **Certificate Templates** (`certtmpl.msc`). Right-click **Web Server** →
   **Duplicate Template**.
2. 🖱 **General** tab: name `Vault-AUT-WebServer`. Set **Validity period** to the longest validity you
   allow (e.g. 1 year).
3. 🖱 **Subject Name** tab: **Supply in the request**. Required: TPP can't use templates that build the
   subject from Active Directory.
4. 🖱 **Cryptography** tab: minimum key size **2048**.
5. 🖱 **Issuance Requirements** tab: leave **CA certificate manager approval** unticked.
   Ticking it makes every Vault request wait for a person.
6. 🖱 **OK**. Then in **Certification Authority** (`certsrv.msc`) → right-click **Certificate
   Templates** → **New** → **Certificate Template to Issue** → select `Vault-AUT-WebServer`.

**Expected:** `Vault-AUT-WebServer` is listed under the CA's Certificate Templates.

## Step 2 — CA admin: give TPP's CA account its rights

TPP logs in to the CA with a domain account (e.g. `CORP\svc-tpp-ca`). This is **not** `svc-vault-pki`.
Use an existing TPP CA account if there is one.

1. 🖱 `certsrv.msc` → right-click the CA → **Properties** → **Security** → add the account → allow
   **Read**, **Issue and Manage Certificates**, **Request Certificates**.
2. 🖱 `certtmpl.msc` → `Vault-AUT-WebServer` → **Properties** → **Security** → add the account → allow
   **Read** and **Enroll**.

**Expected:** both permission sets saved.

## Step 3 — CA admin (optional): let requesters choose validity

Only if consumers must choose their own `ttl` (chunk 01, A10). Otherwise the template's validity
from Step 1 applies to every certificate.

⌨ On the CA server:
```cmd
certutil -setreg policy\EditFlags +EDITF_ATTRIBUTEENDDATE
net stop certsvc && net start certsvc
certutil -getreg policy\EditFlags
```
**Expected:** `EDITF_ATTRIBUTEENDDATE` is listed.

> Don't set `EDITF_ATTRIBUTESUBJECTALTNAME2`. It lets any requester add any SAN and is a known ADCS
> attack path (ESC6). SANs work without it because the template supplies the subject in the request.

## Step 4 — Venafi team: create the CA template in TPP

1. 🖱 TPP → **Policy Tree** → **Tree** drop-down → **Policy**.
2. 🖱 Select the folder that will hold it (e.g. `\VED\Policy\Certificates\Vault`). You need **Create**
   permission there.
3. 🖱 **Add** ► **CA Template** ► **Microsoft**. **CA Name:** `Vault-AUT-MSCA` (this is A10).
4. 🖱 Fill in:

   | Field | Set to | Why |
   |---|---|---|
   | **Connection ► Hostname** | the CA server's DNS name | Where TPP sends requests |
   | **Service Name** | the CA's name = the **CN of the CA's certificate** (e.g. `CORP-Issuing-CA`) | Must match exactly |
   | **Credential** | **Browse** → pick or create a username credential for `CORP\svc-tpp-ca` (Step 2) | TPP's login to the CA |
   | **Options ► Template** | click **Retrieve**, pick `Vault-AUT-WebServer` | The template from Step 1 |
   | **Allow Users to Specify End Date** | tick **only** if you did Step 3 | Lets Vault's `ttl` set the expiry |
   | **Manual Approvals** | **unticked** | Ticked = a person must approve each Vault request |
   | **Subject Alt Name Enabled** | **ticked** | Without it, any request with SANs fails |
   | **Automatically include CN as DNS SAN** | **ticked** | Puts the CN in the SANs as well; browsers require it |
   | **Enrollment Agent** | empty | Not used |

5. 🖱 **Save**.

**Expected:** the CA template is saved and shows under the folder. Clicking **Retrieve** listed
`Vault-AUT-WebServer`, which proves the hostname, service name and credential work.

## Step 5 — Record it

🖱 Write into A10 (chunk 01): the CA template name (`Vault-AUT-MSCA`) and issuer type **`m`**
(Microsoft). The Vault team uses `m` for `issuer_hint`.

**Expected:** A10 filled in. The real test is chunk 06 Step 5, where a certificate is issued through it.

## Done when

- [ ] Template `Vault-AUT-WebServer` published on the CA with *Supply in the request*
- [ ] TPP's CA account has the CA and template rights
- [ ] CA template `Vault-AUT-MSCA` saved in TPP; **Retrieve** worked
- [ ] A10 filled in

## If it fails

| You see | Likely cause | Fix |
|---|---|---|
| **Retrieve** lists nothing or errors | Wrong Hostname / Service Name, or the account lacks rights | Service Name = CN of the CA cert. Recheck Step 2 |
| `Vault-AUT-WebServer` not in the Retrieve list | Template not issued on the CA, or no Read/Enroll | Step 1.6, Step 2.2 |
| Later: `SubjectAltName not supported by Application and CA` | **Subject Alt Name Enabled** unticked | Step 4 |
| Later: request stuck *pending* | Manual Approvals ticked, or CA manager approval on the template | Step 4, Step 1.5 |
| Later: subject comes from AD / request rejected | Template builds the subject from AD | Step 1.3 |
| Later: Vault's `ttl` ignored | Step 3 not done, or End Date box unticked | Step 3, Step 4 |

Source: Venafi TPP 25.1 docs, *Creating CA template objects* and *Configuring the Microsoft template
object*. Labels may differ slightly in other versions.
