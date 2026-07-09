#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CloudBees CD/RO -> Vault Enterprise: ZeroTrust plugin, Tier 1 (plain curl)
#
# Paste this into a CD/RO "command" (shell) procedure step. Recommended airgap
# default: only dependency on the CD/RO agent is curl (jq optional).
#
# Assumes (already configured):
#   - Vault namespace AUT, KV v2 mount "secret".
#   - JWT auth mount "jwt-cdro" (static jwt_validation_pubkeys, bound_issuer=ZeroTrust).
#   - Vault role "cdro-zerotrust" (bound_audiences=vault-AUT, claim_mappings job_name->release,
#     policy cdro-zerotrust-ro on secret/data/cdr/<release>/*).
#   - The ZeroTrust plugin minted a JWT into property /myJob/jwtToken
#     (e.g. via IssueJwtAndStoreInProperty, or getAuthorizedTokenAndRunStep).
#   - Private CA bundle at /etc/pki/vault/ca.crt.
#
# Hardening: set +x (never trace secrets), JWT via stdin (never argv),
#            token revoked at the end. Nothing is echoed except a length.
# ---------------------------------------------------------------------------
set -eu
set +x                                   # never trace the token or the secret

export VAULT_ADDR="https://vault-vip.corp.example.com:8200"
export VAULT_NAMESPACE="AUT"
export VAULT_CACERT="/etc/pki/vault/ca.crt"
VAULT_ROLE="cdro-zerotrust"
RELEASE='$[/myRelease/name]'             # CD/RO substitutes the live release name
JWT='$[/myJob/jwtToken]'                 # plugin-minted JWT (a secure/masked property)

# 1) Log in with the plugin-minted JWT. Sent via stdin (--data @-) so it never
#    lands in the process list / argv. grep+cut parses the token without jq.
VAULT_TOKEN=$(curl -sS --fail --cacert "$VAULT_CACERT" \
    -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
    --request POST --data @- \
    "$VAULT_ADDR/v1/auth/jwt-cdro/login" <<EOF |
{"role":"$VAULT_ROLE","jwt":"$JWT"}
EOF
    grep -o '"client_token":"[^"]*"' | head -1 | cut -d'"' -f4)
# --- jq alternative: replace the grep|cut line with  jq -r '.auth.client_token'

# 2) Read this release's secret (KV v2). Path is release-scoped by policy.
DB_PASS=$(curl -sS --fail --cacert "$VAULT_CACERT" \
    -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/data/cdr/${RELEASE}/db" \
    | grep -o '"password":"[^"]*"' | head -1 | cut -d'"' -f4)
echo "Fetched secret (length=${#DB_PASS}) — value not printed."
# ... use $DB_PASS here; never echo it.

# 3) Clean up: revoke our own token (best-effort; it also expires on its own).
curl -sS --cacert "$VAULT_CACERT" \
    -H "X-Vault-Namespace: $VAULT_NAMESPACE" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    --request POST \
    "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
