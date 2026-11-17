# 07 — Troubleshooting

Work through the stages **in order**. Each one depends on the one before it. Stop at the first that
fails.

## Collect first (2 minutes, on the PVWA server that served the attempt)

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
| **`403.16`** | Client certificate untrusted or invalid | Root not in Local Computer *Trusted Root*; intermediate missing; an **intermediate sitting in Trusted Root** (any non-self-signed cert there breaks client auth); or a CTL on the binding that lacks the external CA. Chunk 02 Step 1, chunk 03 Step 1 |
| **`403.13`** | Revoked, **or the CRL couldn't be downloaded** | Usually the PVWA server can't reach the external CA's CRL/OCSP (proxy/firewall). Chunk 02 Step 3. To confirm only: turn off *Verify Client Certificate Revocation* on the binding, test, **turn it back on** |
| **`403.17`** | Expired / not yet valid | Reissue; check the clocks |
| `403.12` | Mapping denied | IIS client-certificate mapping is configured on the site. Remove it; PKIPN does the mapping |

> "I already trusted the CA" usually means it was imported into the **Current User** store, or into
> one PVWA server only, or the intermediate went into *Trusted Root*. Check with `certlm.msc`
> on **each** server.

## Stage 4 — Does PVWA read a UPN from the certificate?

Seen as: the certificate prompt succeeds (IIS log `200` on the pkipn request), then PVWA shows an
authentication error.

| Cause | Fix |
|---|---|
| No `Principal Name` in the SAN (external certs often carry only e-mail) | Reissue with a UPN SAN (chunk 01) |
| PKIPN module not loaded: DLL missing on **this** PVWA server, or web.config edited in `Env` instead of `Bin` | Chunk 04 Step 2 on every server |
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
