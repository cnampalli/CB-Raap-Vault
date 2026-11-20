# 02 — PVWA server: trust the external CA

**Who:** Windows admin, on **every** PVWA server · **Needs:** `user.cer` ([chunk 01](01-user-certificate.md)), the external
root and issuing-CA `.cer` files · **Gives:** IIS on the PVWA server accepts the user's certificate

**In short:** IIS checks the user's certificate using the **computer's** certificate stores
(`certlm.msc`). Each CA must be in the **right** store, and the server must be able to download the
CA's revocation list (CRL).

## Step 1 — Put the external CA certificates in the right stores

| Certificate | How to recognise it | Store in `certlm.msc` | ⌨ Command |
|---|---|---|---|
| External **root** | *Issued to* = *Issued by* | **Trusted Root Certification Authorities** | `certutil -addstore Root C:\temp\ext-root.cer` |
| External **issuing CA** (e.g. *…Identity CA G2*) | *Issued by* = the root | **Intermediate Certification Authorities** | `certutil -addstore CA C:\temp\ext-issuing-ca.cer` |

**Expected:** both show in `certlm.msc`, in those folders.

## Step 2 — Trusted Root must hold roots only

One intermediate (sub-CA) in *Trusted Root*, **any** intermediate, internal or external, makes IIS
reject **every** client certificate with `403 16` (win32 `2148204809`). Microsoft KB 2802568.

1. ⌨ PowerShell as Administrator:
   ```powershell
   Get-ChildItem Cert:\LocalMachine\Root | ? { $_.Subject -ne $_.Issuer } | fl Subject, Issuer, Thumbprint
   Get-ChildItem Cert:\LocalMachine\CA   | ? { $_.Subject -eq $_.Issuer } | fl Subject, Thumbprint
   ```
   **Expected:** the **first** command shows nothing. The second shows roots sitting in
   *Intermediate*. That's harmless **if** the same root is also in *Trusted Root*.
2. If the first command lists something, fix it. Order matters, so the PVWA's own web certificate
   never loses its chain:
   1. 🖱 `certlm.msc`: if that sub-CA's own root (its *Issued by*) is **not** in *Trusted Root*,
      right-click it in *Intermediate* → **Copy** → *Trusted Root* → *Certificates* → **Paste**.
   2. 🖱 Right-click the sub-CA in *Trusted Root* → **Copy** → *Intermediate* → *Certificates* →
      **Paste**.
   3. 🖱 Back in *Trusted Root*, right-click the sub-CA → **Delete**.
   4. 🖱 **Reboot** (IIS only reads the change after a reboot).
3. ⌨ Run the first command again, then once more after `gpupdate /force`. **Expected:** nothing.
   **Still listed?** A Group Policy puts it back: go to Step 3.
4. ⌨ The PVWA's own certificates still work:
   `certutil -verifystore MY <hash from netsh http show sslcert>`.
   **Expected:** ends with `-verifystore command completed successfully`.

## Step 3 — Only if a Group Policy keeps a sub-CA in Trusted Root

Find it: ⌨ `gpresult /scope computer /h C:\temp\gp.html` → open the file → *Public Key Policies* →
*Trusted Root Certification Authorities* → note the **Winning GPO**. Ask its owner to move the
sub-CA to *Intermediate*. Until then, tell IIS to accept client certificates **only** from the
external CA. That avoids the problem without touching AD:

1. ⌨ Export the external root and issuing CA, if you don't already have the `.cer` files:
   ```powershell
   Export-Certificate -Cert (gci Cert:\LocalMachine\Root | ? Subject -like 'CN=<external root name>,*') -FilePath C:\temp\ext-root.cer
   Export-Certificate -Cert (gci Cert:\LocalMachine\CA   | ? Subject -like 'CN=<external issuing CA name>,*') -FilePath C:\temp\ext-issuing-ca.cer
   ```
2. ⌨ Add them to the *Client Authentication Issuers* store, and switch the mode:
   ```cmd
   certutil -addstore ClientAuthIssuer C:\temp\ext-root.cer
   certutil -addstore ClientAuthIssuer C:\temp\ext-issuing-ca.cer
   reg add HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v ClientAuthTrustMode /t REG_DWORD /d 2 /f
   ```
3. 🖱 **Reboot.**
4. ⌨ Re-run the diagnostic script. **Expected:** `ClientAuthTrustMode = 2` and
   `[OK] Required issuer is in ClientAuthIssuer`.

Afterwards only that external CA can be used for certificate logins on this server. When the external
CA renews its issuing CA, add the new one to `ClientAuthIssuer`. Undo: `reg delete
HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL /v ClientAuthTrustMode /f`, reboot.

**More than one issuing CA.** The store can hold several. In mode 2 IIS accepts a client certificate
whose chain contains **any** certificate in `ClientAuthIssuer`, so add each issuing CA you want to
allow (a renewed CA certificate, a second external CA), with `certutil -addstore ClientAuthIssuer
<file>.cer` each, then reboot. Rules:
- Add **issuing** CAs, not their root. A root there allows every CA under it.
- Each one still needs its root in *Trusted Root* and itself in *Intermediate*, and a reachable CRL.
- The store applies to **every** site on this server that asks for client certificates.
- PVWA checks the issuer again: add the same CA to the issuer setting too (04 Step 5; 📋 the
  14.6 page says how to list several), or PVWA refuses it with *"issuer is not authorized"*.
- Keep the list short: IIS sends these names to the browser, which only offers matching certificates.

## Step 4 — Revocation works the way IIS checks it (as SYSTEM)

The external CA's CRL is on the internet. The PVWA server reaches it only through the **WinHTTP
machine proxy**, not a browser, PowerShell or web.config proxy.

1. ⌨ `netsh winhttp show proxy`. If it says *Direct access*, set it (elevated prompt, host:port, no `http://`):
   ```cmd
   netsh winhttp set proxy proxy-server="10.x.x.x:3128" bypass-list="<local>"
   ```
2. ⌨ Test **as SYSTEM**, which is how IIS checks:
   ```cmd
   schtasks /create /tn pkicheck /sc once /st 00:00 /ru SYSTEM /f /tr "cmd /c certutil -urlcache * delete & certutil -verify -urlfetch C:\temp\user.cer > C:\temp\verify-system.txt 2>&1"
   schtasks /run /tn pkicheck
   ```
   Wait one minute, then:
   ```cmd
   type C:\temp\verify-system.txt
   schtasks /delete /tn pkicheck /f
   ```
   **Expected:** the CRL line shows `Verified`, and the end says `Leaf certificate revocation check
   passed` and `-verify command completed successfully`.

**Your own `certutil` run fails but the SYSTEM one passes?** That's fine for login. Your user session
uses its own proxy settings. Details and the other proxy problems: 07, *Revocation and proxy*.

## Done when

- [ ] External root in *Trusted Root*, issuing CA in *Intermediate*, on every PVWA server
- [ ] No sub-CA in *Trusted Root*, **or** `ClientAuthTrustMode` = 2 with the external CAs in `ClientAuthIssuer`
- [ ] `verify-system.txt` passes on every PVWA server

## If it fails

| You see | Fix |
|---|---|
| `CERT_TRUST_IS_UNTRUSTED_ROOT` | Root missing, or in the wrong store (Step 1) |
| `CERT_TRUST_IS_PARTIAL_CHAIN` | Issuing CA missing (Step 1) |
| `REVOCATION_STATUS_UNKNOWN` / `OFFLINE_REVOCATION` / `12007` / `could not be resolved` | Proxy (Step 4, then 07 *Revocation and proxy*) |
| `CERT_TRUST_IS_REVOKED` | The certificate really is revoked. Reissue |
