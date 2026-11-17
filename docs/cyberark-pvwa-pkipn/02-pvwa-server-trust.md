# 02 — PVWA server trust and revocation

**Who:** Windows admin, on **every** PVWA server · **Needs:** `user.cer` (chunk 01), the external
root and intermediate `.cer` files · **Gives:** Windows on the PVWA server fully validates the user's
certificate

IIS validates the client certificate with the **Local Computer** certificate stores on the PVWA
server, and checks revocation. "Trusted in PVWA" means: in these stores, **in the right store**, with
revocation reachable.

## Step 1 — Put each CA certificate in the right store

| Certificate | Store (Local Computer) | ⌨ Command |
|---|---|---|
| External **root** (subject = issuer) | **Trusted Root Certification Authorities** | `certutil -addstore Root ext-root.cer` |
| External **intermediate(s)** | **Intermediate Certification Authorities** | `certutil -addstore CA ext-intermediate.cer` |

Rules:
- **Local Computer** store, not Current User. `certmgr.msc` is the user store; use **`certlm.msc`**.
- **Never** put an intermediate in *Trusted Root*. On Windows Server 2012 and later, any
  non-self-signed certificate in the machine Root store makes IIS reject client certificates with
  **`403.16`**.

⌨ Check that the Root store has only self-signed certificates:
```powershell
Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -ne $_.Issuer } |
  Format-List Subject, Issuer, Thumbprint
```
**Expected:** no output. Move anything listed to *Intermediate Certification Authorities*.

## Step 2 — Windows can build and check the user's chain

⌨
```cmd
certutil -verify -urlfetch user.cer
```
**Expected:**
- The chain ends at the external root, with no `CERT_TRUST_IS_UNTRUSTED_ROOT` or `PARTIAL_CHAIN`.
- Under **Certificate CDP** and **AIA**, the URLs show `Verified`, and not `Error` or `Failed`.
- Last line: `Leaf certificate revocation check passed` and `CertUtil: -verify command completed
  successfully.`

## Step 3 — Revocation is reachable from the PVWA server

PVWA servers are often locked down. The **external** CA's CRL and OCSP URLs (chunk 01) are on the
internet.

**Which proxy matters.** Windows certificate validation (IIS checking the client certificate, and
`certutil`) uses **only the WinHTTP machine proxy**. These do **not** help:
- a proxy set in a PowerShell session or script (`Invoke-WebRequest -Proxy`, `[Net.WebRequest]::DefaultWebProxy`)
- a `<system.net><defaultProxy>` stanza in the PVWA `web.config`, which only affects the PVWA
  application's own HTTP calls
- the browser / Internet Options proxy, unless you import it into WinHTTP

A PowerShell download of the CRL that works therefore proves the proxy path, not that IIS can use it.
`could not be resolved` / `ERROR_WINHTTP_NAME_NOT_RESOLVED` (12007) in `certutil` means WinHTTP is
going **direct**, and the server can't resolve the external name.

1. ⌨ `netsh winhttp show proxy`. *Direct access (no proxy server)* means it isn't set.
2. ⌨ Set it, in an **elevated** Command Prompt. Use the same proxy your working PowerShell script uses,
   and keep internal names direct:
   ```cmd
   netsh winhttp set proxy proxy-server="http=proxy.corp:8080;https=proxy.corp:8080" bypass-list="<local>;*.corp.example.com"
   ```
   Or copy the Internet Options proxy: `netsh winhttp import proxy source=ie`.
3. ⌨ Clear Windows' cached failures, then re-run Step 2:
   ```cmd
   certutil -urlcache * delete
   certutil -setreg chain\ChainCacheResyncFiletime @now
   certutil -verify -urlfetch user.cer
   ```
4. 🖱 Do this on **every** PVWA server.

**Still `12007` / `could not be resolved` after setting the proxy?** Windows is still going direct.
Check in this order:

1. **The setting itself.** Use host:port only, with no `http://`, in an **elevated, 64-bit** prompt.
   A 32-bit (x86) PowerShell writes to a different registry key.
   ```cmd
   netsh winhttp set proxy proxy-server="10.x.x.x:3128" bypass-list="<local>"
   netsh winhttp show proxy
   ```
   **Expected:** `Proxy Server(s) : 10.x.x.x:3128`. The bypass list must **not** match the CRL/OCSP
   host (e.g. no `*.acme.test.au`).
2. **WinHTTP uses it.** ⌨ PowerShell. This uses the machine WinHTTP setting, with no proxy given:
   ```powershell
   $r = New-Object -ComObject WinHttp.WinHttpRequest.5.1
   $r.Open('GET', 'http://crl.acme.test.au/<path-from-certutil>.crl', $false); $r.Send(); $r.Status
   ```
   **Expected:** `200`. `12007` here means the netsh setting isn't being applied (back to 1). `407`
   means the proxy wants a login. Ask the proxy team to allow the PVWA servers to reach the CRL/OCSP
   hosts **without** authentication, because IIS can't log in to a proxy.
3. **Test as SYSTEM, the way IIS checks.** `certutil` in your own session can use **your user's**
   Internet Options proxy and **your user's** URL cache, not the machine's. IIS validates client
   certificates in the machine context. Run the check as SYSTEM:
   ```cmd
   schtasks /create /tn pkicheck /sc once /st 00:00 /ru SYSTEM /f /tr "cmd /c certutil -urlcache * delete & certutil -verify -urlfetch C:\temp\user.cer > C:\temp\verify-system.txt 2>&1"
   schtasks /run /tn pkicheck
   timeout /t 60
   type C:\temp\verify-system.txt
   schtasks /delete /tn pkicheck /f
   ```
   **Expected:** CRL `Verified` and `Leaf certificate revocation check passed`. **This** result is the
   one that matters for login. Your own session's result is secondary.
4. **Ignore `ldap://` lines.** If the certificate also lists `ldap://` CDP/AIA URLs, errors like
   `ERROR_BAD_NET_RESP` on those are harmless when an `http://` URL is `Verified`.

**Expected:** Step 2 passes. Under *Certificate CDP*, the CRL shows `Verified`. Last line: `Leaf
certificate revocation check passed`.

**OCSP failing while the CRL works.** Windows tries OCSP first and **falls back to the CRL**. If the
CRL is `Verified` and the output ends with *revocation check passed*, an OCSP failure does **not**
stop the login. Fix it anyway for speed:
- The OCSP host is usually a **different name** (e.g. `ocsp.acme…`) from the CRL host. Allow it
  on the proxy/firewall too.
- OCSP is plain `http://`, often sent as **POST** with `Content-Type: application/ocsp-request`.
  Some proxies block or rewrite that. Ask the proxy team to allow it to the OCSP host.
- The **intermediate** CA's revocation is checked too: its CRL (published by the root CA) must also
  be reachable. Check every CDP URL in the `certutil` output, not only the user certificate's.
- **Testing OCSP with a plain web request is misleading.** An OCSP responder only answers real OCSP
  requests. A browser-style GET to its URL usually returns `400`/`405`, and that means **reachable**.
  Only a proxy error (Squid `403 ERR_ACCESS_DENIED`), a timeout or `12007` means blocked. Real test, in
  Git Bash, with the user and issuing-CA certificates as PEM:
  ```bash
  openssl x509 -inform DER -in user.cer -out user.pem
  openssl ocsp -issuer ext-intermediate.pem -cert user.pem \
    -url http://<ocsp-host>/<path> -proxy 10.x.x.x:3128 -noverify -resp_text | grep -E 'Cert Status|Response Status'
  ```
  **Expected:** `OCSP Response Status: successful` and `Cert Status: good`. `-proxy` needs OpenSSL 3.x
  (`openssl version`).

## Done when

- [ ] Root in Trusted Root, intermediate(s) in Intermediate CAs, Local Computer, on every PVWA server
- [ ] No non-self-signed certificates in Trusted Root
- [ ] `certutil -verify -urlfetch user.cer` succeeds on every PVWA server

## If it fails

| You see | Fix |
|---|---|
| `CERT_TRUST_IS_UNTRUSTED_ROOT` | Root missing or in the wrong store (Step 1) |
| `CERT_TRUST_IS_PARTIAL_CHAIN` | Intermediate missing (Step 1) |
| `CERT_TRUST_REVOCATION_STATUS_UNKNOWN` / `IS_OFFLINE_REVOCATION` | CRL/OCSP not reachable (Step 3) |
| `could not be resolved` / `0x80072ee7` (12007) | WinHTTP proxy not set; a PowerShell or web.config proxy doesn't count (Step 3) |
| WinHTTP test `200` and the SYSTEM test passes, but `certutil` in your own session gives `12007` | Not a problem for login. Your session uses **your user's** proxy settings and URL cache, while IIS uses the machine ones. To make your session work too: set the proxy in Internet Options → Connections → LAN settings, then `certutil -urlcache * delete` |
| CRL `Verified`, OCSP failed, check **passed** | Not blocking: Windows fell back to the CRL. Allow the OCSP host on the proxy when convenient |
| `CERT_TRUST_IS_REVOKED` | The certificate really is revoked. Reissue |
