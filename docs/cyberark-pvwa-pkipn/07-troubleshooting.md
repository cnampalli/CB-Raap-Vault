# 07 — Troubleshooting

**In short:** get the **IIS result** for one failed attempt, find it in the first table, do what it
says. Fix one thing at a time and test again after each fix.

## Step 1 — Get the evidence for one attempt

1. 🖱 Copy [`tools/pkipn-collect.ps1`](tools/pkipn-collect.ps1) to `C:\temp` on the PVWA server.
   Behind a load balancer: point the browser at **this** server directly, or run it on every server.
2. ⌨ PowerShell **as Administrator**:
   ```powershell
   cd C:\temp
   powershell -ExecutionPolicy Bypass -File .\pkipn-collect.ps1
   ```
3. 🖱 When it says *Ready*, try the certificate login **once**, in a **new InPrivate** window.
   Then press **Enter** in PowerShell.
4. **Expected:** it prints a summary and makes `C:\temp\pkipn-evidence-<server>-<time>.zip`.

Not sure the setup is complete at all? Run the checklist in [08](08-check-existing-setup.md) first.
Need more detail than the summary gives? Turn on [09 — Debug logging](09-debug-logging.md) and repeat.

## Step 2 — Find your line

The IIS line for `/PasswordVault/api/auth/pkipn/logon` ends with `… 403 16 2148204809 12`: status,
**sub-status**, win32 code, time taken. IIS log times are **UTC**; Event Viewer and PVWA logs use the
server's local time (`tzutil /g` shows it). Compare the same attempt.

| IIS shows | Stage | It means | Go to |
|---|---|---|---|
| No line at all | 1 | The request didn't reach this server, or the browser refused the PVWA page | Other server? Browser warning? → [Stage 1](#stage-1--the-browser-trusts-the-pvwa-page) |
| `403 7` | 2 | No certificate was sent | [Stage 2](#stage-2--a-certificate-is-asked-for-and-sent) |
| `403 16 2148204809` | 3 | Certificate not trusted (untrusted root) | [Stage 3, 403 16](#403-16-not-trusted) |
| `403 16` (other code) | 3 | Certificate not valid for IIS | [Stage 3, 403 16](#403-16-not-trusted) |
| `403 13` | 3 | Revoked, **or the CRL couldn't be downloaded** | [Stage 3, 403 13](#403-13-revocation) |
| `403 17` | 3 | Expired or not yet valid | Reissue the certificate; check clocks |
| `403 12` | 3 | IIS certificate mapping refused it | Remove IIS client-certificate mapping from the site; PVWA does the mapping |
| `500 0 0` on the pkipn request, often with a long time taken (last number, ms; e.g. `31886` = 32 s) | 4–5 | IIS accepted the certificate. PVWA failed while handling it, usually waiting on something that timed out (Vault/LDAP lookup, or PVWA's own certificate check fetching CRLs) | [Stage 4](#stage-4--pvwa-reads-the-certificate): get the PVWA log lines for that request (09 section 4) and `ITALog.log` |
| `200` (or `401`), then a PVWA error | 4–5 | IIS accepted the certificate. PVWA or the Vault said no | [Stage 4](#stage-4--pvwa-reads-the-certificate) then [Stage 5](#stage-5--the-vault-accepts-the-user) |

## Stage 1 — The browser trusts the PVWA page

| You see | Fix |
|---|---|
| "Your connection is not private" on the PVWA page | The workstation doesn't trust the **internal** CA. Deploy the internal root to workstations (GPO) |

## Stage 2 — A certificate is asked for and sent

| You see | Fix |
|---|---|
| `403 7 64` on `/api/auth/pkipn/logon`, and the browser **did** prompt earlier | The binding asks for the certificate when the PVWA page **first opens**. If that first prompt was cancelled (or answered with another certificate), the browser keeps that choice for the whole session, and the PKIPN request arrives without one (`64` = connection dropped while IIS asked again) | Close **all** browser windows, new InPrivate window, open the PVWA, and **pick the certificate at the first prompt**. Then choose the PKIPN option |
| No certificate prompt, `403 7` | 03 Step 2 (*Require* on the PKI folder). On Server 2022+: 03 Step 3 (TLS 1.3) |
| No prompt, but the certificate is installed | The browser remembers an earlier choice or *Cancel*. Close **all** browser windows, new InPrivate window |
| Certificate missing from the prompt list | No private key, or no *Client Authentication* EKU (01 Step 2–3); or a CTL on the binding (03 Step 1) |
| `ERR_HTTP2_…` / `HTTP_1_1_REQUIRED` | 03 Step 3A |

## Stage 3 — IIS trusts the certificate

### 403 16: not trusted

Check these in order. The diagnostic script (08 Step 0) shows each one.

1. **A sub-CA (intermediate) in Trusted Root.** Script: `[FAIL] Not self-signed, move to Intermediate CAs`.
   **Any** intermediate there, internal or external, makes IIS refuse every client certificate with
   `403 16 2148204809`, even when everything else is right (Microsoft KB 2802568).
   Fix: 02 Step 2. If the script says `stored in: GroupPolicy`, a GPO puts it back: 02 Step 3.
2. **External root or issuing CA missing** from the computer stores, or only in *Current User*.
   Script: `Root is NOT in LocalMachine\Root`, or `PartialChain`. Fix: 02 Step 1.
3. **IIS limited to a list of issuers that lacks the external CA.** Script: a `CTL store` WARN on the
   binding, or `ClientAuthTrustMode` = 1 or 2 with the external CA not in `ClientAuthIssuer`. Fix:
   02 Step 3 (add it to `ClientAuthIssuer`), or remove the CTL (03 Step 1).
4. **The browser sent a different certificate than you tested.** The collector's *Certificate checks
   by IIS* line shows the subject and thumbprint IIS really checked. No PIN prompt is a clue: a
   software certificate was chosen instead of the smart card. Test again with the right one.

After any change in 1–3: **reboot**. `iisreset` is not enough.

### 403 13: revocation

The PVWA server couldn't confirm the certificate isn't revoked, nearly always because it can't
download the external CA's CRL. Run 02 Step 4 (the SYSTEM test). If that fails, see
[Revocation and proxy](#revocation-and-proxy) below.

To **confirm** it's revocation (test only): turn *Verify Client Certificate Revocation* off on the
binding, test, and **turn it back on**. `netsh http update` resets every option you leave out, so
always give them all (hash and app ID from `netsh http show sslcert`):
```cmd
netsh http update sslcert ipport=0.0.0.0:443 certhash=<hash> appid={<app-id>} certstorename=MY verifyclientcertrevocation=enable clientcertnegotiation=enable
```
**Expected:** `netsh http show sslcert` shows *Verify Client Certificate Revocation: Enabled* and
*Negotiate Client Certificate: Enabled*.

## Stage 4 — PVWA reads the certificate

IIS shows `200` (or `401`) for the pkipn request, then PVWA shows an error. Look in the PVWA logs for
that request (09 section 4).

| Cause | Fix |
|---|---|
| No `Principal Name` in the certificate's SAN (only an e-mail) | Reissue with a UPN (01) |
| PKIPN not installed on **this** server: DLL missing, or its lines missing from `PasswordVault\web.config` | 04 Step 2 (check with 08 A10–A11) |
| `pkipn` method missing or disabled | 04 Step 3 |
| PVWA says **"The Client Certificate issuer is not authorized. Choose a different certificate with an authorized issuer."** | PVWA's issuer restriction (`web.config` → `<appSettings>`, e.g. `PKIAuthorizedIssuer`) doesn't match the Issuer of the certificate the browser **sent**. Either a certificate from another CA was picked, the CA renewed, or the text differs (spaces after commas, order, case) | 04 Step 5: compare the sent certificate's Issuer with the `web.config` value, character by character, and make them identical |
| `ValidatePKICertificate` = Yes and the certificate fails a check | Fix the certificate (01). To confirm only: set No, test, set Yes again |
| IIS `500` after ~15–60 s; PVWA log shows a timeout or chain/revocation error | `ValidatePKICertificate` = Yes makes PVWA check the certificate again, as the **app pool** account. It tries every CRL/AIA URL, including `ldap://` ones the server can't reach, and waits for each | To confirm: set `ValidatePKICertificate` = No, test, set it back. Fix: make the `http://` URLs reachable (02 Step 4) and ask the CA team whether the `ldap://` URLs are needed, or allow them |
| IIS `500` after ~30 s; `ITALog.log` shows LDAP errors for the user | The Vault couldn't find or create the user through LDAP in time (LDAP server or domain unreachable from the Vault, or the mapping searches the wrong branch) | 05 Step 1; check the Vault's LDAP connection for that domain |
| User picked **PKI** instead of the PKIPN option | Use the PKIPN option on the sign-in page. IIS log shows `/auth/pki/logon` instead of `/auth/pkipn/logon` |

## Stage 5 — The Vault accepts the user

Check the PVWA logs, and `ITALog.log` on the Vault (09 section 5).

| Cause | Fix |
|---|---|
| PVWA says **"Authentication failure for the user [<UPN>]"** (the Vault's `ITATS004E`) | The Vault refused this user. PVWA and IIS are fine. The reason is in the Vault's `ITALog.log` on the line just before `ITATS004E`: user not found, wrong authentication method, suspended, or not allowed from PVWA | Read `ITALog.log` (09 section 5). Check the UPN in the message is exactly the AD `userPrincipalName` (watch for typos such as `.ai` vs `.au`). Then 05 Steps 1–3 and 08 B5–B11 |
| "User not found": the Vault name is `jdoe` but the certificate says `jdoe@corp…` | 05 Step 2 |
| LDAP user can't be created: the directory mapping doesn't cover the user's domain or branch | 05 Step 2; 08 B6–B7 |
| User disabled, suspended, expired, or not allowed through PVWA | 05 Step 3 |
| **Every** certificate login fails, password logins work | PVWA gateway user (`PVWAGWUser`) suspended or its credential file stale. Check in PrivateArk and `ITALog.log`; reset per CyberArk's credential-file procedure |

## Revocation and proxy

Windows downloads CRLs through the **WinHTTP machine proxy** only (`netsh winhttp`). A proxy in
PowerShell, in the browser, or in `web.config` doesn't count for IIS.

| You see | Cause | Fix |
|---|---|---|
| `12007` / `could not be resolved` / `0x80072ee7` | WinHTTP goes direct, can't resolve the internet name | 02 Step 4 item 1. Use host:port, no `http://`, in a **64-bit, elevated** prompt. The bypass list must not match the CRL host |
| SYSTEM test passes, your own `certutil` gives `12007` | Your session uses your user's proxy settings and cache | Not a login problem. Optional: set the proxy in Internet Options, `certutil -urlcache * delete` |
| Script stage 3 shows `RevocationStatusUnknown` / `OfflineRevocation` as `WARN` | Same: the script runs as you | Trust the SYSTEM test (02 Step 4) |
| WinHTTP test returns `407` | Proxy wants a login; IIS can't log in to a proxy | Ask the proxy team to allow the CRL/OCSP hosts from the PVWA servers without authentication |
| CRL `Verified`, OCSP failed, check **passed** | Windows fell back to the CRL | Not blocking. Allow the OCSP host on the proxy when convenient |
| Errors only on `ldap://` URLs | The `http://` URL worked | Harmless |

**WinHTTP test** (uses the machine proxy, like IIS):
```powershell
$r = New-Object -ComObject WinHttp.WinHttpRequest.5.1
$r.Open('GET', 'http://<crl-host>/<path>.crl', $false); $r.Send(); $r.Status
```
**Expected:** `200`.

**OCSP test.** A plain web request to an OCSP URL returns `400`/`405`, which still means *reachable*.
Only a proxy error page, a timeout or `12007` means blocked. A real test (Git Bash, OpenSSL 3.x):
```bash
openssl x509 -inform DER -in user.cer -out user.pem
openssl ocsp -issuer ext-issuing-ca.pem -cert user.pem -url http://<ocsp-host>/<path> -proxy 10.x.x.x:3128 -noverify -resp_text | grep -E 'Cert Status|Response Status'
```
**Expected:** `OCSP Response Status: successful`, `Cert Status: good`.

## Still stuck

Send CyberArk support:
- the collector zip;
- the diagnostic report;
- `C:\temp\verify-system.txt` (02 Step 4);
- the PVWA error text;
- the Vault `ITALog.log` lines from the same minute.

`user.cer` is safe to share. The private key never leaves the user's machine.

## Seen on this deployment

| Date | Symptom | Cause | Fix |
|---|---|---|---|
| 2026-11 | `403 16 2148204809` for every certificate; chain and revocation fine | Old internal sub-CA (`6B814EEE…`) pushed into *Trusted Root* by a **GPO**; internal root sitting only in *Intermediate* | Internal root added to Trusted Root, sub-CA moved locally (02 Step 2). The GPO re-adds it, so `ClientAuthTrustMode` = 2 with the external CAs (02 Step 3) until the GPO owner fixes the policy |
| 2026-11 | `12007` on CRL download | `netsh winhttp` proxy not set | 02 Step 4 |
| 2026-11 | IIS Manager: `Only one <configSections> element allowed` | A proxy stanza pasted above `<configSections>` in `PasswordVault\web.config` | 03 *If it fails* |
