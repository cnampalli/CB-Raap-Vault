#!/usr/bin/env bash
# venafi-pki-verify-node.sh — READ-ONLY check of ONE Vault node for the Venafi PKI plugin
# (runbook 09 step V2/V4). Ansible has already placed the binary; this proves it is right.
# Run as root (or a user that can read the plugin dir and the Vault config) on EVERY node.
#
#   ./venafi-pki-verify-node.sh                         # defaults below
#   PLUGIN_DIR=/opt/vault/plugins TPP_HOST=tpp.corp.example.com ./venafi-pki-verify-node.sh
#
# Env (all optional):
#   PLUGIN_DIR    plugin_directory from the Vault server config  (default: read from config)
#   VAULT_CONFIG  Vault server config dir or file                (default: /etc/vault.d)
#   BIN_NAME      file name registered as -command               (default: venafi-pki-backend)
#   EXPECTED_SHA256  binary SHA-256 to require                   (default: v0.16.0 linux/amd64)
#   VAULT_GROUP   group that runs Vault                          (default: vault)
#   TRUST_BUNDLE  TPP web-chain PEM used as trust_bundle_file    (default: /etc/vault/tls/tpp-chain.pem)
#   TPP_HOST      if set, prove TLS to TPP:443 with TRUST_BUNDLE from THIS node (firewall flow #11)
#
# Prints one machine-readable summary line per node for the evidence pack. Exit 0 = all OK.
set -uo pipefail

EXPECTED_SHA256="${EXPECTED_SHA256:-48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec}"
BIN_NAME="${BIN_NAME:-venafi-pki-backend}"
VAULT_CONFIG="${VAULT_CONFIG:-/etc/vault.d}"
VAULT_GROUP="${VAULT_GROUP:-vault}"
TRUST_BUNDLE="${TRUST_BUNDLE:-/etc/vault/tls/tpp-chain.pem}"
TPP_HOST="${TPP_HOST:-}"

fails=0
ok()   { printf 'OK    %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }

# 1. plugin_directory: from env, else from the server config (HCL: plugin_directory = "...")
cfg_dir_line="$(grep -rhsE '^[[:space:]]*plugin_directory[[:space:]]*=' "$VAULT_CONFIG" 2>/dev/null | tail -1)"
cfg_dir="$(printf '%s' "$cfg_dir_line" | sed -E 's/.*=[[:space:]]*"?([^"]+)"?.*/\1/')"
PLUGIN_DIR="${PLUGIN_DIR:-$cfg_dir}"
if [[ -z "$cfg_dir" ]]; then
  bad "plugin_directory not set in $VAULT_CONFIG — Vault cannot run any external plugin"
elif [[ "$cfg_dir" != "$PLUGIN_DIR" ]]; then
  bad "PLUGIN_DIR=$PLUGIN_DIR but the server config says $cfg_dir"
else
  ok "plugin_directory = $cfg_dir (from $VAULT_CONFIG)"
fi
[[ -n "${PLUGIN_DIR:-}" ]] || { echo "SUMMARY host=$(hostname -f 2>/dev/null || hostname) result=FAIL reason=no-plugin-dir"; exit 1; }

# 2. directory: real dir, not a symlink, not on a noexec mount
if [[ -L "$PLUGIN_DIR" ]]; then bad "$PLUGIN_DIR is a symlink — Vault refuses symlinked plugin directories"
elif [[ ! -d "$PLUGIN_DIR" ]]; then bad "$PLUGIN_DIR does not exist"
else ok "$PLUGIN_DIR is a real directory"; fi
if findmnt -no OPTIONS --target "$PLUGIN_DIR" 2>/dev/null | grep -qw noexec; then
  bad "$PLUGIN_DIR is on a noexec mount — the plugin process cannot start"
else
  ok "$PLUGIN_DIR is not on a noexec mount"
fi

# 3. binary: present, exact SHA-256, owner/mode, not writable by group/other
BIN="$PLUGIN_DIR/$BIN_NAME"
actual_sha="missing"
if [[ ! -f "$BIN" ]]; then
  bad "$BIN not found (did the Ansible play run on this node?)"
else
  actual_sha="$(sha256sum "$BIN" | cut -d' ' -f1)"
  if [[ "$actual_sha" == "$EXPECTED_SHA256" ]]; then ok "sha256 $actual_sha"
  else bad "sha256 $actual_sha != expected $EXPECTED_SHA256 (zip hash registered by mistake, or wrong build)"; fi
  read -r mode owner group < <(stat -c '%a %U %G' "$BIN")
  [[ "$group" == "$VAULT_GROUP" || "$owner" == "$VAULT_GROUP" ]] \
    && ok "owner $owner:$group" || bad "owner $owner:$group — Vault (group $VAULT_GROUP) may not be able to execute it"
  (( (8#$mode & 8#022) == 0 )) && ok "mode $mode (not group/other writable)" || bad "mode $mode is group/other writable"
  [[ -x "$BIN" ]] || bad "$BIN is not executable"
  file "$BIN" 2>/dev/null | grep -q 'ELF 64-bit.*x86-64' && ok "ELF x86-64 binary" \
    || warn "could not confirm ELF x86-64 (is 'file' installed? is this node arm64?)"
fi

# 4. TPP trust bundle (trust_bundle_file is a PATH read on the active node — must exist on every node)
if [[ -s "$TRUST_BUNDLE" ]]; then
  n="$(grep -c 'BEGIN CERTIFICATE' "$TRUST_BUNDLE")"
  ok "trust bundle $TRUST_BUNDLE ($n certificate(s))"
  if [[ -n "$TPP_HOST" ]]; then
    out="$(timeout 15 openssl s_client -connect "$TPP_HOST:443" -servername "$TPP_HOST" \
            -CAfile "$TRUST_BUNDLE" -verify_return_error </dev/null 2>&1)"
    if printf '%s' "$out" | grep -q 'Verify return code: 0 (ok)'; then
      ok "TLS to $TPP_HOST:443 verified with the trust bundle (flow #11 open from this node)"
    else
      bad "TLS to $TPP_HOST:443 failed: $(printf '%s' "$out" | grep -m1 -E 'Verify return code|connect:|errno|Connection' )"
    fi
  fi
else
  bad "trust bundle $TRUST_BUNDLE missing or empty — enrollment from this node will fail with x509 errors"
fi

result=$([[ $fails -eq 0 ]] && echo PASS || echo FAIL)
echo "SUMMARY host=$(hostname -f 2>/dev/null || hostname) result=$result sha256=$actual_sha plugin_dir=$PLUGIN_DIR fails=$fails"
exit $(( fails > 0 ))
