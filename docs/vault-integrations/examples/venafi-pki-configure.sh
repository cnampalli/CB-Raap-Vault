#!/usr/bin/env bash
# venafi-pki-configure.sh — CLI alternative to the vault-enterprise-config Terraform (guide 08 §5–§8,
# runbook 09 steps V6–V7). Registers the plugin, mounts it pinned to v0.16.0, writes roles and
# consumer policies. Idempotent. Run ONCE as a Vault admin, AFTER venafi-pki-verify-node.sh passes
# on every node.
#
# It does NOT write the Venafi secret (TPP tokens): use venafi-pki-bootstrap-secret.sh for that,
# so the tokens are handled by the Venafi team only.
#
# Prefer the Terraform path (vault-enterprise-config: configs/root-namespace.yaml "plugins" and
# configs/applications/<app>.yaml "secret_engines.venafi_pki"). Do not run both against one mount.
#
# Required env:  VAULT_ADDR  VAULT_TOKEN (admin: sudo on root sys/plugins/catalog, admin in NS)
# Optional env:  NS=AUT  MOUNT=venafi-pki  SECRET=tpp  BASE_ZONE='Certificates\Vault\AUT'
#                DOMAIN=aut.corp.example.com   SKIP_REGISTER=1 (catalog already done)
set -euo pipefail

VERSION="v0.16.0"
BIN_SHA256="48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec"   # linux/amd64 BINARY

NS="${NS-AUT}"
MOUNT="${MOUNT:-venafi-pki}"
SECRET="${SECRET:-tpp}"
BASE_ZONE="${BASE_ZONE:-Certificates\\Vault\\AUT}"
DOMAIN="${DOMAIN:-aut.corp.example.com}"
nsflag=(); [[ -n "$NS" ]] && nsflag=(-namespace="$NS")

: "${VAULT_ADDR:?}" "${VAULT_TOKEN:?}"
command -v vault >/dev/null || { echo "vault CLI not found" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found" >&2; exit 2; }

# 1. catalog — ROOT namespace only
if [[ "${SKIP_REGISTER:-0}" != "1" ]]; then
  echo "== register venafi-pki-backend ${VERSION} (root catalog)"
  VAULT_NAMESPACE="" vault plugin register \
    -sha256="$BIN_SHA256" -command=venafi-pki-backend -version="$VERSION" \
    secret venafi-pki-backend
fi
VAULT_NAMESPACE="" vault plugin info -version="$VERSION" secret venafi-pki-backend | grep -E 'sha256|version'

# 2. mount, pinned to the catalog version
echo "== mount ${NS:+$NS/}${MOUNT}"
if vault secrets list "${nsflag[@]}" -format=json | jq -e --arg m "${MOUNT}/" 'has($m)' >/dev/null; then
  echo "   already mounted — tuning plugin_version instead (reload needed if it changed)"
  vault secrets tune "${nsflag[@]}" -plugin-version="$VERSION" -max-lease-ttl=2160h "${MOUNT}/"
else
  vault secrets enable "${nsflag[@]}" -path="$MOUNT" -plugin-version="$VERSION" \
    -max-lease-ttl=2160h -description="Venafi TPP-backed TLS issuance (venafi-pki-backend)" \
    venafi-pki-backend
fi
vault secrets list "${nsflag[@]}" -detailed -format=json | jq --arg m "${MOUNT}/" '.[$m] | {type, plugin_version, running_plugin_version}'

# 3. roles (fields are exactly those of v0.16.0)
echo "== roles"
# Server certs; Vault generates the key, key NOT stored in Vault.
vault write "${nsflag[@]}" "${MOUNT}/roles/web-aut" \
  venafi_secret="$SECRET" zone="${BASE_ZONE}\\Web" \
  key_type=rsa key_bits=2048 chain_option=last issuer_hint=m \
  ttl=720h max_ttl=2160h generate_lease=true \
  store_by=serial store_pkey=false server_timeout=180
# CSR-only: hosts keep their own keys. key_type=any is valid for sign/ only.
vault write "${nsflag[@]}" "${MOUNT}/roles/host-csr-aut" \
  venafi_secret="$SECRET" zone="${BASE_ZONE}\\Hosts" \
  key_type=any chain_option=last issuer_hint=m ttl=2160h max_ttl=8760h no_store=true
# Kubernetes cert-manager (sign/). chain_option MUST be last: cert-manager treats ca_chain[0] as issuer.
vault write "${nsflag[@]}" "${MOUNT}/roles/k8s-cert-manager" \
  venafi_secret="$SECRET" zone="${BASE_ZONE}\\K8s" \
  key_type=any chain_option=last issuer_hint=m ttl=720h max_ttl=2160h no_store=true generate_lease=false

# 4. consumer policies (paths are relative to the namespace)
echo "== policies"
vault policy write "${nsflag[@]}" "${MOUNT}-web-aut" - <<EOF
path "${MOUNT}/issue/web-aut" {
  capabilities = ["create", "update"]
  # Pre-filter only: alt_names globs are bypassable with a comma-joined value (guide 08 §8).
  allowed_parameters = {
    "common_name"        = ["*.${DOMAIN}"]
    "alt_names"          = ["*.${DOMAIN}"]
    "ttl"                = []
    "private_key_format" = []
    "custom_fields"      = []
  }
}
path "${MOUNT}/venafi/*" { capabilities = ["deny"] }
path "${MOUNT}/roles/*"  { capabilities = ["deny"] }
EOF
vault policy write "${nsflag[@]}" "${MOUNT}-host-csr-aut" - <<EOF
path "${MOUNT}/sign/host-csr-aut" {
  capabilities = ["create", "update"]
  allowed_parameters = { "csr" = [], "ttl" = [], "custom_fields" = [] }
}
path "${MOUNT}/venafi/*" { capabilities = ["deny"] }
path "${MOUNT}/roles/*"  { capabilities = ["deny"] }
EOF
vault policy write "${nsflag[@]}" "${MOUNT}-k8s-cert-manager" - <<EOF
# Exactly the parameters cert-manager's Vault issuer sends to sign/ (v1.21), plus custom_fields.
path "${MOUNT}/sign/k8s-cert-manager" {
  capabilities = ["create", "update"]
  allowed_parameters = {
    "csr" = [], "ttl" = [], "common_name" = [], "alt_names" = [], "ip_sans" = [],
    "uri_sans" = [], "exclude_cn_from_sans" = [], "custom_fields" = []
  }
}
path "${MOUNT}/venafi/*" { capabilities = ["deny"] }
path "${MOUNT}/roles/*"  { capabilities = ["deny"] }
EOF

cat <<EOF

Done. Next (runbook 09):
  V8  issue the bootstrap token:   ./venafi-pki-bootstrap-secret.sh issue-token
  P9  Venafi team writes the secret: ./venafi-pki-bootstrap-secret.sh write-secret
  V10 attach ${MOUNT}-<role> policies to the consuming auth roles
  §5  run the proof:  tools/venafi_pki_proof.py ...
EOF
