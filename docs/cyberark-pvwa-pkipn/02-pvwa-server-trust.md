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
| CRL `Verified`, OCSP failed, check **passed** | Not blocking: Windows fell back to the CRL. Allow the OCSP host on the proxy when convenient |
| `CERT_TRUST_IS_REVOKED` | The certificate really is revoked. Reissue |
