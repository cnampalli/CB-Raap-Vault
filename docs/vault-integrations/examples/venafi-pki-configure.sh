#!/usr/bin/env bash
# venafi-pki-configure.sh — register + mount + configure the Venafi PKI engine (guide 08 §5–§8).
# Run ONCE, as a Vault admin, AFTER venafi-pki-install-node.sh has run on every node.
#
# Required env:
#   VAULT_ADDR        e.g. https://vault-vip.corp.example.com:8200
#   VAULT_TOKEN       admin token valid in root (catalog) and in AUT
#   TPP_URL           e.g. https://tpp.corp.example.com
#   TOKEN_DIR         tmpfs dir holding three files from `vcert getcred` (guide 08 §6.2):
#                       access_token  refresh_token  refresh_token_2
# Optional env:
#   NS=AUT  MOUNT=venafi-pki  SECRET=tpp  REFRESH_INTERVAL=12h
#   TRUST_BUNDLE=/etc/vault/tls/tpp-chain.pem   (must exist at this path on EVERY node)
#   BASE_ZONE='Certificates\Automation\Vault\AUT'
#   SKIP_SECRET=1     skip writing the Venafi secret (e.g. re-running for roles only)
set -euo pipefail

VERSION="v0.16.0"
BIN_SHA256="48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec"

NS="${NS:-AUT}"
MOUNT="${MOUNT:-venafi-pki}"
SECRET="${SECRET:-tpp}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-12h}"
TRUST_BUNDLE="${TRUST_BUNDLE:-/etc/vault/tls/tpp-chain.pem}"
BASE_ZONE="${BASE_ZONE:-Certificates\\Automation\\Vault\\AUT}"
HERE="$(cd "$(dirname "$0")" && pwd)"

: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 2; }

# 1. catalog (root namespace only)
echo "== register ${VERSION} in plugin catalog (root)"
VAULT_NAMESPACE="" vault plugin register \
  -sha256="$BIN_SHA256" -command=venafi-pki-backend -version="$VERSION" \
  secret venafi-pki-backend

# 2. mount in AUT (skip if present)
echo "== mount ${NS}/${MOUNT}"
if vault secrets list -namespace="$NS" -format=json | grep -q "\"${MOUNT}/\""; then
  echo "   already mounted — leaving as is (use 'vault secrets tune -plugin-version' to upgrade)"
else
  vault secrets enable -namespace="$NS" -path="$MOUNT" -plugin-version="$VERSION" \
    -max-lease-ttl=2160h -description="Venafi TPP-backed TLS issuance" venafi-pki-backend
fi

# 3. Venafi secret (tokens via @file — never on the command line)
if [[ "${SKIP_SECRET:-0}" != "1" ]]; then
  : "${TPP_URL:?}" "${TOKEN_DIR:?}"
  for f in access_token refresh_token refresh_token_2; do
    [[ -s "$TOKEN_DIR/$f" ]] || { echo "missing $TOKEN_DIR/$f" >&2; exit 2; }
    # vault's key=@file keeps a trailing newline, which corrupts the token. printf is a
    # builtin, so the token never appears in argv / ps.
    printf '%s' "$(<"$TOKEN_DIR/$f")" > "$TOKEN_DIR/$f"
  done
  echo "== write ${MOUNT}/venafi/${SECRET}"
  echo "   WARNING: these tokens must not be used by any other Venafi secret, mount or cluster."
  vault write -namespace="$NS" "${MOUNT}/venafi/${SECRET}" \
    url="$TPP_URL" \
    access_token=@"$TOKEN_DIR/access_token" \
    refresh_token=@"$TOKEN_DIR/refresh_token" \
    refresh_token_2=@"$TOKEN_DIR/refresh_token_2" \
    client_id="hashicorp-vault-by-venafi" \
    refresh_interval="$REFRESH_INTERVAL" \
    zone="$BASE_ZONE" \
    trust_bundle_file="$TRUST_BUNDLE"
  echo "   done — now destroy the token files: shred -u $TOKEN_DIR/*"
fi

# 4. roles
echo "== roles"
vault write -namespace="$NS" "${MOUNT}/roles/web-aut" \
  venafi_secret="$SECRET" zone="${BASE_ZONE}\\Web" \
  key_type=rsa key_bits=2048 chain_option=last issuer_hint=m \
  ttl=720h max_ttl=2160h generate_lease=true \
  store_by=serial store_pkey=false server_timeout=180

vault write -namespace="$NS" "${MOUNT}/roles/host-csr-aut" \
  venafi_secret="$SECRET" zone="${BASE_ZONE}\\Hosts" \
  issuer_hint=m ttl=2160h max_ttl=8760h no_store=true

# 5. consumer policy
echo "== policy venafi-pki-web-aut"
vault policy write -namespace="$NS" venafi-pki-web-aut "$HERE/venafi-pki-consumer.hcl"

cat <<EOF

Next:
  * attach policy 'venafi-pki-web-aut' to the consuming auth role(s) (guide 08 §8)
  * smoke test:
      vault write -namespace=$NS ${MOUNT}/issue/web-aut common_name=smoke.aut.corp.example.com ttl=24h
  * run the verification list in guide 08 §12
EOF
