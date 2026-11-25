# 01 — Check the user certificate

**Who:** you / PKI team · **Needs:** the test user's certificate as a `.cer` file (public part only)
**Gives:** proof that the certificate has everything PKIPN needs

**In short:** export the user's certificate (no private key), read it with `certutil -dump`, and check
it has a **Principal Name**, the **Client Authentication** EKU and valid dates.

Most PKIPN failures with **external** certificates come from the certificate itself. External
providers often put the **e-mail address** in the SAN and **no UPN**, and PKIPN has nothing to read.

## Step 1 — Export the certificate (no private key)

1. 🖱 On the user's workstation: `certmgr.msc` → *Personal* → *Certificates* → the login certificate.
2. 🖱 **All Tasks ► Export** → **No, do not export the private key** → **DER encoded (.CER)** → `user.cer`.
3. 🖱 Copy `user.cer` to a PVWA server.

## Step 2 — Read it

⌨ On the PVWA server:
```cmd
certutil -dump user.cer
```

Check every row:

| Look for | Must be | Why |
|---|---|---|
| **Subject Alternative Name** → `Other Name: Principal Name=` | Present, e.g. `jdoe@corp.example.com` | **This is what PKIPN reads.** `RFC822 Name=` (e-mail) is **not** a UPN |
| That Principal Name | The same as the user's **`userPrincipalName` in AD**, and the same as their **Vault user name** | PKIPN logs in the Vault user with exactly this name. For an LDAP user that works when the LDAP mapping uses `userPrincipalName` ([05](05-user-mapping.md)) |
| **Enhanced Key Usage** | Includes **Client Authentication (1.3.6.1.5.5.7.3.2)** | Required for TLS client certificates |
| **Key Usage** | Includes **Digital Signature** | Used in the TLS handshake |
| **NotBefore / NotAfter** | Valid today | Expired → `403.17` |
| **Basic Constraints** | `Subject Type=End Entity` (or absent) | A CA certificate is refused when extended validation is on |
| **Issuer** | The external CA's intermediate | Its root and intermediate go on the PVWA server ([chunk 02](02-pvwa-server-trust.md)) |
| **CRL Distribution Points** / **Authority Information Access** | URLs present; note them | The PVWA server must reach them ([chunk 02](02-pvwa-server-trust.md)) |

**Expected:** a `Principal Name` that equals the user's Vault name, Client Authentication EKU, valid
dates.

## Step 3 — The user has the private key

🖱 On the workstation: `certmgr.msc` → the certificate → **General** tab shows *"You have a private
key that corresponds to this certificate."* For a smart card, the card is inserted and its middleware
is installed.

**Expected:** private key present. Without it the browser can't offer the certificate.

## If it fails

| You see | Fix |
|---|---|
| No `Principal Name` in the SAN | Ask the external provider to reissue with a **UPN SAN** (`otherName` OID `1.3.6.1.4.1.311.20.2.3`) set to the user's AD UPN. PKIPN can't work without it. Plain PKI (Subject DN) is the alternative |
| Principal Name ≠ Vault user name | [Chunk 05](05-user-mapping.md) |
| No Client Authentication EKU | Reissue. IIS and browsers won't use it for login |
| Expired / not yet valid | Reissue, or check the server and workstation clocks |
