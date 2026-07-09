#!/usr/bin/env python3
"""Decode and pretty-print an OIDC/JWT ID token's header and claims.

Airgap-safe: standard library only, no network calls, no signature
verification. This is a *decode*, not a validation — it reads the two
base64url segments of a JWT and prints them so you can see the exact
`iss`, `aud`, `sub`, and build-context claims your CloudBees CI OIDC
Provider plugin issues. Use the output to configure the matching Vault
JWT role (`bound_issuer`, `bound_audiences`, `bound_claims`).

Security: this does not verify the signature and must never be trusted to
authenticate a token. It only reveals claim values, not secrets. Do not
paste a *usable* token into a shared terminal; capture it, inspect it,
discard it.

Usage:
    # from a file
    python3 inspect_jwt_claims.py --file token.jwt

    # from stdin (heredoc keeps the token out of your shell history/argv)
    python3 inspect_jwt_claims.py <<'EOF'
    eyJ...header...*.eyJ...payload...*.sig
    EOF

    # as a positional argument (least private — visible in process list)
    python3 inspect_jwt_claims.py eyJ...

Exit codes: 0 = decoded, 2 = bad input / malformed token.

Requires: Python 3.6+ (standard library only — no pip install).
"""
import argparse
import base64
import binascii
import json
import sys
from typing import Tuple

# Claims worth calling out because they map directly onto Vault JWT-role bindings
# (bound_issuer/bound_audiences/bound_claims) and templated-policy metadata
# (claim_mappings -> group_name/job_name).
HIGHLIGHT = ("iss", "aud", "sub", "job", "group_name", "job_name",
             "build_url", "exp", "iat", "nbf")


def _b64url_decode(segment: str) -> bytes:
    """Decode a base64url segment, restoring the padding JWT omits."""
    padding = "=" * (-len(segment) % 4)
    try:
        return base64.urlsafe_b64decode(segment + padding)
    except (binascii.Error, ValueError) as exc:
        raise ValueError(f"segment is not valid base64url: {exc}") from exc


def decode_jwt(token: str) -> Tuple[dict, dict]:
    """Return (header, payload) dicts from a JWT string. Raises ValueError."""
    token = token.strip()
    parts = token.split(".")
    if len(parts) < 2:
        raise ValueError(
            "not a JWT: expected at least two dot-separated segments "
            f"(header.payload[.signature]), got {len(parts)}"
        )
    header = json.loads(_b64url_decode(parts[0]))
    payload = json.loads(_b64url_decode(parts[1]))
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise ValueError("decoded segments are not JSON objects")
    return header, payload


def _read_token(args) -> str:
    if args.token:
        return args.token
    if args.file:
        with open(args.file, "r", encoding="utf-8") as fh:
            return fh.read()
    if not sys.stdin.isatty():
        return sys.stdin.read()
    raise ValueError("no token provided (use --file, a positional arg, or stdin)")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Decode a JWT/OIDC ID token's header and claims (no verification)."
    )
    parser.add_argument("token", nargs="?", help="the JWT string (optional; prefer stdin/--file)")
    parser.add_argument("-f", "--file", help="read the token from this file")
    args = parser.parse_args()

    try:
        token = _read_token(args)
        header, payload = decode_jwt(token)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print("=== JWT header ===")
    print(json.dumps(header, indent=2, sort_keys=True))
    print("\n=== JWT claims (payload) ===")
    print(json.dumps(payload, indent=2, sort_keys=True))

    present = [(k, payload[k]) for k in HIGHLIGHT if k in payload]
    if present:
        print("\n=== Key claims for Vault role binding ===")
        for key, value in present:
            print(f"  {key:10} = {value}")
        print(
            "\nMap these onto the Vault JWT role:\n"
            "  iss                   -> auth/<mount>/config bound_issuer / oidc_discovery_url\n"
            "  aud                   -> role bound_audiences (must equal the CI ID-token credential audience)\n"
            "  sub                   -> role user_claim / bound_claims\n"
            "  job                   -> role bound_claims (pin to the folder/job that should hold the policy)\n"
            "  group_name/job_name   -> role claim_mappings -> templated-policy metadata\n"
            "                           (secret/data/project/<group_name>/<job_name>/*)"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
