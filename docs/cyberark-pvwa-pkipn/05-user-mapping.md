# 05 — Map the certificate to the Vault user

**Who:** CyberArk admin · **Needs:** the `Principal Name` from [chunk 01](01-user-certificate.md)
**Gives:** the certificate's UPN finds exactly one Vault user

**In short:** the Vault user name must be **exactly** the certificate's Principal Name
(`user@domain`). If your Vault uses short names (`jdoe`), change the LDAP mapping or use the alternate
name option.

## How the name is matched

```
Certificate: Principal Name = jdoe@corp.example.com
        │  PVWA (PKIPN) sends this name to the Vault
        ▼
Vault: is there a user called "jdoe@corp.example.com"?
        ├─ yes ─► that user logs in
        └─ no  ─► Vault searches AD (LDAP provisioning), via the directory mapping, for an account whose
                  UserLogonName attribute = jdoe@corp.example.com
                     ├─ mapping uses userPrincipalName ─► found, user created, logs in ✅
                     └─ mapping uses sAMAccountName ───► not found ❌ (AD has "jdoe" there)
```

So **yes, an LDAP user is the normal case.** Two things must be true:
1. In **AD**, the user's `userPrincipalName` equals the certificate's Principal Name (check below).
2. In **PVWA**, the LDAP directory mapping's **UserLogonName** is `userPrincipalName`, so the Vault
   user name is the UPN too.

## Step 1 — Compare the names

1. ⌨ AD value (on any domain-joined server with the AD PowerShell module, or ask the AD team):
   ```powershell
   Get-ADUser -Filter "userPrincipalName -eq 'jdoe@corp.example.com'" -Properties userPrincipalName |
     Format-List SamAccountName, UserPrincipalName, Enabled, DistinguishedName
   ```
   **Expected:** exactly one user, `Enabled : True`. Note the `DistinguishedName`: the LDAP mapping
   must cover that branch.
2. 🖱 PVWA → **Users** (or *Administration* ► *Users and groups*) → search for the user. Note the
   **user name** exactly, if the user exists already.
3. 🖱 PVWA → *Administration* ► *LDAP Integration* → the directory → the mapping → note
   **UserLogonName**.

| AD `userPrincipalName` | Mapping *UserLogonName* | Vault user name | Result |
|---|---|---|---|
| = certificate Principal Name | `userPrincipalName` | `jdoe@corp.example.com` (or not created yet) | ✅ Works. Go to Step 3 |
| = certificate Principal Name | `sAMAccountName` | `jdoe` | ❌ Not found. Step 2 |
| ≠ certificate Principal Name | any | any | ❌ Fix the UPN in AD (AD team), or reissue the certificate |
| no AD user found | any | none | ❌ Wrong domain, or the user isn't in AD. Check with the AD team |

## Step 2 — If the mapping uses `sAMAccountName`

Pick **one**:

**A. Log in LDAP users by UPN.** 🖱 PVWA → **Administration** ► **LDAP Integration** → the directory →
**Directory mapping / profile** → in *Properties*, change **UserLogonName** from `sAMAccountName` to
**`userPrincipalName`** → **Save**.
> ⚠ This makes **new** Vault users (`jdoe@corp…`). The Vault does **not** link them to the existing
> `jdoe` users. Safe permissions granted through **LDAP groups** carry over. Permissions granted to
> the **user directly** do **not**: re-grant them. Agree this with the Vault owners first.

**B. Keep the existing names.** The 14.6 PKI page describes a web.config `<appSettings>` option to
authenticate "with the same Principal Name but with a different Logon Name". 📋 Copy it from that
page ([chunk 04](04-pvwa-pkipn-method.md) link). A community guide names the key `UsePKIPNAlternateUserName`; use it only if
the 14.6 page shows the same name. Use this when changing to UPN names (A) isn't acceptable.

## Step 3 — The Vault user can log in

🖱 Open the user in PVWA:
- **Disabled**: No. **Suspended**: No. Not expired.
- Authorized from the PVWA's network area (if your Vault uses network areas / *Authorized
  interfaces*: include **PVWA**).
- For LDAP users: the directory mapping that creates them is the one with the matching UPN setting.

**Expected:** an active user whose name equals the certificate's Principal Name.

> PVWA logs certificate users in to the Vault **on their behalf** through its own gateway user
> (typically `PVWAGWUser`). If that account is locked or its credential file is stale, every
> certificate login fails at this stage, while CyberArk password logins may still work. See [chunk 07](07-troubleshooting.md), Stage 5.

## Done when

- [ ] Vault user name = certificate Principal Name for the test user
- [ ] User active and allowed through the PVWA
