#!/usr/bin/env python3
"""Validate that a CloudBees CI controller's OIDC endpoints are reachable.

This is the operator-side check for **firewall flow #1** in the architecture:
Vault must be able to reach each CI controller's OIDC discovery document and
JWKS to validate per-build JWTs. When that flow is not open, JWT login fails
*silently* on the Vault side — this script catches it early.

Run it from a host that is *permitted* to reach the controller (a Vault node
or an approved jump host), pointing at the controller's base URL. It fetches:
    <base>/oidc/.well-known/openid-configuration
    <the jwks_uri advertised in that document>
and reports whether each is reachable and well-formed.

Airgap-safe: standard library only (urllib, ssl, json). No secrets are sent
or read — these are public discovery endpoints. Supports a private CA bundle
via --cacert for corporate TLS.

Usage:
    python3 check_oidc_discovery.py https://ctrlA.ci.corp.example.com
    python3 check_oidc_discovery.py https://ctrlA.ci.corp.example.com --cacert /etc/pki/corp-ca.pem
    python3 check_oidc_discovery.py https://ctrlA.ci.corp.example.com --insecure   # skip TLS verify (diagnostic only)

Exit codes: 0 = both endpoints reachable and valid, 1 = a check failed.

Requires: Python 3.6+ (standard library only — no pip install).
"""
import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from typing import Optional

TIMEOUT = 10  # seconds


def _fetch(url: str, ctx: ssl.SSLContext) -> dict:
    """GET a URL and parse the JSON body. Raises on network/parse error."""
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=ctx) as resp:
        body = resp.read().decode("utf-8")
    return json.loads(body)


def _build_context(cacert: Optional[str], insecure: bool) -> ssl.SSLContext:
    if insecure:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        return ctx
    if cacert:
        return ssl.create_default_context(cafile=cacert)
    return ssl.create_default_context()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check a CloudBees CI controller's OIDC discovery + JWKS reachability (firewall flow #1)."
    )
    parser.add_argument("base_url", help="controller base URL, e.g. https://ctrlA.ci.corp.example.com")
    parser.add_argument("--cacert", help="path to a private CA bundle (PEM) for TLS verification")
    parser.add_argument(
        "--insecure", action="store_true",
        help="skip TLS certificate verification (diagnostic use only)",
    )
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    discovery_url = f"{base}/oidc/.well-known/openid-configuration"
    ctx = _build_context(args.cacert, args.insecure)

    if args.insecure:
        print("WARNING: TLS verification disabled (--insecure) — diagnostic only.\n", file=sys.stderr)

    # 1) Discovery document
    print(f"[1/2] Fetching discovery: {discovery_url}")
    try:
        discovery = _fetch(discovery_url, ctx)
    except (urllib.error.URLError, urllib.error.HTTPError, ssl.SSLError, OSError, ValueError) as exc:
        print(f"  FAIL: could not fetch/parse discovery document: {exc}", file=sys.stderr)
        print("  -> Firewall flow #1 is likely NOT open (Vault -> controller /oidc/**),", file=sys.stderr)
        print("     or the controller Jenkins URL is wrong. Fix this before configuring Vault.", file=sys.stderr)
        return 1

    issuer = discovery.get("issuer")
    jwks_uri = discovery.get("jwks_uri")
    print(f"  OK: issuer   = {issuer}")
    print(f"  OK: jwks_uri = {jwks_uri}")
    if not jwks_uri:
        print("  FAIL: discovery document has no jwks_uri", file=sys.stderr)
        return 1

    # 2) JWKS
    print(f"\n[2/2] Fetching JWKS: {jwks_uri}")
    try:
        jwks = _fetch(jwks_uri, ctx)
    except (urllib.error.URLError, urllib.error.HTTPError, ssl.SSLError, OSError, ValueError) as exc:
        print(f"  FAIL: could not fetch/parse JWKS: {exc}", file=sys.stderr)
        return 1

    keys = jwks.get("keys")
    if not isinstance(keys, list) or not keys:
        print("  FAIL: JWKS has no keys — Vault cannot validate JWTs", file=sys.stderr)
        return 1
    print(f"  OK: JWKS advertises {len(keys)} signing key(s)")

    print("\nRESULT: OIDC discovery and JWKS are reachable and well-formed.")
    print("Set the Vault JWT auth mount's oidc_discovery_url / bound_issuer to:")
    print(f"  {issuer}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
