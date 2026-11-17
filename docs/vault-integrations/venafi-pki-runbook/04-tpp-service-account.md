# 04 — Service account

**Who:** Venafi team (AD team for option A) · **Needs:** chunk 02 if AD · **Gives:** A3 `svc-vault-pki`

Vault uses this account **only once a year**, when its tokens are first issued (chunk 11). After that,
Vault runs on refresh tokens. The password stays with the Venafi team.

Pick **one** option.

## Option A — AD account (recommended where policy requires AD)

1. 🖱 AD team: **Active Directory Users and Computers** → right-click an OU **inside a TPP Search
   Root** (chunk 02) → **New** → **User**.
2. 🖱 User logon name: `svc-vault-pki`. Set a strong password.
3. 🖱 Password expiry follows your service-account policy. If it expires, live tokens keep working,
   but the yearly re-connect (chunk 16) will fail until it is reset.
4. 🖱 Block interactive logon in AD (GPO: *Deny log on locally* and *Deny log on through Remote
   Desktop*). Don't restrict network logon. TPP must still be able to check the password.
5. 🖱 Member of: **Domain Users only**. No group that has rights in TPP.
6. 🖱 Store the password in your PAM vault.

**Expected:** the account exists, and in Aperture (signed in as your **AD** admin, chunk 02 Step 5)
`svc-vault-pki` appears in an identity search.

## Option B — Local TPP account

1. 🖱 Sign in to Aperture as `tpp_admin`.
2. 🖱 Open the **Users** list (local identities) → **Add**.
3. 🖱 Username `svc-vault-pki`, strong password. No group membership.
4. 🖱 Store the password in your PAM vault.

**Expected:** `svc-vault-pki` appears in the Users list.

> With a local account, do chunks 05–06 as `tpp_admin` or another local admin. With an AD account,
> do them as your AD admin.

## Step — Check it holds no rights

1. 🖱 Aperture → **Policy Tree** → select `\VED\Policy` → **Permissions** → **Effective
   permissions** → choose `svc-vault-pki`.

**Expected:** no rights anywhere. Rights are given only in chunk 06.

The login test happens in chunk 05, once the API integration exists.

## Done when

- [ ] `svc-vault-pki` exists (A3 records `CORP\svc-vault-pki` or the local name)
- [ ] Password in PAM; never shared outside the Venafi team
- [ ] No rights anywhere yet
