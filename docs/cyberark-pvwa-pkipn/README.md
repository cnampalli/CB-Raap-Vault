# CyberArk PVWA — certificate login (PKI / PKIPN), Self-Hosted 14.6

Users log in to the **PVWA web page** with a certificate (smart card or Windows certificate store)
instead of a password.

- **PKIPN** reads the **Principal Name (UPN)** from the certificate, e.g. `jdoe@corp.example.com`,
  and logs in the Vault user with **that exact name**.
- **PKI** (plain) identifies the user from the certificate's Subject instead.

## Start here: pick your path

| Your situation | Do this |
|---|---|
| **It was set up before (maybe by someone else) and doesn't work** | 1. [08 — Check an existing setup](08-check-existing-setup.md) (tick-box list) → 2. fix what fails → 3. [06 — Test](06-test.md). Stuck? [07 — Troubleshooting](07-troubleshooting.md) and [09 — Debug logging](09-debug-logging.md) |
| **New setup** | Chunks [01](01-user-certificate.md) → [06](06-test.md) in order |
| **One login just failed and you want to know why** | Run [`tools/pkipn-collect.ps1`](tools/pkipn-collect.ps1) (09), then [07](07-troubleshooting.md) |

## Five words you need

| Word | Meaning |
|---|---|
| **Root CA** | The top certificate authority. Its certificate is *self-signed* (Issued to = Issued by). Goes in **Trusted Root Certification Authorities** |
| **Intermediate / sub-CA** | A CA signed by the root. Goes in **Intermediate Certification Authorities**. **Never** in Trusted Root |
| **`certlm.msc`** | The **computer's** certificate stores. IIS uses these. (`certmgr.msc` is your user's stores: wrong place) |
| **UPN / Principal Name** | The `user@domain` name inside the certificate. PKIPN logs in the Vault user with this name |
| **IIS sub-status** | The number after `403` in the IIS log, e.g. `403 16`. It tells you which stage failed (table below) |

## Two CAs, two directions

| Certificate | Issued by | Who must trust that CA |
|---|---|---|
| PVWA **web page** certificate (HTTPS) | **Internal** CA | Users' **workstations** |
| User's **login** certificate | **External** CA | The **PVWA servers** (IIS) |

Trusting one CA does nothing for the other.

## How a login works, and where it breaks

```
Browser ──► IIS on the PVWA server ──► PVWA (PKI / PKIPN) ──► Vault
 1 trusts the        2 asks for a cert       4 reads the UPN        5 finds the user
   PVWA page         3 checks the cert         from the cert          with that name
                       (trust + revocation)
```

| Stage | Fails as | Fix in |
|---|---|---|
| 1 | Browser warning on the PVWA page | 06 Step 1 |
| 2 | No certificate prompt; IIS `403 7` | 03 |
| 3 | IIS `403 16` (not trusted), `403 13` (revoked / CRL unreachable), `403 17` (expired) | 02 |
| 4 | IIS `200`, then a PVWA error | 04, 01 |
| 5 | PVWA "user not found / suspended / not authorized" | 05 |

## Chunks

| # | Chunk | Who |
|---|---|---|
| 01 | [Check the user certificate](01-user-certificate.md) | PKI team / you |
| 02 | [PVWA server: trust the external CA](02-pvwa-server-trust.md) | Windows admin, each PVWA server |
| 03 | [IIS: ask for the certificate](03-iis-client-certificates.md) | Windows admin, each PVWA server |
| 04 | [Turn on PKIPN in PVWA](04-pvwa-pkipn-method.md) | CyberArk admin |
| 05 | [Match the certificate to the Vault user](05-user-mapping.md) | CyberArk admin |
| 06 | [Test end to end](06-test.md) | CyberArk admin + test user |
| 07 | [Troubleshooting](07-troubleshooting.md) | All |
| 08 | [Check an existing setup](08-check-existing-setup.md) | Windows + CyberArk admin |
| 09 | [Debug logging](09-debug-logging.md) | Windows admin |
| 10 | [Strong certificate mapping (KB5014754) and PKIPN](10-strong-mapping.md) | Windows + AD + CyberArk admin |
| 11 | [Choosing a future-proof certificate login (analysis)](11-certificate-login-options.md) | Security architect + admins |

Tools (run on each PVWA server, as Administrator; neither changes anything):
- [`tools/pkipn-diagnose.ps1`](tools/pkipn-diagnose.ps1): checks the configuration, `[OK]`/`[WARN]`/`[FAIL]` per item.
- [`tools/pkipn-collect.ps1`](tools/pkipn-collect.ps1): you reproduce one failed login, it collects the logs for that attempt into a zip.
- [`tools/strongmap-evidence.ps1`](tools/strongmap-evidence.ps1): evidence for 10, whether PKIPN uses `altSecurityIdentities` strong mapping (it doesn't).

## Before you start

- [ ] Admin access to **every** PVWA server (each one is set up separately)
- [ ] A CyberArk admin login to PVWA (Administration ► Options)
- [ ] One test user, their certificate as a **public** `.cer` file ([chunk 01](01-user-certificate.md)), and a workstation
- [ ] The external CA's root and intermediate certificates (`.cer`)
- [ ] The CyberArk 14.6 page open:
      [PKI authentication (Personal Certificate) for the PVWA](https://docs.cyberark.com/pam-self-hosted/14.6/en/content/pas%20inst/pki-authentication-personal-certificate.htm).
      Lines marked 📋 must be copied from it word for word.
- [ ] A change window: some steps need `iisreset` or a reboot

**Cross-references** like "02 Step 3" mean *file 02, Step 3*.

🖱 = click in a window. ⌨ = type a command (on the PVWA server, as Administrator, unless stated).
**Expected:** = what you should see. If you don't see it, stop and go to that chunk's *If it fails*.

## Sources

- CyberArk: [PKI authentication (Personal Certificate) for the PVWA](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/pki-authentication-personal-certificate.htm)
- CyberArk: [How users authenticate to PAM - Self-Hosted](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/authenticating-to-the-privileged-account-security-solution.htm)
- CyberArk: [Set up customized authentication modules](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/setting-up-customized-authentication-modules.htm)
- CyberArk Community: [PVWA — HTTP 403.13 with PKI authentication](https://community.cyberark.com/s/article/00004950), [How to enable UPN login for LDAP in PVWA](https://community.cyberark.com/s/article/How-to-enable-UPN-login-for-LDAP-in-PVWA)
- Microsoft: [IIS 403.7 client certificate errors](https://learn.microsoft.com/en-us/troubleshoot/developer/webapps/iis/www-authentication-authorization/errors-403-7-reject-client-certificate-rquest), [Troubleshooting client certificate issues](https://learn.microsoft.com/en-us/archive/blogs/saurabh_singh/client-certificate-revisited-how-to-troubleshoot-client-certificate-related-issues), KB 2802568 (non-self-signed certificates in Trusted Root → `403.16`), [Failed Request Tracing](https://learn.microsoft.com/en-us/iis/troubleshoot/using-failed-request-tracing/troubleshooting-failed-requests-using-tracing-in-iis)
