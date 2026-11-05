# 02 — AD admin access to TPP

**Who:** Venafi team, AD team, and someone with Windows admin on a TPP server
**Needs:** nothing · **Gives:** an AD login with TPP admin rights (A3a)

**Skip this chunk** if you use a **local** service account, or if you can already sign in to TPP with an
AD account that has admin rights.

## Why this chunk exists

TPP only lets an identity add others **from its own directory**. A local account such as `tpp_admin`
**cannot add an AD user or group** to anything: not folder permissions, and not an API integration's
allowed identities. No setting changes this.

So to give an AD service account rights, you must be signed in **as an AD identity** with admin rights.
This chunk creates that identity, once.

AD accounts never appear in the TPP **Users** list (that list shows local accounts only). You find
them by **searching** in an identity picker.

## Step 1 — Find out what already exists (no changes)

1. 🖱 Ask the Venafi platform team: *"Does anyone sign in to TPP with their AD login today?"*
   If yes, and they have admin rights, ask them to do chunks 04–06 and skip to the end.
2. 🖱 Sign in (RDP) to a TPP server as a Windows administrator. Open **Venafi Configuration Console**
   (VCC) from the Start menu.
3. 🖱 In VCC, click **Connectors** in the left tree. Look for an **Active Directory** connector.
   If there is one, open it and write down its **Search Roots** (the AD OUs TPP can see).
4. 🖱 In VCC, open **Master Admins**. Write down who is listed.

**Expected:** you know which of these is true:

| Finding | Go to |
|---|---|
| No AD connector | Step 2 |
| AD connector, no AD group in Master Admins | Step 3 |
| An AD group is already a Master Admin | Ask to be added to that group in AD, then Step 5 |

## Step 2 — Connect TPP to AD (only if there is no connector)

Done by a **Master Admin** on the TPP server. You need from the AD team: the domain name or domain
controllers, and a read-only LDAP bind account.

1. 🖱 VCC → **Connectors** → **Actions** pane → **Active Directory Connector**.
2. 🖱 Enter the domain / domain controllers and the bind account.
3. 🖱 Add **Search Roots** that cover **both**:
   - the OU that will hold `svc-vault-pki` (chunk 04)
   - the OU that will hold the admin group (Step 3)
4. 🖱 Run **Test** / **Verify** in the wizard, then **Finish**.

**Expected:** the connector is listed under Connectors and the test passes.

## Step 3 — Create the admin group in AD (AD team)

1. 🖱 Open **Active Directory Users and Computers**.
2. 🖱 Right-click an OU **inside a Search Root** → **New** → **Group**.
3. 🖱 Name: `GG-TPP-Vault-Admins` (A3a). Scope: **Global**. Type: **Security**. Click **OK**.
4. 🖱 Open the group → **Members** → **Add** → add **your own AD user** (and any co-admins).
   Do **not** add `svc-vault-pki`. The service account must never be an admin.

**Expected:** the group exists and shows your user under Members.

## Step 4 — Make the group a TPP Master Admin

This is the one place a server administrator can give TPP rights to an AD identity. Master Admin is
platform-wide, so record it in the change ticket (A18).

1. 🖱 On the TPP server, VCC → **Master Admins** → **Add**.
2. 🖱 Search for `GG-TPP-Vault-Admins` and select it → **OK** → **Apply**.

**Expected:** `GG-TPP-Vault-Admins` appears in the Master Admins list.

> If you cannot find a **Master Admins** setting in your VCC version, note the TPP version
> (Help ► About in Aperture) and ask Venafi support for the Master Admin path for that version. Don't
> work around it with `tpp_admin`; that cannot add AD identities.

## Step 5 — Sign in as AD and check

1. 🖱 Sign out of `tpp_admin`.
2. 🖱 Open Aperture (`https://<A1>/aperture`) and sign in as `CORP\<your-user>`.
3. 🖱 Check that the **Platform** menu (API integrations) is visible.
4. 🖱 Open **Policy Tree** → select any folder → **Permissions** → **Add**. Type `svc-vault-pki` in
   the search box. **Do not save.** Close the dialog.

**Expected:**
- You are signed in with your AD account and see the admin menus.
- `svc-vault-pki` shows up as an AD identity in the search. (If chunk 04 isn't done yet, search for
  your own user instead.)

## Done when

- [ ] You can sign in to Aperture with your AD account and see the admin menus
- [ ] AD users can be found in the identity search
- [ ] **From now on, do chunks 04–06 signed in with this AD account, not `tpp_admin`**

## If it fails

| You see | Likely cause | Fix |
|---|---|---|
| AD sign-in rejected | Your OU is not under a Search Root | Add the OU in Step 2 |
| Group not found in Master Admins search | The group's OU is not under a Search Root, or AD hasn't replicated yet | Check Step 2. Wait 15 min |
| Signed in, but no admin menus | Group membership cached, or added after you signed in | Sign out and back in |
| `svc-vault-pki` not found in the search | Its OU is not under a Search Root | Move the account, or add the OU |

## Optional, later — narrow the rights

Once chunks 04–06 are done, you can give `GG-TPP-Vault-Admins` **Admin** on
`\VED\Policy\Certificates\Vault` only, and remove it from Master Admins. Do this only if your TPP version
lets non-Master-Admins manage API integrations. If it doesn't, keep the group small.
