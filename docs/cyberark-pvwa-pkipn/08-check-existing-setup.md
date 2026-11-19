# 08 — Check an existing setup (PKI and PKIPN)

**Use when:** certificate login was set up some time ago, perhaps by someone else, and you don't know
if every step was done. **Who:** Windows admin (Part A, on **each** PVWA server) + CyberArk admin
(Part B, once). **Time:** about 30 minutes.

Go down the list. For each line, write ✅ or ❌. Fix every ❌ with the chunk named, then test (06).
Most of Part A is checked for you by the diagnostic script, so start with that.

## Step 0 — Run the diagnostic script

1. 🖱 Copy `tools\pkipn-diagnose.ps1` and the test user's `user.cer` (chunk 01) to `C:\temp` on the
   PVWA server.
2. ⌨ Open **PowerShell as Administrator**, then:
   ```powershell
   cd C:\temp
   powershell -ExecutionPolicy Bypass -File .\pkipn-diagnose.ps1 -UserCert C:\temp\user.cer
   ```
3. **Expected:** a file `C:\temp\pkipn-report-<server>-<time>.txt`. Keep it open for Part A.

## Part A — Each PVWA server (Windows / IIS)

| # | Check | Where to look | Good looks like | ❌ → fix |
|---|---|---|---|---|
| A1 | External **root** in the computer's Trusted Root | Report: `Root is in LocalMachine\Root` | `[OK]` | 02 Step 1 |
| A2 | External **issuing CA** in Intermediate | 🖱 `certlm.msc` → *Intermediate Certification Authorities* | *…Identity CA G2* (your external issuing CA) is listed | 02 Step 1 |
| A3 | **Nothing but roots** in Trusted Root | Report: `LocalMachine\Root hygiene` | `[OK] Only self-signed certificates` | 02 Step 2 |
| A4 | Internal root in Trusted Root (for the PVWA's own web cert) | Report: no `WARN Self-signed (root) cert only in Intermediate CAs` | No such WARN | 02 Step 2 |
| A5 | If A3 can't be fixed (GPO): client-auth trust mode 2 | Report: `ClientAuthTrustMode` and `Client Authentication Issuers store` | Mode `0` with A3 OK, **or** mode `2` with the external root + issuing CA in the store | 02 Step 3 |
| A6 | Revocation works **as SYSTEM** | 02 Step 4 test file `verify-system.txt` | `Leaf certificate revocation check passed` | 02 Step 4 |
| A7 | HTTPS binding | Report: `netsh http show sslcert`, the `:443` entry | *Verify Client Certificate Revocation: Enabled*, *Ctl Store Name: (null)*, *Negotiate Client Certificate: Enabled* | 03 Step 1 |
| A8 | Client certificate **Require** on the PKI login folders only | Report: `sslFlags per PVWA path` | `SslNegotiateCert,SslRequireCert` on `auth/pki` (and `auth/pkipn` if listed). Plain `Ssl` on the site and on `PasswordVault` | 03 Step 2 |
| A9 | No IIS certificate mapping | Report: no `IIS client certificate mapping is enabled` | No such WARN | 07 (`403 12`) |
| A10 | PKIPN DLL in place | Report: `PKIPN module files` | `CyberArk.Authentication.CustomPKIPN.dll` (or the name your 14.6 page gives) in **both** `Bin` and `CustomAuthenticationDlls` | 04 Step 2 |
| A11 | PKI lines in `PasswordVault\web.config` | Report: `PKI-related lines in web.config` | Lines for PKI **and** PKIPN as the 14.6 page lists them; issuer value = the user cert's Issuer, exactly | 04 Steps 2 and 5 |
| A12 | `web.config` loads | ⌨ `[xml](Get-Content C:\inetpub\wwwroot\PasswordVault\web.config -Raw) \| Out-Null` | No error | 03 *If it fails* |
| A13 | Same on every PVWA server | Compare the reports | Same `[OK]`s, same web.config PKI lines | Repeat on that server |

> **A11 needs a human comparison.** Open the 14.6 page (README link) and compare its web.config lines
> with the report's, line by line. Write down anything missing or different. Typical leftovers from an
> old setup: an issuer value with a different CA name (after the CA renewed), a DLL from an older
> version, or lines edited in a copy of web.config that IIS doesn't load (`Bin` or `Env`).

## Part B — PVWA and Vault settings (CyberArk admin, once)

| # | Check | Where | Good looks like | ❌ → fix |
|---|---|---|---|---|
| B1 | PKIPN method exists and is on | 🖱 PVWA → *Administration* ► *Options* → *Authentication Methods* → `pkipn` | *Enabled* = **Yes** | 04 Step 3 |
| B2 | PKI method (if you use it) | Same place → `pki` | *Enabled* = Yes, or No if you don't use plain PKI | 04 Step 3 |
| B3 | Users see the right option | 🖱 PVWA sign-in page (new InPrivate window) | The PKIPN display name is offered | 04 Step 3 |
| B4 | Extended certificate checks | *Options* → *General* → `ValidatePKICertificate` | Yes (recommended) | 04 Step 4 |
| B5 | Vault user name = certificate UPN | 🖱 PVWA → *Users* → find the test user | User name is exactly the `Principal Name` from the report (e.g. `chaitanya.nampalli@acme.corp.au`) | 05 Step 2 |
| B6 | LDAP mapping uses the UPN | *Administration* ► *LDAP Integration* → directory → mapping → *UserLogonName* | `userPrincipalName` (if users come from LDAP) | 05 Step 2 |
| B7 | LDAP mapping covers the user's domain/branch | Same mapping → *LDAP Branch* / domain | Includes where the user's AD account lives | 05 Step 2 |
| B8 | User's authentication method | 🖱 PVWA → *Users* → the user → *Authentication method* (or PrivateArk Client → user → *Authentication*) | Allows certificate login. 📋 Check the value the 14.6 page requires for PKI/PKIPN users | 05 Step 3 |
| B9 | User active | Same user | Not disabled, not suspended, not expired | 05 Step 3 |
| B10 | PVWA allowed for the user | Same user → *Authorized interfaces* / network areas | Includes **PVWA** | 05 Step 3 |
| B11 | PVWA gateway user healthy | PrivateArk Client → `PVWAGWUser` (or your gateway user) | Not suspended; recent successful logons in the Vault's `ITALog.log` | 07 Stage 5 |

## Done when

- [ ] Every line ✅ on every PVWA server, or a ticket raised for the ❌ you can't fix yourself
- [ ] Report files saved (they're your "before" record)
- [ ] 06 — Test passes
