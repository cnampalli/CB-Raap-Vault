# 07 — Troubleshooting

Work through the stages **in order**. Each one depends on the one before it. Stop at the first that
fails.

## Run the diagnostic script first

On **each** PVWA server, as Administrator, with the user's **public** `user.cer` (chunk 01):

1. 🖱 Copy [`tools/pkipn-diagnose.ps1`](tools/pkipn-diagnose.ps1) to the server.
2. ⌨ `wevtutil sl Microsoft-Windows-CAPI2/Operational /e:true` (enables certificate logging).
3. 🖱 Try the certificate login once from a workstation, so the logs hold a failed attempt.
4. ⌨ `powershell -ExecutionPolicy Bypass -File .\pkipn-diagnose.ps1 -UserCert C:\temp\user.cer`

**Expected:** a `pkipn-report-<server>-<time>.txt` with `[OK]` / `[FAIL]` lines for stages 2–4, plus
the binding, IIS sslFlags per folder, PKIPN DLL locations, the PKI lines in your web.config, and recent
403 sub-statuses. The first `[FAIL]` points to the table below. The script only reads. It doesn't
change anything.

The report also answers three things the guide marks 📋: which **DLL** your install has, what your
**web.config** already contains for PKI, and which **IIS folders** exist under `PasswordVault\auth`.

## Or collect by hand (on the PVWA server that served the attempt)

| What | Where |
|---|---|
| IIS status + **sub-status** | `C:\inetpub\logs\LogFiles\W3SVC1\u_ex<yymmdd>.log`, columns `sc-status sc-substatus sc-win32-status` |
| Certificate chain / revocation errors | Event Viewer → *Applications and Services Logs* → *Microsoft* → *Windows* → **CAPI2** → *Operational*. Right-click → **Enable Log** first, then retry the login |
| TLS handshake errors | Event Viewer → *Windows Logs* → **System**, source **Schannel** |
| PVWA application errors | `C:\Windows\Temp\PVWA\` (PVWA application logs; newest file) |
| Vault side | Vault server `…\PrivateArk\Server\Logs\ITALog.log`, around the login time |
| Binding | `netsh http show sslcert` |

## Stage 1 — Browser ↔ PVWA server certificate (internal CA)

| Symptom | Cause | Fix |
|---|---|---|
| "Your connection is not private" on the PVWA page | Workstation doesn't trust the internal CA | Deploy the internal root to workstations (GPO) |

## Stage 2 — Is a certificate requested and sent?

| Symptom | Cause | Fix |
|---|---|---|
| No certificate prompt, **`403.7`** | IIS isn't asking at the right point | Chunk 03 Step 2 (folder *Require*), Step 3 (TLS 1.3) |
| No prompt, but the cert is installed | Browser cached a previous choice / cancel | New InPrivate window; restart the browser |
| Cert not in the prompt list | No private key; missing Client Authentication EKU; or the server sends an issuer list (CTL) without the external CA | Chunk 01 Steps 2–3; chunk 03 Step 1 (CTL) |
| Works on TLS 1.2, fails on TLS 1.3 | No post-handshake auth | Chunk 03 Step 3 |
| `ERR_HTTP2_…` / `HTTP_1_1_REQUIRED` | HTTP/2 can't renegotiate for a client cert | Usually the browser retries on HTTP/1.1. If not, use chunk 03 Step 3A |

## Stage 3 — Does Windows trust the certificate? (most common with an external CA)

⌨ First run `certutil -verify -urlfetch user.cer` **on the PVWA server**. Read CAPI2 for the attempt.

| IIS sub-status | Meaning | Fix |
|---|---|---|
| **`403.16`** with win32 **`2148204809`** (`0x800B0109`, untrusted root) | The chain from the certificate the browser **actually sent** ends at a root IIS doesn't accept | **(1)** The browser sent a different certificate than you tested. No PIN prompt is a clue: a software cert was picked instead of the smart card. Check CAPI2 **Event 11** for the subject and thumbprint, and re-run chunk 02's SYSTEM test with *that* cert. **(2)** IIS is limited to the **Client Authentication Issuers** store: a *Ctl Store Name* on the binding (`netsh http show sslcert`) or `ClientAuthTrustMode` = 1/2 (`reg query HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v ClientAuthTrustMode`). Add the external root (and, for mode 2, the issuing CA) with `certutil -addstore ClientAuthIssuer <file>.cer`, then **reboot**. **(3)** Non-self-signed certs in LocalMachine\Root (script: `Not self-signed, move to Intermediate CAs`): see [below](#40316-with-a-non-self-signed-cert-in-trusted-root) |
| **`403.16`** (other codes) | Client certificate untrusted or invalid | Root not in Local Computer *Trusted Root*; intermediate missing; an **intermediate sitting in Trusted Root** (any non-self-signed cert there breaks client auth); or a CTL on the binding that lacks the external CA. Chunk 02 Step 1, chunk 03 Step 1 |
| **`403.13`** | Revoked, **or the CRL couldn't be downloaded** | Usually the PVWA server can't reach the external CA's CRL/OCSP (proxy/firewall). Chunk 02 Step 3. To confirm only: turn off *Verify Client Certificate Revocation* on the binding, test, **turn it back on** |
| **`403.17`** | Expired / not yet valid | Reissue; check the clocks |
| `403.12` | Mapping denied | IIS client-certificate mapping is configured on the site. Remove it; PKIPN does the mapping |

### 403.16 with a non-self-signed cert in Trusted Root

Seen on a Server 2019 PVWA: the chain builds fine (`certutil -verify` passes, the external root is in
LocalMachine\Root, revocation passes as SYSTEM), yet IIS logs `403 16 2148204809` for every certificate.
The report shows `[FAIL] Not self-signed, move to Intermediate CAs: CN=<internal sub-CA>`. With
`ClientAuthTrustMode` = 0, one intermediate in Trusted Root is enough to make Schannel reject client
certificates as untrusted root, whatever CA issued them (Microsoft KB 2802568). The cert there is often
the **internal** CA's issuing CA, imported with the PVWA web certificate.

1. ⌨ See where it's stored (the report's `stored in:` line says the same):
   ```cmd
   certutil -store Root <thumbprint>
   certutil -grouppolicy -store Root <thumbprint>
   certutil -enterprise -store Root <thumbprint>
   ```
   If it's in **GroupPolicy** or **Enterprise**, deleting it locally won't last: the next `gpupdate`
   puts it back. Have the GPO / AD owner move it to *Intermediate Certification Authorities* there.
2. ⌨ Check its own root is in Trusted Root (report: `its own root in Root: yes`). If not, import that
   root to `LocalMachine\Root` first, or the PVWA web certificate's chain breaks.
3. ⌨ Move it (LocalMachine store; PowerShell as Administrator):
   ```powershell
   $t = '<thumbprint>'
   Export-Certificate -Cert "Cert:\LocalMachine\Root\$t" -FilePath C:\temp\sub-ca.cer
   Import-Certificate -FilePath C:\temp\sub-ca.cer -CertStoreLocation Cert:\LocalMachine\CA
   Remove-Item "Cert:\LocalMachine\Root\$t"
   ```
4. 🖱 **Reboot** the PVWA server. Schannel caches its trust lists; `iisreset` is not enough.
5. ⌨ Re-run the script. **Expected:** `[OK] Only self-signed certificates in LocalMachine\Root`.
6. 🖱 Retry the login in a new InPrivate window. **Expected:** the IIS log line is no longer `403 16`.

**Can't move it** (owned by someone else, needed in Root): use exclusive CA trust instead.
⌨ `reg add HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v ClientAuthTrustMode /t REG_DWORD /d 2 /f`,
then `certutil -addstore ClientAuthIssuer` the external **root** and **issuing CA** `.cer` files, then reboot.
Only certificates from CAs in that store are accepted afterwards.

**Afterwards, turn revocation back on** if you turned it off to test. `netsh http update sslcert` resets
options you leave out, so pass the ones you rely on (hash and app ID from `netsh http show sslcert`):
```cmd
netsh http update sslcert ipport=0.0.0.0:443 certhash=<hash> appid={<app-id>} certstorename=MY verifyclientcertrevocation=enable clientcertnegotiation=enable
```
**Expected:** *Verify Client Certificate Revocation: Enabled*, *Negotiate Client Certificate: Enabled*.
Retry the login. A new `403.13` here means IIS can't reach the CRL as SYSTEM: chunk 02 Step 3.

> The script's chain check runs as **you**. `RevocationStatusUnknown` / `OfflineRevocation` there, with
> the SYSTEM test in chunk 02 passing, is your user's proxy settings, not the login. The script marks
> these `WARN`.

> "I already trusted the CA" usually means it was imported into the **Current User** store, or into
> one PVWA server only, or the intermediate went into *Trusted Root*. Check with `certlm.msc`
> on **each** server.

## Stage 4 — Does PVWA read a UPN from the certificate?

Seen as: the certificate prompt succeeds (IIS log `200` on the pkipn request), then PVWA shows an
authentication error.

| Cause | Fix |
|---|---|
| No `Principal Name` in the SAN (external certs often carry only e-mail) | Reissue with a UPN SAN (chunk 01) |
| PKIPN module not loaded: DLL missing on **this** PVWA server, or the PKIPN entry missing from `PasswordVault\web.config` (the file IIS loads; the report lists it) | Chunk 04 Step 2 on every server |
| `pkipn` method missing or disabled | Chunk 04 Step 3 |
| `ValidatePKICertificate=Yes` and the cert fails a check (CA cert, self-signed, key usage/EKU) | Fix the certificate (chunk 01), or set `No` briefly to confirm |
| Issuer restriction set to a different CA name | Chunk 04 Step 5: use the exact Issuer from `user.cer` |

## Stage 5 — Does the Vault accept the user?

Check `ITALog.log` on the Vault and the PVWA logs.

| Cause | Fix |
|---|---|
| User not found: UPN vs `sAMAccountName` name | Chunk 05 Step 2 |
| User disabled / suspended / expired | Chunk 05 Step 3 |
| LDAP user can't be created: no directory mapping matches the user's LDAP branch | Add or fix the directory mapping for that branch |
| Not authorized from the PVWA network area / interface | Chunk 05 Step 3 |
| **All** certificate logins fail, password logins work | PVWA gateway user (`PVWAGWUser`) locked or credential file stale. Check it in PrivateArk / the Vault log. Reset per CyberArk's credential-file procedure |

## Still stuck

Send CyberArk support: the IIS log line (with sub-status), the CAPI2 events for the attempt, the
`certutil -verify -urlfetch user.cer` output, the PVWA log lines, and the `ITALog.log` lines. The
private key never leaves the user's machine. `user.cer` is safe to share.
