#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CloudBees CD/RO -> Vault Enterprise: ZeroTrust plugin, Tier 3 (vault CLI + jq)
#
# Advanced/scripted tier for users who run the vault CLI and want automation.
# You never NEED this tier to complete the basic flow — Tier 1 (curl) suffices.
#
# Dependencies on the CD/RO agent: vault (1.15.1 is fine vs 1.20.8+ent) + jq.
#
# Assumes (already configured):
#   - Vault namespace AUT, KV v2 mount "secret".
#   - JWT auth mount "jwt-cdro" (static pubkey, bound_issuer=ZeroTrust),
#     role "cdro-zerotrust", policy cdro-zerotrust-ro on secret/data/cdr/<release>/*.
#   - The ZeroTrust plugin minted a JWT into property /myJob/jwtToken.
#   - Private CA bundle at /etc/pki/vault/ca.crt.
# ---------------------------------------------------------------------------
set -eu
set +x                                   # never trace the token or the secret

export VAULT_ADDR="https://vault-vip.corp.example.com:8200"
export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"
RELEASE='$[/myRelease/name]'
JWT='$[/myJob/jwtToken]'

# 1) Log in with the plugin-minted JWT; -field=token prints only the token.
VAULT_TOKEN=$(vault write -field=token auth/jwt-cdro/login \
              role=cdro-zerotrust jwt="$JWT")
export VAULT_TOKEN

# 2) Read this release's secret (KV v2), single field, never printed.
DB_PASS=$(vault kv get -field=password "secret/cdr/${RELEASE}/db")
echo "Fetched secret (length=${#DB_PASS}) — value not printed."
# ... use $DB_PASS here.

# jq variant (raw HTTP JSON, if you prefer curl output through jq):
#   vault kv get -format=json "secret/cdr/${RELEASE}/db" | jq -r '.data.data.password'

# 3) Clean up.
vault token revoke -self >/dev/null 2>&1 || true
