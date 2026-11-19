# 05 — Map the certificate to the Vault user

**Who:** CyberArk admin · **Needs:** the `Principal Name` from chunk 01
**Gives:** the certificate's UPN finds exactly one Vault user

**In short:** the Vault user name must be **exactly** the certificate's Principal Name
(`user@domain`). If your Vault uses short names (`jdoe`), change the LDAP mapping or use the alternate
name option.

PKIPN logs in the Vault user whose **user name equals the certificate's Principal Name**. Check what
your Vault user names look like.

## Step 1 — Compare the names

1. 🖱 PVWA → **Users** (or *Administration* ► *Users and groups*) → find the test user. Note the **user
   name** exactly.
2. 🖱 Compare it with the `Principal Name` from chunk 01.

| Vault user name | Certificate Principal Name | Result |
|---|---|---|
| `jdoe@corp.example.com` | `jdoe@corp.example.com` | ✅ Works. Go to Step 3 |
| `jdoe` (LDAP `sAMAccountName`) | `jdoe@corp.example.com` | ❌ Not found. Step 2 |
| no such user | anything | ❌ Create or provision the user first |

## Step 2 — If the Vault uses `sAMAccountName` names

Pick **one**:

**A. Log in LDAP users by UPN.** 🖱 PVWA → **Administration** ► **LDAP Integration** → the directory →
**Directory mapping / profile** → in *Properties*, change **UserLogonName** from `sAMAccountName` to
**`userPrincipalName`** → **Save**.
> ⚠ This makes **new** Vault users (`jdoe@corp…`). The Vault does **not** link them to the existing
> `jdoe` users. Safe permissions granted through **LDAP groups** carry over. Permissions granted to
> the **user directly** do **not**: re-grant them. Agree this with the Vault owners first.

**B. Keep the existing names.** The 14.6 PKI page describes a web.config `<appSettings>` option to
authenticate "with the same Principal Name but with a different Logon Name". 📋 Copy it from that
page (chunk 04 link). A community guide names the key `UsePKIPNAlternateUserName`; use it only if
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
> certificate login fails at this stage, while CyberArk password logins may still work. See chunk 07, Stage 5.

## Done when

- [ ] Vault user name = certificate Principal Name for the test user
- [ ] User active and allowed through the PVWA
