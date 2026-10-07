#!/usr/bin/env bash
# venafi-pki-install-node.sh — install venafi-pki-backend on ONE Vault node (guide 08 §4).
# Run as root on EVERY node in the cluster, standbys first. Idempotent.
#
#   ./venafi-pki-install-node.sh /path/to/venafi-pki-backend_v0.16.0_linux.zip [plugin_dir]
#
# Airgap: copy the zip in by your normal transfer process; this script never downloads.
# Prints the BINARY sha256 at the end — that, not the zip hash, is what Vault registers.
set -euo pipefail

VERSION="v0.16.0"
# Published zip hash for linux/amd64 (release notes, v0.16.0)
ZIP_SHA256="53729133de9c3b2d465d2abd070d722e1ccd0d6cccb9b16c86aaca38031ba0e2"
# Binary hash, verified from that zip on 2026-10-08
BIN_SHA256="48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec"

ZIP="${1:?usage: $0 <zip> [plugin_dir]}"
PLUGIN_DIR="${2:-/etc/vault/vault_plugins}"
TARGET="${PLUGIN_DIR}/venafi-pki-backend"

die() { echo "ERROR: $*" >&2; exit 1; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

[[ $EUID -eq 0 ]] || die "run as root"
command -v unzip >/dev/null || die "unzip not installed"

# 1. zip integrity against the published hash
[[ "$(sha "$ZIP")" == "$ZIP_SHA256" ]] || die "zip sha256 mismatch — not the ${VERSION} linux/amd64 release"
echo "OK  zip sha256 matches ${VERSION} release"

# 2. extract to a private temp dir and check the bundled SHA256SUM
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
unzip -q "$ZIP" -d "$WORK"
[[ -f "$WORK/venafi-pki-backend" ]] || die "binary not found in zip"
[[ "$(sha "$WORK/venafi-pki-backend")" == "$(tr -d '[:space:]' < "$WORK/venafi-pki-backend.SHA256SUM")" ]] \
  || die "binary does not match the SHA256SUM shipped in the zip"
[[ "$(sha "$WORK/venafi-pki-backend")" == "$BIN_SHA256" ]] || die "binary sha256 differs from the value pinned in guide 08"
echo "OK  binary sha256 matches"

# 3. plugin_directory sanity: real dir, not a symlink, not on a noexec mount
mkdir -p "$PLUGIN_DIR"
[[ ! -L "$PLUGIN_DIR" ]] || die "$PLUGIN_DIR is a symlink — Vault rejects it"
if findmnt -no OPTIONS --target "$PLUGIN_DIR" 2>/dev/null | grep -qw noexec; then
  die "$PLUGIN_DIR is on a noexec mount — Vault cannot start the plugin"
fi
getent group vault >/dev/null || die "group 'vault' not found"

# 4. install (atomic replace)
install -o root -g vault -m 0750 "$WORK/venafi-pki-backend" "${TARGET}.new"
mv -f "${TARGET}.new" "$TARGET"
chown root:vault "$PLUGIN_DIR"; chmod 0750 "$PLUGIN_DIR"
echo "OK  installed $TARGET"

# 5. remind about server config
grep -rqs "plugin_directory" /etc/vault.d/ 2>/dev/null \
  || echo "WARN plugin_directory not found under /etc/vault.d/ — add: plugin_directory = \"$PLUGIN_DIR\" and restart this node"

echo
echo "host:           $(hostname -f 2>/dev/null || hostname)"
echo "binary sha256:  $(sha "$TARGET")   <- register this (guide 08 §5)"
