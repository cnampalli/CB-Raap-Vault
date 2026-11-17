# CyberArk PVWA — PKIPN certificate login (Self-Hosted 14.6)

Users sign in to the **PVWA web UI** with a certificate, from a smart card or the Windows certificate
store. **PKIPN** reads the **Principal Name (UPN)** from the certificate and logs the user in to the
Vault as the matching user. Plain **PKI** matches the certificate's Subject DN instead.

This setup has **two different CAs**:

| Certificate | Issued by | Who must trust its CA |
|---|---|---|
| PVWA web server certificate (HTTPS) | **Internal** CA | Users' **browsers / workstations** |
| User's login certificate (PKIPN) | **External** provider | The **PVWA server** (IIS / Windows) |

These are two separate trust directions. Trusting one CA does nothing for the other.

## How a login works (and where it breaks)

```
Browser ──TLS──► IIS on PVWA ──► PVWA app (PKIPN) ──► Vault
  │ 1 trusts PVWA's     │ 2 asks for a client cert     │ 4 reads the UPN     │ 5 user with that
  │   internal-CA cert  │ 3 builds the chain to the    │   from the cert's   │   name exists,
  │                     │   external root and checks   │   SAN               │   enabled, allowed
  │                     │   revocation (CRL/OCSP)      │                     │
```

| Stage | Fails as | Chunk |
|---|---|---|
| 1 | Browser warning on the PVWA page | 02 |
| 2 | No certificate prompt; `403.7` | 03, 04 |
| 3 | `403.16` (untrusted), `403.13` (revoked / CRL unreachable), `403.17` (expired) | 02, 03 |
| 4 | PVWA error after the prompt; user not identified | 01, 05 |
| 5 | PVWA "user not found / suspended / not authorized" | 06 |

## Chunks

| # | Chunk | Who |
|---|---|---|
| 01 | [Check the user certificate](01-user-certificate.md) | PKI / you |
| 02 | [PVWA server trust and revocation](02-pvwa-server-trust.md) | Windows admin on each PVWA server |
| 03 | [IIS: ask for client certificates](03-iis-client-certificates.md) | Windows admin on each PVWA server |
| 04 | [Enable PKIPN in PVWA](04-pvwa-pkipn-method.md) | CyberArk admin |
| 05 | [Map the certificate to the Vault user](05-user-mapping.md) | CyberArk admin |
| 06 | [Test end to end](06-test.md) | CyberArk admin + a test user |
| 07 | [Troubleshooting](07-troubleshooting.md) | All |

**Already set up and it doesn't work?** Go to [07 — Troubleshooting](07-troubleshooting.md). It
walks the five stages in order.

## Before you start

- [ ] Admin access to **every** PVWA server (each one is configured separately)
- [ ] CyberArk admin in PVWA (Administration ► Options)
- [ ] One test user's certificate (public `.cer`), and that user on a test workstation
- [ ] The external CA's root and intermediate certificates (`.cer`)
- [ ] The CyberArk 14.6 doc page open in a browser:
      [PKI authentication (Personal Certificate) for the PVWA](https://docs.cyberark.com/pam-self-hosted/14.6/en/content/pas%20inst/pki-authentication-personal-certificate.htm).
      Chunk 04 tells you which lines to copy from it.
- [ ] A change window: IIS restarts in chunk 03

🖱 = manual step. ⌨ = command (PowerShell or Command Prompt on the PVWA server unless stated).

## Sources

- CyberArk: [PKI authentication (Personal Certificate) for the PVWA](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/pki-authentication-personal-certificate.htm) (PKIPN DLL, `pkipn` method, `ValidatePKICertificate`, issuer validation, TLS 1.3, `UserLogonName`)
- CyberArk: [How users authenticate to PAM - Self-Hosted](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/authenticating-to-the-privileged-account-security-solution.htm)
- CyberArk: [Set up customized authentication modules](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/setting-up-customized-authentication-modules.htm)
- CyberArk Community: [PVWA — HTTP 403.13 with PKI authentication](https://community.cyberark.com/s/article/00004950) and [How to enable UPN login for LDAP in PVWA](https://community.cyberark.com/s/article/How-to-enable-UPN-login-for-LDAP-in-PVWA)
- Microsoft: [IIS 403.7 client certificate errors](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/iis/www-authentication-authorization/errors-403-7-reject-client-certificate-rquest) and [Troubleshooting client certificate issues](https://learn.microsoft.com/en-us/archive/blogs/saurabh_singh/client-certificate-revisited-how-to-troubleshoot-client-certificate-related-issues)
