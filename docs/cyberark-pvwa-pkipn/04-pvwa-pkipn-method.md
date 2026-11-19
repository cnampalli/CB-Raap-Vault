# 04 — Enable PKIPN in PVWA

**Who:** CyberArk admin (Windows admin for the file steps, on **every** PVWA server)
**Needs:** the 14.6 doc page open:
[PKI authentication (Personal Certificate) for the PVWA](https://docs.cyberark.com/pam-self-hosted/14.6/en/content/pas%20inst/pki-authentication-personal-certificate.htm)
**Gives:** a **PKIPN** login option on the PVWA sign-in page

**In short:** copy the PKIPN DLL into place, add its lines to `PasswordVault\web.config`, create the
`pkipn` authentication method in PVWA, and (recommended) restrict it to the external CA.

> CyberArk's docs couldn't be read automatically when this was written, so lines marked **📋 copy
> from the 14.6 page** must be taken word for word from that page. Don't type them from memory.
> Older versions use different DLL names and folders.

## Step 1 — Back up

🖱 Copy `…\wwwroot\PasswordVault\web.config` (default
`C:\inetpub\wwwroot\PasswordVault\web.config`) to `web.config.bak-<date>`.

Edit **`PasswordVault\web.config`**, the application's own file that IIS loads. Some installs also
have copies under `Bin` or `Env`; IIS doesn't read those. The diagnostic script ([chunk 08](08-check-existing-setup.md) Step 0) lists
which exist and their PKI lines.

## Step 2 — Put the PKIPN module in place (each PVWA server)

1. 🖱 In `C:\inetpub\wwwroot\PasswordVault`, create the folder **`CustomAuthenticationDlls`**.
2. 🖱 Copy **`CyberArk.Authentication.CustomPKIPN.dll`** from `PasswordVault\Bin` into
   `PasswordVault\CustomAuthenticationDlls`.
   📋 Check the DLL name against the 14.6 page. Some versions ship `CyberArk.Authentication.PKIPN.dll`
   in the installation package instead.
3. 🖱 Add the PKIPN entry to `PasswordVault\web.config`. 📋 **Copy from the 14.6 page.**
4. ⌨ `iisreset`

**Expected:** the DLL is in `CustomAuthenticationDlls`, and the PVWA still loads after `iisreset`.

## Step 3 — Create the authentication method (once, in PVWA)

1. 🖱 PVWA → **Administration** ► **Options** → **Authentication Methods**.
2. 🖱 Right-click **Authentication Methods** → **Add Authentication Method**.
3. 🖱 Set:

   | Property | Value |
   |---|---|
   | Name / ID | **`pkipn`** |
   | Display Name | e.g. `Certificate (smart card)` (shown on the sign-in page) |
   | Enabled | **Yes** |
   | Other properties | Leave default, or 📋 as the 14.6 page lists |

4. 🖱 **Apply** → **OK**.

**Expected:** `pkipn` listed under Authentication Methods. The PVWA sign-in page shows the new option
after a refresh.

## Step 4 — Extended certificate checks (recommended)

🖱 **Administration** ► **Options** → **General** → **ValidatePKICertificate** = **Yes** → **Apply**.

This is off by default. With it on, PVWA also refuses certificates that are self-signed, are CA
certificates, or lack a suitable key usage / EKU. [Chunk 01](01-user-certificate.md) already checked these.

## Step 5 — Restrict which CA may issue login certificates (optional, recommended)

Without this, **any** CA that the PVWA server trusts can issue a certificate that logs someone in,
including the internal CA and every public root in Windows. Limit it to the external CA:

- 🖱 In `PasswordVault\web.config` → `<appSettings>` → add the issuer value from the 14.6 page
  section **"Validate the certificate issuer for PKI and PKIPN authentication"**. 📋 Copy the key name
  from that page. The value is the issuing CA's name, taken from `user.cer`'s **Issuer** ([chunk 01](01-user-certificate.md)).
- ⌨ `iisreset`

## Done when

- [ ] PKIPN DLL in `CustomAuthenticationDlls` and web.config updated, on every PVWA server
- [ ] `pkipn` authentication method enabled
- [ ] `ValidatePKICertificate` = Yes
- [ ] (Optional) issuer restricted to the external CA
