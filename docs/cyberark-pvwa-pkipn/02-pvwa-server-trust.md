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

1. ⌨ Is a proxy needed? `netsh winhttp show proxy`. Revocation checks use the **machine** (WinHTTP)
   proxy, not the browser's.
2. 🖱 If `certutil -urlfetch` showed failures: open the firewall/proxy for the CDP and AIA/OCSP URLs
   from **every** PVWA server, or set the proxy:
   `netsh winhttp set proxy proxy-server="proxy.corp:8080" bypass-list="*.corp.example.com"`.
3. ⌨ Re-run Step 2.

**Expected:** Step 2 passes with all URLs `Verified`.

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
| `CERT_TRUST_IS_REVOKED` | The certificate really is revoked. Reissue |
