# 11 — Connect Vault to TPP

**Who:** Vault engineer **and** Venafi engineer, at the same time (on a call)
**Needs:** chunks 05, 06, 07, 09 (flow #14), 10 · **Gives:** live TPP tokens in Vault, the `refresh_until` date

The Vault team creates a one-time token. The Venafi engineer uses it to write the TPP tokens into Vault.
The service account password never leaves the Venafi team.

## Step 1 — Vault team: issue the one-time token

⌨
```bash
NS=AUT MOUNT=venafi-pki SECRET=tpp \
  docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh issue-token
```
**Expected:** policy `venafi-pki-bootstrap` created, and a **wrapping token** valid **30 minutes**.

🖱 Send the wrapping token to the Venafi engineer over the agreed channel (A17). **Never** chat or
e-mail. Note the wrapping accessor.

## Step 2 — Venafi team: write the secret

Needs on your admin host: `vcert` v5, `vault`, `jq`, `tpp-chain.pem`, network to Vault (flow #14) and TPP.

⌨
```bash
export VAULT_ADDR=https://vault-vip.corp.example.com:8200 VAULT_CACERT=/path/vault-listener-ca.pem
export NS=AUT MOUNT=venafi-pki SECRET=tpp
export VAULT_WRAPPED_TOKEN='<token from Step 1>'
export TPP_URL=https://tpp.corp.example.com TPP_USER='CORP\svc-vault-pki' TPP_CHAIN=./tpp-chain.pem
export ZONE='Certificates\Vault\AUT' REFRESH_INTERVAL=12h TRUST_BUNDLE=/etc/vault/tls/tpp-chain.pem
./docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh write-secret
```
For a local account: `TPP_USER=svc-vault-pki`.

🖱 Type the `svc-vault-pki` password when prompted. **It asks twice** (two independent tokens).

**Expected:**
- `Success! Data written to: venafi-pki/venafi/tpp`. Vault has already called TPP successfully.
- `== bootstrap token revoked`
- `GRANT EXPIRES (refresh_until): <date>`

🖱 Send "secret written" and the **`refresh_until` date** to the Vault team. Do not send the tokens.

## Step 3 — Vault team: check the secret

⌨
```bash
NS=AUT docs/vault-integrations/examples/venafi-pki-bootstrap-secret.sh status
```
**Expected:** `url`, `zone`, `client_id=hashicorp-vault-by-venafi`, tokens shown **masked**, and the
effective `refresh_interval`.

## Step 4 — Both: put the expiry in the calendar

🖱 Calendar entry for **`refresh_until` − 30 days**, owners: Venafi + Vault teams. Title: "Re-connect
Vault to TPP (chunk 11)". After `refresh_until`, **all issuance stops**.

**Expected:** the entry exists and the date is in the change ticket.

## Done when

- [ ] Secret written, one-time token revoked
- [ ] `status` shows masked tokens and the right client id
- [ ] `refresh_until − 30 days` in the calendar

## If it fails

| You see | Likely cause | Fix |
|---|---|---|
| `unwrap failed` | Token expired (30 min), **or someone else used it** | Stop. If "already used", report it as a security event. Redo Step 1 |
| `invalid_grant` / 401 | Wrong client id, scope, username format or password | Re-run chunk 05 Step 3 first, then a new Step 1 |
| `x509: … unknown authority` | Trust bundle missing on the **active** node | Chunk 08 Step 4 |
| Timeout | Flow #11 from the active node, or #14 from your host | Chunk 09 |
