#!/usr/bin/env bash
# venafi-pki-bootstrap-secret.sh — write the Venafi secret (TPP tokens) into Vault ONCE, without
# the Vault team ever seeing the TPP tokens and without Terraform (runbook 09, steps V8/P9/V9).
#
#   Vault team :  ./venafi-pki-bootstrap-secret.sh issue-token    -> prints a WRAPPING token (30 min, single use)
#   Venafi team:  ./venafi-pki-bootstrap-secret.sh write-secret   -> unwraps it, runs vcert getcred twice, writes
#   Vault team :  ./venafi-pki-bootstrap-secret.sh status         -> shows the (masked) secret
#
# Why a wrapped token: the bootstrap token can only create/update ONE path and cannot read it back.
# Wrapping makes it single-use and tamper-evident — if unwrap says "wrapping token is not valid",
# someone else used it first: treat that as an incident.
#
# Common env:
#   VAULT_ADDR (required)  VAULT_CACERT (Vault TLS CA)  NS=AUT  MOUNT=venafi-pki  SECRET=tpp
# issue-token / status:  VAULT_TOKEN = admin token in NS
# write-secret:          VAULT_WRAPPED_TOKEN = the wrapping token from issue-token
#                        TPP_URL (e.g. https://tpp.corp.example.com)   TPP_USER=svc-vault-pki
#                        TPP_CHAIN = TPP web-chain PEM on THIS host (for vcert)
#                        TRUST_BUNDLE = same PEM's PATH ON EVERY VAULT NODE (default /etc/vault/tls/tpp-chain.pem)
#                        ZONE='Certificates\Vault\AUT'   REFRESH_INTERVAL=12h
#                        CLIENT_ID=hashicorp-vault-by-venafi   SCOPE='certificate:manage,revoke'
# Needs: vault CLI, jq; write-secret also needs vcert (v5) and a TTY (vcert prompts for the password).
set -euo pipefail

NS="${NS-AUT}"
MOUNT="${MOUNT:-venafi-pki}"
SECRET="${SECRET:-tpp}"
POLICY="${MOUNT}-bootstrap"
nsflag=(); [[ -n "$NS" ]] && nsflag=(-namespace="$NS")

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 not found on PATH"; }
: "${VAULT_ADDR:?set VAULT_ADDR}"
need vault; need jq

issue_token() {
  : "${VAULT_TOKEN:?admin VAULT_TOKEN required}"
  echo "== policy ${POLICY} (create/update on ${MOUNT}/venafi/${SECRET} only — no read)"
  vault policy write "${nsflag[@]}" "$POLICY" - <<EOF
# One-time bootstrap of the Venafi secret. Cannot read the secret back.
path "${MOUNT}/venafi/${SECRET}" {
  capabilities = ["create", "update"]
}
# -no-default-policy drops this too; the token must be able to revoke itself when done.
path "auth/token/revoke-self" {
  capabilities = ["update"]
}
EOF
  echo "== wrapped bootstrap token (TTL 30m, 4 uses, orphan, no default policy)"
  out="$(vault token create "${nsflag[@]}" -policy="$POLICY" -no-default-policy -orphan \
          -ttl=30m -explicit-max-ttl=30m -use-limit=4 -display-name="${MOUNT}-bootstrap" \
          -wrap-ttl=30m -format=json)"
  echo
  echo "WRAPPING TOKEN (give it to the Venafi engineer over an approved secure channel, never chat/email):"
  echo "  $(jq -r .wrap_info.token <<<"$out")"
  echo "wrapping accessor (to revoke it if unused): $(jq -r .wrap_info.accessor <<<"$out")"
  echo "expires: $(jq -r .wrap_info.creation_time <<<"$out") + 30m"
}

write_secret() {
  : "${VAULT_WRAPPED_TOKEN:?set VAULT_WRAPPED_TOKEN to the wrapping token}" "${TPP_URL:?set TPP_URL}"
  : "${TPP_CHAIN:?set TPP_CHAIN (PEM of the TPP web chain on this host)}"
  need vcert
  local TPP_USER="${TPP_USER:-svc-vault-pki}" CLIENT_ID="${CLIENT_ID:-hashicorp-vault-by-venafi}"
  local SCOPE="${SCOPE:-certificate:manage,revoke}" REFRESH_INTERVAL="${REFRESH_INTERVAL:-12h}"
  local TRUST_BUNDLE="${TRUST_BUNDLE:-/etc/vault/tls/tpp-chain.pem}" ZONE="${ZONE:-Certificates\\Vault\\AUT}"
  [[ -t 0 ]] || die "write-secret needs a terminal: vcert prompts for the ${TPP_USER} password"

  umask 077
  local base="/dev/shm"; [[ -d "$base" && -w "$base" ]] || base="${TMPDIR:-/tmp}"
  WORK="$(mktemp -d "$base/venafi-bootstrap.XXXXXX")"
  trap 'command -v shred >/dev/null && shred -u "$WORK"/* 2>/dev/null; rm -rf "$WORK"' EXIT

  echo "== unwrap the bootstrap token"
  BOOT="$(VAULT_TOKEN="$VAULT_WRAPPED_TOKEN" vault unwrap -field=token)" \
    || die "unwrap failed — token expired or ALREADY USED BY SOMEONE ELSE (report it)"

  for i in 1 2; do
    echo "== vcert getcred #$i  (user ${TPP_USER}, client ${CLIENT_ID}, scope ${SCOPE})"
    # No --password: vcert prompts on the terminal, so the password never appears in argv/ps.
    vcert getcred -u "$TPP_URL" --username "$TPP_USER" --client-id "$CLIENT_ID" --scope "$SCOPE" \
      --trust-bundle "$TPP_CHAIN" --format json > "$WORK/pair$i.json"
    jq -e '.access_token and .refresh_token' "$WORK/pair$i.json" >/dev/null \
      || die "getcred #$i returned no refresh_token — is token refresh enabled on the API integration?"
  done
  jq -j .access_token  "$WORK/pair1.json" > "$WORK/access_token"     # -j: no trailing newline
  jq -j .refresh_token "$WORK/pair1.json" > "$WORK/refresh_token"
  jq -j .refresh_token "$WORK/pair2.json" > "$WORK/refresh_token_2"
  local expires until
  expires="$(jq -r '.expires // empty' "$WORK/pair1.json")"
  until="$(jq -rs 'map(.refresh_until // empty) | min // empty' "$WORK/pair1.json" "$WORK/pair2.json")"

  echo "== write ${NS:+$NS/}${MOUNT}/venafi/${SECRET}"
  echo "   The ACTIVE Vault node calls TPP during this write (it spends refresh_token at once),"
  echo "   so success also proves flow #11, the trust bundle, client_id and scope."
  VAULT_TOKEN="$BOOT" vault write "${nsflag[@]}" "${MOUNT}/venafi/${SECRET}" \
    url="$TPP_URL" \
    access_token=@"$WORK/access_token" \
    refresh_token=@"$WORK/refresh_token" \
    refresh_token_2=@"$WORK/refresh_token_2" \
    client_id="$CLIENT_ID" \
    refresh_interval="$REFRESH_INTERVAL" \
    zone="$ZONE" \
    trust_bundle_file="$TRUST_BUNDLE"
  if VAULT_TOKEN="$BOOT" vault token revoke -self >/dev/null; then
    echo "== bootstrap token revoked"
  else
    echo "WARN: could not revoke the bootstrap token; it still expires in <= 30 min" >&2
  fi

  echo
  [[ -n "$expires" ]] && echo "access token expires : $(date -u -d "@$expires" +%FT%TZ 2>/dev/null || echo "$expires")"
  if [[ -n "$until" ]]; then
    echo "GRANT EXPIRES (refresh_until): $(date -u -d "@$until" +%FT%TZ 2>/dev/null || echo "$until")"
    echo "  -> after this date the plugin cannot refresh and ALL issuance stops."
    echo "  -> book a re-bootstrap (this script again) at least 30 days before it."
  fi
  echo "Token files are shredded on exit. Never reuse these tokens anywhere else."
}

status() {
  : "${VAULT_TOKEN:?admin VAULT_TOKEN required}"
  vault read "${nsflag[@]}" "${MOUNT}/venafi/${SECRET}"
  echo
  echo "refresh_interval above is the EFFECTIVE value: the plugin clamps it to (access-token lifetime - 30s)."
}

case "${1:-}" in
  issue-token)  issue_token ;;
  write-secret) write_secret ;;
  status)       status ;;
  *) sed -n '2,24p' "$0"; exit 2 ;;
esac
