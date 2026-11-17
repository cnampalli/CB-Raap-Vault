# 03 — IIS: ask for client certificates

**Who:** Windows admin, on **every** PVWA server · **Needs:** chunk 02 done
**Gives:** the browser is asked for a certificate on the PKIPN login, and IIS accepts it

## Step 1 — Note the HTTPS binding settings

⌨
```cmd
netsh http show sslcert
```
For the PVWA's `0.0.0.0:443` (or `IP:443` / `hostname:443`) entry, note:

| Field | Expect | Why |
|---|---|---|
| **Certificate Hash** | The internal-CA PVWA certificate | Must stay the same when you change the binding |
| **Application ID** | Note it | Needed to recreate the binding |
| **Verify Client Certificate Revocation** | `Enabled` | Keep it on. Turn off only to diagnose, never in production |
| **Ctl Store Name** / **CTL Identifier** | Empty, **or** a CTL that **includes the external CA** | If a CTL is set, IIS accepts only those issuers. A CTL without the external CA → `403.16` |
| **Negotiate Client Certificate** | See Step 3 | Needed for TLS 1.3 |

## Step 2 — Require client certificates on the PKI login path only

1. 🖱 **IIS Manager** → *Sites* → the PVWA site (e.g. *Default Web Site*) → **PasswordVault** →
   expand down to the PKI authentication folder. Community guides name **`auth` → `pki`**. If an
   `auth` → `pkipn` folder also exists, set both. The diagnostic script (chunk 07) lists the folders
   that exist on your server and their current setting.
2. 🖱 Select that folder → **SSL Settings** → tick **Require SSL** → **Client certificates:
   Require** → **Apply**.
3. 🖱 Leave the rest of `PasswordVault` on **Ignore**. Otherwise every PVWA page asks for a certificate,
   which breaks CyberArk / LDAP logins and the other components.
4. ⌨ `iisreset`

**Expected:** only the PKI folder shows *Require*.

## Step 3 — TLS 1.3 (Windows Server 2022 and later)

IIS asks for a folder-level client certificate **after** the TLS handshake. TLS 1.3 needs
post-handshake authentication for that, and browsers don't do it. Result: no certificate prompt, or
a connection reset or `403.7`, with TLS 1.3 only.

Pick **one**:
- **A. Ask for the certificate during the handshake** (CyberArk's documented fix). ⌨ Recreate the
  binding with the **same** hash and app ID from Step 1:
  ```cmd
  netsh http delete sslcert ipport=0.0.0.0:443
  netsh http add sslcert ipport=0.0.0.0:443 certhash=<hash> appid={<app-id>} certstorename=MY clientcertnegotiation=enable
  netsh http show sslcert
  ```
  **Expected:** *Negotiate Client Certificate: Enabled*. Side effect: browsers may offer a
  certificate as soon as the PVWA page opens. Users who log in another way press **Cancel**.
- **B. Turn off TLS 1.3 on the server** (Schannel registry or your hardening tool). Then TLS 1.2
  renegotiation works as before.

⌨ `iisreset` afterwards.

## Done when

- [ ] Client certificates *Require* on the PKI folder only, on every PVWA server
- [ ] Binding: revocation check enabled; no CTL, or a CTL that includes the external CA
- [ ] TLS 1.3 handled (A or B) if the server supports TLS 1.3
