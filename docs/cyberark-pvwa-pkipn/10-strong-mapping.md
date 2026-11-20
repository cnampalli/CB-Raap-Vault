# 10 — Strong certificate mapping (KB5014754, altSecurityIdentities) and PVWA PKIPN

**Question:** can PVWA PKIPN use Microsoft's *strong certificate mapping* (the `altSecurityIdentities`
attribute), so a certificate only logs in the AD account it is explicitly bound to?

## The short answer

**Not natively.** PKIPN never asks Windows or AD to map the certificate. PVWA reads the UPN out of the
certificate itself and passes that **name** to the Vault, which looks the name up in LDAP. That is an
implicit, name-based mapping. Microsoft calls UPN mappings *weak*. KB5014754 enforcement lives in the
domain controller's certificate logon (Kerberos PKINIT) and in Schannel's certificate-to-account
mapping, and PKIPN uses neither, so it is **not covered by it and can't be switched to it**.

You **can** get strong mapping in front of PVWA another way (Options below), or build a custom module.
The tests below let you prove the "not natively" part on your own servers instead of taking it on trust.

## What strong mapping is (one minute)

Since KB5014754 (May 2022; Full Enforcement from 2025), a **domain controller** accepts a certificate
logon only if the certificate is *strongly* tied to the account:

| Mapping | How the certificate is tied to the account | Strong? |
|---|---|---|
| SID extension in the certificate (OID `1.3.6.1.4.1.311.25.2`) | AD CS writes the user's SID into the certificate | ✅ |
| `altSecurityIdentities` = `X509:<I>`*issuer*`<SR>`*serial* | Issuer + serial number of **this** certificate | ✅ |
| `altSecurityIdentities` = `X509:<SKI>`*key id* | Subject Key Identifier of **this** certificate | ✅ |
| `altSecurityIdentities` = `X509:<SHA1-PUKEY>`*hash* | Hash of the public key | ✅ |
| `X509:<I>…<S>…`, `X509:<S>…`, `X509:<RFC822>…` | Issuer+Subject, Subject, e-mail | ❌ weak |
| UPN / DNS name in the SAN (implicit) | Whoever has that `userPrincipalName` | ❌ weak |

An **external CA** can't put your AD SIDs in its certificates, so for your users strong mapping means
an `altSecurityIdentities` entry per certificate.

## Where it applies, and why PKIPN isn't there

```
Windows smart-card logon / IIS "AD certificate mapping":
  certificate ──► DC (KDC / Schannel mapping) ──► checks altSecurityIdentities / SID  ◄── KB5014754 here
                                                └─► Windows account token

PVWA PKIPN:
  certificate ──► IIS (checks chain + revocation only) ──► PVWA reads "Principal Name"
             ──► Vault: "is there a user called <UPN>?" ──► LDAP search by userPrincipalName
                 (no DC certificate logon, no altSecurityIdentities anywhere)
```

You have already seen one proof: a **local** Vault user with no AD account at all logged in with
PKIPN (07, *Seen on this deployment*). AD can't have mapped a certificate to an account that doesn't
exist.

## Prove it on your servers

All four tests use [`tools/strongmap-evidence.ps1`](tools/strongmap-evidence.ps1). It only reads.
Copy it and the test user's `user.cer` to `C:\temp`. Run PowerShell **as Administrator**.

### Test 1 — PVWA has no strong-mapping code path (on a PVWA server)

⌨
```powershell
cd C:\temp
powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Pvwa
```
**Expected (= "not natively"):**
- `DS Mapper Usage = Disabled` on `0.0.0.0:443`, and `AD cert mapping = False` on every path: IIS
  doesn't map certificates to AD accounts.
- `altSecurityIdentities no` and `X509:< no`: no PVWA assembly contains the attribute name or the
  mapping-string prefix, so none of them can read or compare strong mappings.
- `1.3.6.1.4.1.311.20.2.3 YES` in a PKI module: it identifies users by the UPN in the SAN.

**If** `altSecurityIdentities` or `X509:<` shows `YES`: note which file, and send it to CyberArk
support. That would mean your version has code for it, and this chunk's answer needs revisiting.

### Test 2 — The certificate's strong mapping, and who it points to (any domain-joined machine)

⌨
```powershell
powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Cert -UserCert C:\temp\user.cer
```
**Expected:** the UPN; *No SID extension* (external CA); the two strong mapping strings for this
certificate; `1) Account by UPN … 1 found`; `2) … STRONG mapping … 0 found` (unless someone added
one). Users in another domain: add `-SearchRoot 'LDAP://<dc>/DC=acme,DC=corp,DC=au'`.

### Test 3 — The deciding test: PKIPN logs in without a strong mapping

1. Test 2 shows **`STRONG mapping … 0 found`** for the test user's certificate.
2. 🖱 Log in to PVWA with that certificate (PKIPN), as in 06.
3. **Expected:** the login **works**.

Result: PKIPN accepted a certificate that a domain controller under Full Enforcement would refuse
for the same account. PKIPN does not use strong mapping.

*Optional, stronger:* with two **test** AD accounts A and B, and a certificate whose UPN is A's, add
the certificate's strong mapping string (Test 2 prints it) to **B**. PKIPN still logs in **A**, while
Windows would map the certificate to B. Remove the mapping afterwards.

### Test 4 — No domain controller was involved (needs rights to read DC event logs)

Straight after the Test 3 login:
⌨
```powershell
powershell -ExecutionPolicy Bypass -File .\strongmap-evidence.ps1 -Part Dc -SamAccountName <user's logon name> -SinceMinutes 15
```
**Expected:** `with a certificate (PKINIT): 0` and no KB5014754 KDC events at the time of the
login. If PKIPN used Windows mapping, every DC log would show a 4768 with a certificate issuer.

Keep the four `strongmap-evidence-*.txt` reports: they are your evidence.

## If you need strong mapping: options

| Option | How it works | Strong mapping enforced by | Effort / notes |
|---|---|---|---|
| **A. PVWA "Windows" authentication + smart-card logon to Windows** | Users log on to their workstation with the smart card. The DC checks the certificate (strong mapping enforced). PVWA then uses the user's Kerberos ticket (no certificate at PVWA) | The domain controller (KB5014754) | The external CA must be in AD **NTAuth**, and DCs need KDC certificates; add an `altSecurityIdentities` entry per user certificate (Test 2 prints it). Needs the *Smart Card Logon* EKU (your certificates have it) |
| **B. PVWA SAML + an identity provider doing certificate login** | PVWA trusts the IdP. The IdP (AD FS, or Microsoft Entra certificate-based authentication with *high-affinity* bindings: Issuer+Serial, SKI, public key hash) checks the certificate | The IdP | Uses PVWA's SAML support; the certificate check moves to the IdP. Usually the cleanest if you already have one |
| **C. Custom PVWA authentication module** | A module in `CustomAuthenticationDlls` (the same mechanism as CustomPKIPN) that, after reading the certificate, searches AD for `altSecurityIdentities` = the certificate's Issuer+Serial or SKI, and only then returns that account's UPN | Your code | Development and support burden; check with CyberArk that custom modules are supported for this. `-Part Cert` shows the exact lookup such a module would do |
| **D. Stay on PKIPN, reduce the risk** | Keep the issuer restriction (04 Step 5) on the **one** external issuing CA, `ValidatePKICertificate` = Yes, revocation on (03), and make sure that CA only issues certificates whose UPN belongs to the holder | The external CA's issuance process | No strong mapping, but limits the classic attack (a certificate with someone else's UPN from **any** trusted CA) to that one CA |

**Recommendation:** if strong mapping is a firm requirement, go with **B** (or **A** if smart-card
logon to Windows is already planned); otherwise **D**, and record the risk acceptance. Ask CyberArk
support to confirm for 14.6 (send them the Test 1–4 reports):

> *"Does PVWA 14.6 PKI/PKIPN authentication support Microsoft strong certificate mapping
> (KB5014754 / altSecurityIdentities), or any per-certificate binding to the user account beyond the
> UPN/Subject match? Attached: evidence that no PVWA assembly references altSecurityIdentities and
> that a PKIPN login succeeds without a strong mapping."*

## Sources

- Microsoft: [KB5014754 — Certificate-based authentication changes on Windows domain controllers](https://support.microsoft.com/help/5014754)
- Microsoft: [Alt-Security-Identities (MS-DVRJ)](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-dvrj/f900e812-8f1c-4345-9ab0-b91111068651)
- Samba: [Bug 16001 — altSecurityIdentities X509 issuer DN order is reversed](https://bugzilla.samba.org/show_bug.cgi?id=16001) and [merge request 4422](https://gitlab.com/samba-team/samba/-/merge_requests/4422) (issuer and serial are stored reversed)
- [Strong certificate mapping (KB5014754) in practice](https://www.activedirectoryhardening.com/en/blog/strong-certificate-mapping), [Uwe Gradenegger on KB5014754](https://www.gradenegger.eu/en/changes-to-certificate-issuance-and-certificate-based-logon-to-the-active-directory-with-the-patch-for-windows-server-dated-may-10-2022-kb5014754/)
