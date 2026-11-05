# 05 — API integration

**Who:** Venafi team, signed in as the right admin (AD admin for an AD account, see chunk 02)
**Needs:** `svc-vault-pki` (chunk 04) · **Gives:** A4–A6 to the Vault team

## Step 1 — Create the Vault integration

1. 🖱 Aperture → **Platform** ► **API** ► **Integrations** → **Add**.
2. 🖱 Fill in:

   | Field | Value |
   |---|---|
   | Name | `Venafi Secrets Engine for HashiCorp Vault — AUT` |
   | Application ID | **`hashicorp-vault-by-venafi`**, exactly. The plugin depends on it |
   | Scope | Certificate → **Manage** and **Revoke** (`certificate:manage,revoke`). Untick Revoke only if Vault must never revoke |
   | Allow token refresh | **On** |
   | Token validity | **1 day** |
   | Grant validity | **365 days** |

3. 🖱 **Allowed identities** → **Add** → search `svc-vault-pki` → select → **OK**.
   It must be the **only** allowed identity.
4. 🖱 **Save**.

**Expected:** the integration shows in the list as **Enabled**, with `svc-vault-pki` as its only
identity.

## Step 2 — Create the read-only proof integration

Used once, in chunk 15, to look certificates up in TPP.

1. 🖱 **Integrations** → **Add**.
2. 🖱 Name `Venafi PKI proof (read-only)`, Application ID **`venafi-pki-proof`**, scope
   **Certificate** (read only, no Manage), token validity 1 day, token refresh **Off**.
3. 🖱 Allowed identities: the PKI analyst who will run the proof.
4. 🖱 **Save**.

**Expected:** both integrations listed and enabled.

## Step 3 — Test that the service account can log in

⌨ From your admin host (bash or zsh; needs `curl` and `jq`):

1. Set the URL and username. Use **single quotes** and **one** backslash:
   ```bash
   TPP_URL=https://tpp.corp.example.com
   TPP_USER='CORP\svc-vault-pki'        # local account: TPP_USER='svc-vault-pki'
   ```
2. Type the password and build the request:
   ```bash
   printf 'svc-vault-pki password: '; read -rs P; echo
   BODY=$(jq -n --arg u "$TPP_USER" --arg p "$P" \
     '{client_id:"hashicorp-vault-by-venafi", scope:"certificate:manage,revoke", username:$u, password:$p}')
   unset P
   [ -n "$BODY" ] && echo "body OK" || echo "body EMPTY: is jq installed?"
   ```
   **Expected:** `body OK`.
3. Ask TPP for a token:
   ```bash
   RESP=$(curl -sS -X POST "$TPP_URL/vedauth/authorize/oauth" \
     -H 'Content-Type: application/json' -d "$BODY"); unset BODY
   TOKEN=$(printf '%s' "$RESP" | jq -r '.access_token // empty')
   [ -n "$TOKEN" ] && echo "OK: ${TOKEN:0:6}…" || echo "FAILED: $RESP"
   ```
   **Expected:** `OK: ` followed by a token prefix. On `FAILED`, TPP's reply tells you why (see the
   table below).
4. Throw the test token away:
   ```bash
   curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
     "$TPP_URL/vedauth/revoke/token"; unset TOKEN RESP
   ```
   **Expected:** `200`.

## Step 4 — Hand off

🖱 Send A4–A6 to the Vault team. They set `refresh_interval` to half the token validity (`12h`).

## Done when

- [ ] Vault integration enabled, `svc-vault-pki` its only identity, refresh on
- [ ] Proof integration enabled
- [ ] Login test returns a token

## If it fails

| You see | Likely cause | Fix |
|---|---|---|
| Can't find `svc-vault-pki` under Allowed identities | Signed in as a local admin for an AD account | Sign in as your AD admin (chunk 02) |
| `Unable to parse input document` | TPP got an empty or broken body: `jq` missing, or the username typed into the JSON with a single backslash | Use Step 3 exactly as written (username in `TPP_USER`); check `body OK` |
| `body EMPTY` | `jq` not installed | Install `jq` (`brew install jq` / `dnf install jq`) |
| `invalid_grant` / 401 in Step 3 | Wrong username format, or wrong password | Try `CORP\svc-vault-pki`, then the UPN `svc-vault-pki@corp.example.com` |
| `invalid_client` | Application ID typo | Must be exactly `hashicorp-vault-by-venafi` |
| `invalid_scope` | Scope on the integration lacks Manage/Revoke | Fix Step 1 |
| Works locally, fails for AD | Account locked, expired, or logon restricted | Check the account in AD |
