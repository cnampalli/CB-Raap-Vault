# 11 — Choosing a future-proof certificate login for PVWA (analysis)

**Status:** analysis for a decision. Nothing here has been changed on any server yet.
**Context:** PKIPN works today (chunks 01–09). Chunk 10 shows it doesn't use Microsoft strong mapping.
The question is whether that matters, and which option to build on.

## Summary

| | |
|---|---|
| **Is strong mapping a firm requirement?** | **Not from Microsoft.** KB5014754 governs Windows logons only. Whether **you** need it is a risk decision: it protects against one specific threat (below). If your security policy says *"an authentication certificate must be bound to exactly one account by an identifier the user or an admin can't simply edit"*, it is firm. Otherwise it is a strong "should" for a privileged-access system |
| **Most future-proof** | **B — PVWA SAML with an identity provider that does the certificate login** (Microsoft Entra certificate-based authentication with high-affinity binding, AD FS, or CyberArk Identity). It is the direction both CyberArk and Microsoft are going, works off-network, and the strong binding and MFA policy live in one place |
| **Option A (Windows logon by smart card + PVWA Windows authentication)** | Gives real KB5014754 enforcement, but it is a **forest-wide** change (trusting the external CA for Windows logon) to protect **one** web app, needs domain-joined, on-network devices, and the card is no longer checked at each PVWA login. Worth it **if** smart-card logon to Windows is wanted anyway. A lab trial plan is below |
| **Option C (custom module)** | Possible, roughly **4–8 weeks** elapsed and re-testing every PVWA upgrade. Least future-proof. Only if A and B are both ruled out |
| **Option D (PKIPN + hardening)** | Keep as the **baseline now**, whatever you choose. Most of it is already done. Add the two AD controls listed in section 2 |

**Suggested path:** D now (hardening, days) → decide A vs B with the questions in section 3 →
lab-trial the chosen one (plan in section 5 for A).

## 1. Why strong mapping exists

A **weak** mapping says *"this certificate belongs to whoever has the name inside it"* (UPN, e-mail,
subject). The 2022 vulnerabilities behind KB5014754 (CVE-2022-26923, CVE-2022-26931, CVE-2022-34691)
abused exactly that: someone who can **change a name attribute** on an account (its UPN or DNS name),
or who can get a certificate **issued with a chosen name**, ends up with a certificate that maps to
**another** account.

A **strong** mapping ties the account to **this specific certificate** (issuer + serial number, key
identifier, or the account's SID inside the certificate). Renaming accounts, or getting a different
certificate with the same name, no longer works.

## 2. Does that threat apply to your PVWA?

PKIPN decides *"who is this?"* from the UPN text in the certificate. So the risk is anything that lets
a certificate's UPN point at the wrong person.

| # | Attack path | Today | With strong mapping |
|---|---|---|---|
| 1 | Certificate with someone else's UPN from **another CA** the server trusts (e.g. a misconfigured internal AD CS template that lets users choose their SAN) | ✅ **Blocked**: `ClientAuthTrustMode` = 2 lets only the external CA through IIS, and `PKIAuthorizedIssuer` lets only its issuing CA through PVWA | Blocked |
| 2 | The **external CA** issues a certificate with someone else's UPN (an error or fraud in its enrolment process) | ⚠️ **Open**: PKIPN trusts the CA's UPN | Blocked: that certificate isn't mapped to the victim |
| 3 | Someone who can **edit `userPrincipalName`** in AD (helpdesk, OU admins) gives an account the UPN on *their own* certificate, so it now resolves to that account (most relevant for LDAP users created on first login) | ⚠️ **Open** | Blocked: the mapping is on the account, tied to one certificate |
| 4 | Stolen smart card + PIN | Open (strong mapping doesn't help) | Open: card PIN policy, revocation |
| 5 | Revoked certificate still used | Covered if *Verify Client Certificate Revocation* is **Enabled** on the binding (it was **Disabled** in the 17 Nov report: check 03 Step 1) | Same |

**Hardening for D, do now (no strong mapping needed):**
1. Binding revocation check **on** (03 Step 1); `ValidatePKICertificate` = Yes (04 Step 4).
2. **Who can write `userPrincipalName`** on the accounts in your CyberArk-mapped AD groups: limit it to
   tier-0/identity admins, and **alert** on changes (Security event **5136**, attribute
   `userPrincipalName`, on the DCs). This closes most of path 3.
3. LDAP mapping: provision Vault users only from a **dedicated AD group** (not a whole OU), so a new
   or renamed account can't be auto-created into the Vault just by having a matching UPN.
4. Ask the external CA (written answer): how is the UPN verified before they issue? That's your
   evidence for path 2.

## 3. Is it a firm requirement? Questions that decide it

| Question | If "yes" |
|---|---|
| Does your security policy, or an assessor, require certificates to be **bound per account** (not by name)? | Firm: A, B (high-affinity) or C |
| Is smart-card logon **to Windows** with these cards planned anyway (desktop, servers, jump hosts)? | A becomes cheap: the mapping work is needed for Windows anyway |
| Do PVWA users ever connect from **non-domain or off-network** devices? | A doesn't work for them; B or D |
| Do you already run an identity provider (Entra ID, AD FS, CyberArk Identity) for SAML? | B is the natural choice |
| Must the **card be present at each PVWA login** (not only at Windows logon)? | Favour B or D; A only checks the card when the user logs on to Windows |

## 4. Options compared

| | **A. Windows smart-card logon + PVWA Windows auth** | **B. SAML + IdP certificate login** | **C. Custom module** | **D. PKIPN + hardening** |
|---|---|---|---|---|
| Strong mapping | ✅ Enforced by DCs | ✅ IdP high-affinity binding | ✅ Your code | ❌ |
| Card checked at each PVWA login | ❌ Only at Windows logon (SSO after) | ✅ (per IdP session policy) | ✅ | ✅ |
| Off-network / non-domain devices | ❌ | ✅ | ✅ | ✅ |
| Blast radius of the change | **Forest**: external CA added to NTAuth, root on every DC and client, CRL reachable from every DC | IdP + PVWA | PVWA only | PVWA only |
| Per-certificate mapping upkeep | Yes, on every card renewal (unless the CA can embed the SID, below) | Yes for high affinity (same idea, in the IdP) | Yes | No |
| Supported by vendors | ✅ Microsoft + CyberArk (Windows auth) | ✅ Both | ⚠️ Your code; check with CyberArk | ✅ |
| Future-proof | Medium: depends on Kerberos (fine), on-network devices (narrowing) | **High** | Low | Medium (baseline) |
| Rough effort | 2–4 weeks incl. approvals, then ongoing mapping upkeep | 2–6 weeks, depending on the IdP you have | 4–8 weeks, plus every upgrade | Days |

**Per-certificate upkeep, and how it could go away.** External certificates carry no AD SID, so A and
B need one mapping per certificate (`X509:<I>…<SR>…`), redone at every renewal. Microsoft added a
second way to carry the SID: a SAN URL, `tag:microsoft.com,2022-09-14:sid:<SID>` (announced 2023;
Intune uses it). A **third-party CA can include it**, unlike the AD CS-only SID extension. Check the
current status on the KB5014754 page. If your external CA can add it at enrolment, Windows logon (option A)
needs **no** per-certificate upkeep. Ask them. Otherwise, script the mapping at card issuance:
`strongmap-evidence.ps1 -Part Cert` already prints the exact `Set-ADUser` line.

## 5. Option A: what it takes, and a lab trial

### What changes

| Where | Change | Why |
|---|---|---|
| **AD (forest)** | Publish the external **issuing** CA to NTAuth: `certutil -dspublish -f ext-issuing-ca.cer NTAuthCA` | DCs only accept logon certificates from NTAuth CAs. This is forest-wide: safe only **because** DCs enforce strong mapping, so an unmapped certificate from that CA can't log anyone on |
| **DCs** | External root/issuing CA in Trusted Root/Intermediate (GPO, right stores!); WinHTTP proxy so they reach the external CRL (02 Step 4, on every DC) | DCs validate the user certificate and its revocation |
| **DCs** | A valid KDC (Kerberos Authentication) certificate from the internal CA | Clients check the DC during smart-card logon |
| **AD (per user)** | `altSecurityIdentities` strong mapping per certificate (or the SID SAN URL from the CA) | KB5014754 Full Enforcement |
| **Workstations** | Smart-card middleware; external root/intermediate trusted (GPO) | Smart-card logon |
| **PVWA** | IIS **Windows Authentication** on `PasswordVault/api/auth/windows/logon`; `windows` method enabled in PVWA; SPN `HTTP/<pvwa fqdn>` on the account that runs the app pool (or the load-balancer name's service account); PVWA URL in the browsers' *Local intranet* / Kerberos allow-list | So the browser uses Kerberos (not NTLM, which Microsoft is retiring) |
| **PVWA servers** | Users allowed *"Access this computer from the network"* (the PVWA hardening GPO removes it by default) | Otherwise Windows auth fails for non-admins |
| **Vault** | Check which name PVWA Windows auth sends (`DOMAIN\user`, `user` or UPN) against the LDAP mapping's *UserLogonName* (now `userPrincipalName`) | A mismatch = "user not found". **Test this first** |

### Phase 0 — readiness checks (read-only, an afternoon)

| Check | ⌨ Command (where) | Good looks like |
|---|---|---|
| External CA in NTAuth? | `certutil -enterprise -store NTAuth` (any domain machine) | Lists the internal CA; the external issuing CA isn't there **yet** |
| DC Kerberos certificates OK | `certutil -dcinfo verify` | Every DC: a valid certificate, chain OK |
| DC enforcement mode | `reg query HKLM\SYSTEM\CurrentControlSet\Services\Kdc /v StrongCertificateBindingEnforcement` (each DC) | `0x2`, or not set (default is Full Enforcement on current updates) |
| DCs can check the external CRL | 02 Step 4 SYSTEM test, **on a DC**, with `user.cer` | `revocation check passed` |
| Card visible on a workstation | `certutil -scinfo` (workstation, card inserted) | The login certificate, with private key |
| PVWA SPN | `setspn -Q HTTP/<pvwa fqdn>` | One account, and it's the app pool / service account |
| PVWA Windows auth folder | 08 report, `sslFlags` list shows `auth/windows` | Folder exists (it does on MPCUVN2004) |

### Phase 1 — one test user, one workstation (lab or approved pilot)

1. Change approval for NTAuth (forest-wide). Publish the external issuing CA; `gpupdate` on the test
   workstation and a DC; check with `certutil -enterprise -store NTAuth`.
2. ⌨ Map the test user strongly: `strongmap-evidence.ps1 -Part Cert -UserCert C:\temp\user.cer`, then
   run the `Set-ADUser … altSecurityIdentities …` line it prints.
3. 🖱 Smart-card logon to the test workstation. ⌨ `klist`. **Expected:** a TGT for the user.
4. ⌨ `strongmap-evidence.ps1 -Part Dc -SamAccountName <user> -SinceMinutes 15`. **Expected:**
   `with a certificate (PKINIT): 1` or more. Evidence the DC did the certificate logon.
5. **Negative test (proves strong mapping is enforced):** remove the mapping
   (`Set-ADUser <user> -Remove @{altSecurityIdentities='<string>'}`), log off, smart-card logon again.
   **Expected:** refused, and a KDC strong-mapping event on the DC (`-Part Dc` lists it). Put the
   mapping back.
6. PVWA: enable Windows authentication (IIS + PVWA method), open the PVWA from the test workstation,
   choose *Windows*. **Expected:** logged in without a prompt. Check the PVWA log (09 section 4) for
   the user name sent to the Vault, and that it matches the Vault user.
7. Keep every report: they are the evidence for the go/no-go.

**Stop if:** the DCs can't reach the external CRL (every logon would fail), NTAuth isn't approved, or
the name PVWA Windows auth sends can't be made to match the Vault user.

## 6. Option C: effort, if you go there

| Step | Effort (rough) |
|---|---|
| Confirm with CyberArk that the custom authentication interface is supported for this use, and get its documentation. `strongmap-evidence.ps1 -Part Module` shows the interface CustomPKIPN implements, to size it | 1–2 weeks elapsed |
| Build: .NET Framework class library. Read the certificate, compute Issuer+Serial / SKI, search AD `altSecurityIdentities`, return that account's UPN, refuse otherwise; logging; timeouts | 5–10 days |
| Security review / penetration test of the module | 1–2 weeks |
| Deploy to every PVWA server; test | 2–3 days |
| **Ongoing:** re-test on every PVWA upgrade; you own the code and its bugs; mapping upkeep as for A/B | 2–3 days per upgrade |

Total roughly **4–8 weeks elapsed**, ~15–25 person-days, plus ongoing ownership. It is the only option
that keeps PKIPN's "card at every login, works anywhere" **and** adds strong mapping without an IdP,
but it is also the one most likely to break when CyberArk changes PVWA.

## Sources

- Microsoft: [KB5014754](https://support.microsoft.com/help/5014754); [Preview of SAN URI for certificate strong mapping](https://techcommunity.microsoft.com/blog/AskDS/preview-of-san-uri-for-certificate-strong-mapping-for-kb5014754/3789785); [Implementing strong mapping in Intune](https://techcommunity.microsoft.com/t5/intune-customer-success/support-tip-implementing-strong-mapping-in-microsoft-intune/ba-p/4053376)
- Citrix: [How KB5014754 affects FAS (third-party CAs need the SID)](https://support.citrix.com/external/article/CTX695393/citrix-federated-authentication-service.html)
- Bulwarx: [CyberArk PAS — Windows Authentication doesn't work](https://support.bulwarx.com/support/solutions/articles/17000093133--cyberark-pas-windows-authentication-doesn-t-work) (applicationHost.config entry; *Access this computer from the network* in the PVWA hardening GPO)
- [CyberArk Windows authentication in PVWA (community blog)](https://luckyfusion.blogspot.com/2025/08/cyberark-windows-authentication-in-pvwa.html)
- Chunk 10 of this guide, and its sources
