#!/usr/bin/env python3
"""Prove that Vault's Venafi PKI secrets engine issues certificates through Venafi TPP.

Produces an evidence report (Markdown + JSON) that a reviewer can attach to a change
ticket. It answers, with artifacts, the question "does Venafi really back Vault's PKI?":

  P1  Vault is reachable and unsealed.
  P2  The mount is the venafi-pki-backend plugin, pinned to the expected version.
  P3  (admin token only) the catalog entry carries the expected binary SHA-256.
  P4  A certificate is issued through Vault (or read from --cert-file, e.g. a
      cert-manager tls.crt from Kubernetes).
  P5  The private key returned by Vault matches the certificate (issue mode only).
  P6  The chain validates with openssl, and the leaf is NOT signed by a Vault CA.
  P7  The chain validates against the enterprise root the PKI team gave you
      out of band (--trust-root). This does not trust anything Vault returned.
  P8  TPP has the certificate in its inventory, under the expected policy folder.
  P9  TPP records its origin as "HashiCorp Vault" (the plugin sets this on every request).
  P10 A name outside policy is refused (ACL 403, or TPP policy error).
  P11 (optional, --revoke) the test certificate is revoked through Vault.

Python 3.6+, standard library only, plus the `openssl` CLI for chain checks.

Secrets: VAULT_TOKEN and TPP_TOKEN are read from the environment only, never from
argv. The private key is never printed or written to the report; it is held in a
0600 temp file only long enough to compare it with the certificate.

Examples:
    # Issue a short-lived test cert through Vault and prove it end to end
    export VAULT_ADDR=https://vault-vip.corp.example.com:8200 VAULT_TOKEN=... TPP_TOKEN=...
    python3 tools/venafi_pki_proof.py --namespace AUT --mount venafi-pki --role web-aut \\
        --common-name proof-$(date +%s).aut.corp.example.com --ttl 24h \\
        --tpp-url https://tpp.corp.example.com --tpp-ca /etc/pki/tpp-chain.pem \\
        --expect-folder 'Certificates\\Automation\\Vault\\AUT\\Web' \\
        --trust-root /etc/pki/enterprise-root.pem --negative-cn evil.example.com --revoke

    # Prove a certificate cert-manager put in a Kubernetes secret
    kubectl -n demo get secret demo-tls -o jsonpath='{.data.tls\\.crt}' | base64 -d > tls.crt
    python3 tools/venafi_pki_proof.py --cert-file tls.crt --tpp-url ... --expect-folder ...

Exit codes: 0 all checks PASS or SKIP, 1 at least one FAIL, 2 usage/config error.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, List, Optional, Tuple

PEM_RE = re.compile(r"-----BEGIN CERTIFICATE-----.+?-----END CERTIFICATE-----", re.S)
EXPECTED_ORIGIN = "HashiCorp Vault"


# --------------------------------------------------------------------------- results
class Check(object):
    def __init__(self, cid, title, status, detail, evidence=None):
        # type: (str, str, str, str, Optional[Dict[str, Any]]) -> None
        self.cid = cid
        self.title = title
        self.status = status  # PASS | FAIL | SKIP | INFO
        self.detail = detail
        self.evidence = evidence or {}

    def as_dict(self):
        return {"id": self.cid, "title": self.title, "status": self.status,
                "detail": self.detail, "evidence": self.evidence}


class Report(object):
    def __init__(self):
        self.checks = []  # type: List[Check]
        self.facts = {}  # type: Dict[str, Any]

    def add(self, cid, title, status, detail, evidence=None):
        c = Check(cid, title, status, detail, evidence)
        self.checks.append(c)
        print("[{:<4}] {:<4} {} — {}".format(c.status, cid, title, detail))
        return c

    @property
    def failed(self):
        return any(c.status == "FAIL" for c in self.checks)


# --------------------------------------------------------------------------- http
class Http(object):
    """Tiny JSON-over-HTTPS client. TLS is always verified; pass a CA file for private CAs."""

    def __init__(self, base, ca_file=None, headers=None, timeout=60):
        # type: (str, Optional[str], Optional[Dict[str, str]], int) -> None
        self.base = base.rstrip("/")
        self.headers = headers or {}
        self.timeout = timeout
        self.ctx = None
        if self.base.startswith("https://"):
            self.ctx = ssl.create_default_context(cafile=ca_file) if ca_file else ssl.create_default_context()

    def call(self, method, path, body=None, query=None, extra_headers=None):
        # type: (str, str, Optional[Dict[str, Any]], Optional[Dict[str, str]], Optional[Dict[str, str]]) -> Tuple[int, Any]
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        hdrs = dict(self.headers)
        hdrs.update(extra_headers or {})
        if data is not None:
            hdrs["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            resp = urllib.request.urlopen(req, timeout=self.timeout, context=self.ctx)
            status, raw = resp.getcode(), resp.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
        except urllib.error.URLError as e:
            return 0, {"errors": ["connection failed: {}".format(e.reason)]}
        try:
            return status, json.loads(raw.decode() or "{}")
        except ValueError:
            return status, {"raw": raw.decode(errors="replace")[:500]}


def errors_of(payload):
    # type: (Any) -> str
    if isinstance(payload, dict):
        for key in ("errors", "Error", "error"):
            if key in payload:
                return str(payload[key])[:300]
    return str(payload)[:300]


# --------------------------------------------------------------------------- x509 via openssl
def have_openssl():
    return shutil.which("openssl") is not None


def run(cmd, stdin=None):
    # type: (List[str], Optional[str]) -> Tuple[int, str]
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, universal_newlines=True)
    out, _ = p.communicate(stdin)
    return p.returncode, out.strip()


def pem_blocks(text):
    # type: (str) -> List[str]
    return [m.group(0).strip() + "\n" for m in PEM_RE.finditer(text or "")]


def der_of(pem):
    # type: (str) -> bytes
    body = "".join(l for l in pem.strip().splitlines() if not l.startswith("-----"))
    return base64.b64decode(body)


def cert_facts(pem):
    # type: (str) -> Dict[str, Any]
    der = der_of(pem)
    facts = {
        "sha1_thumbprint": hashlib.sha1(der).hexdigest().upper(),
        "sha256_fingerprint": hashlib.sha256(der).hexdigest().upper(),
    }  # type: Dict[str, Any]
    if have_openssl():
        rc, out = run(["openssl", "x509", "-noout", "-subject", "-issuer", "-serial",
                       "-startdate", "-enddate", "-nameopt", "RFC2253"], pem)
        if rc == 0:
            for line in out.splitlines():
                k, _, v = line.partition("=")
                facts[{"subject": "subject", "issuer": "issuer", "serial": "serial_hex",
                       "notBefore": "not_before", "notAfter": "not_after"}.get(k.strip(), k.strip())] = v.strip()
        rc, out = run(["openssl", "x509", "-noout", "-ext", "subjectAltName"], pem)
        if rc == 0:
            facts["sans"] = [s.strip() for s in out.split("\n", 1)[-1].split(",") if s.strip()]
    return facts


def write_tmp(dirpath, name, content):
    # type: (str, str, str) -> str
    path = os.path.join(dirpath, name)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    return path


def openssl_verify(tmp, leaf, intermediates, root):
    # type: (str, str, List[str], str) -> Tuple[bool, str]
    leaf_p = write_tmp(tmp, "leaf.pem", leaf)
    root_p = write_tmp(tmp, "root.pem", root)
    cmd = ["openssl", "verify", "-CAfile", root_p]
    if intermediates:
        cmd += ["-untrusted", write_tmp(tmp, "inter.pem", "".join(intermediates))]
    rc, out = run(cmd + [leaf_p])
    return rc == 0, out.replace(leaf_p + ": ", "leaf: ")


def split_chain(chain):
    # type: (List[str]) -> Tuple[List[str], Optional[str]]
    """Return (intermediates, root) from a list of CA PEMs; root = the self-signed one."""
    inters, root = [], None
    for pem in chain:
        f = cert_facts(pem)
        if f.get("subject") and f.get("subject") == f.get("issuer"):
            root = pem
        else:
            inters.append(pem)
    return inters, root


# --------------------------------------------------------------------------- vault steps
def vault_checks(args, rep, vault):
    # type: (argparse.Namespace, Report, Http) -> Optional[Dict[str, Any]]
    st, body = vault.call("GET", "/v1/sys/health", query={"standbyok": "true", "perfstandbyok": "true"})
    if st in (200, 429, 472, 473) and not body.get("sealed", True):
        rep.add("P1", "Vault reachable and unsealed", "PASS",
                "HTTP {} version {}".format(st, body.get("version")), {"version": body.get("version")})
        rep.facts["vault_version"] = body.get("version")
    else:
        rep.add("P1", "Vault reachable and unsealed", "FAIL", "HTTP {} {}".format(st, errors_of(body)))
        return None

    st, body = vault.call("GET", "/v1/sys/internal/ui/mounts/{}".format(args.mount))
    data = body.get("data", {}) if isinstance(body, dict) else {}
    mtype = data.get("type")
    version = data.get("running_plugin_version") or data.get("plugin_version")
    if st == 200 and mtype:
        ok_type = mtype == args.plugin_name
        ok_ver = (not args.expect_plugin_version) or version == args.expect_plugin_version
        rep.add("P2", "Mount runs the Venafi plugin at the pinned version",
                "PASS" if (ok_type and ok_ver) else "FAIL",
                "type={} version={} (expected {} {})".format(mtype, version or "n/a", args.plugin_name,
                                                             args.expect_plugin_version or "any"),
                {"type": mtype, "plugin_version": version})
    else:
        rep.add("P2", "Mount runs the Venafi plugin at the pinned version", "FAIL",
                "cannot read mount {}: HTTP {} {}".format(args.mount, st, errors_of(body)))

    if args.expect_sha256:
        q = {"version": args.expect_plugin_version} if args.expect_plugin_version else None
        st, body = vault.call("GET", "/v1/sys/plugins/catalog/secret/{}".format(args.plugin_name), query=q,
                              extra_headers={"X-Vault-Namespace": ""})
        if st == 200:
            sha = body.get("data", {}).get("sha256")
            rep.add("P3", "Catalog entry carries the expected binary SHA-256",
                    "PASS" if sha == args.expect_sha256 else "FAIL",
                    "catalog sha256={}".format(sha), {"catalog_sha256": sha})
        else:
            rep.add("P3", "Catalog entry carries the expected binary SHA-256", "SKIP",
                    "HTTP {} (needs a root-namespace token with sudo on sys/plugins/catalog)".format(st))
    else:
        rep.add("P3", "Catalog entry carries the expected binary SHA-256", "SKIP", "--expect-sha256 not given")

    req = {"common_name": args.common_name, "ttl": args.ttl}
    if args.alt_names:
        req["alt_names"] = args.alt_names
    t0 = time.time()
    st, body = vault.call("POST", "/v1/{}/issue/{}".format(args.mount, args.role), body=req)
    took = round(time.time() - t0, 1)
    if st == 200 and body.get("data", {}).get("certificate"):
        d = body["data"]
        rep.add("P4", "Certificate issued through Vault", "PASS",
                "issue/{} in {}s, serial {}".format(args.role, took, d.get("serial_number")),
                {"serial_number": d.get("serial_number"), "lease_id": body.get("lease_id") or None,
                 "issue_seconds": took})
        return d
    rep.add("P4", "Certificate issued through Vault", "FAIL", "HTTP {} {}".format(st, errors_of(body)))
    return None


def negative_check(args, rep, vault):
    # type: (argparse.Namespace, Report, Http) -> None
    if not args.negative_cn:
        rep.add("P10", "Name outside policy is refused", "SKIP", "--negative-cn not given")
        return
    st, body = vault.call("POST", "/v1/{}/issue/{}".format(args.mount, args.role),
                          body={"common_name": args.negative_cn, "ttl": args.ttl})
    if st == 403:
        rep.add("P10", "Name outside policy is refused", "PASS",
                "{} -> HTTP 403 at the Vault ACL".format(args.negative_cn), {"layer": "vault-acl"})
    elif st in (400, 500):
        rep.add("P10", "Name outside policy is refused", "PASS",
                "{} -> HTTP {} from the plugin/TPP: {}".format(args.negative_cn, st, errors_of(body)),
                {"layer": "tpp-or-plugin", "error": errors_of(body)})
    elif st == 200:
        serial = body.get("data", {}).get("serial_number")
        rep.add("P10", "Name outside policy is refused", "FAIL",
                "{} was ISSUED (serial {}). Tighten the ACL and the TPP domain whitelist, then revoke it."
                .format(args.negative_cn, serial), {"leaked_serial": serial})
    else:
        rep.add("P10", "Name outside policy is refused", "FAIL", "HTTP {} {}".format(st, errors_of(body)))


# --------------------------------------------------------------------------- tpp steps
def find_in_tpp(args, tpp, facts):
    # type: (argparse.Namespace, Http, Dict[str, Any]) -> Tuple[int, Dict[str, Any], str]
    filters = [("Thumbprint", facts["sha1_thumbprint"])]
    if facts.get("serial_hex"):
        filters.append(("Serial", facts["serial_hex"].replace(":", "").upper()))
    deadline = time.time() + args.tpp_wait
    last = (0, {}, "")
    while True:
        for key, value in filters:
            st, body = tpp.call("GET", "/vedsdk/certificates/", query={key: value})
            last = (st, body if isinstance(body, dict) else {}, key)
            if st == 200 and body.get("TotalCount", len(body.get("Certificates", []))) > 0:
                return last
            if st in (401, 403):
                return last
        if time.time() >= deadline:
            return last
        time.sleep(5)


def search_key(obj, needle):
    # type: (Any, str) -> List[Tuple[str, Any]]
    hits = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if needle.lower() in str(k).lower():
                hits.append((k, v))
            hits.extend(search_key(v, needle))
    elif isinstance(obj, list):
        for v in obj:
            hits.extend(search_key(v, needle))
    return hits


def tpp_checks(args, rep, facts):
    # type: (argparse.Namespace, Report, Dict[str, Any]) -> None
    token = os.environ.get("TPP_TOKEN")
    if not (args.tpp_url and token):
        for cid, title in (("P8", "TPP inventory has the certificate"), ("P9", "TPP origin is HashiCorp Vault")):
            rep.add(cid, title, "SKIP", "--tpp-url and TPP_TOKEN (scope: certificate) not provided")
        return
    tpp = Http(args.tpp_url, args.tpp_ca, {"Authorization": "Bearer " + token})
    st, body, key = find_in_tpp(args, tpp, facts)
    certs = body.get("Certificates") or []
    if st != 200 or not certs:
        rep.add("P8", "TPP inventory has the certificate", "FAIL",
                "search by {} -> HTTP {} {} (waited {}s)".format(key, st, errors_of(body) if st != 200 else "0 results",
                                                               args.tpp_wait))
        rep.add("P9", "TPP origin is HashiCorp Vault", "SKIP", "certificate not found in TPP")
        return
    c = certs[0]
    dn = c.get("DN", "")
    folder_ok = True
    if args.expect_folder:
        want = "\\VED\\Policy\\" + args.expect_folder.strip("\\")
        folder_ok = dn.lower().startswith(want.lower() + "\\")
    rep.add("P8", "TPP inventory has the certificate", "PASS" if folder_ok else "FAIL",
            "found by {}: {}{}".format(key, dn, "" if folder_ok else " (NOT under the expected folder)"),
            {"tpp_dn": dn, "tpp_guid": c.get("Guid"), "tpp_created_on": c.get("CreatedOn"),
             "tpp_schema_class": c.get("SchemaClass")})
    rep.facts["tpp_guid"] = c.get("Guid")

    guid = (c.get("Guid") or "").strip("{}")
    origin = None
    if guid:
        st, detail = tpp.call("GET", "/vedsdk/certificates/" + urllib.parse.quote("{%s}" % guid))
        if st == 200:
            for k, v in search_key(detail, "origin"):
                origin = v if isinstance(v, str) else (v[0] if isinstance(v, list) and v else origin)
                if origin:
                    break
            rep.facts["tpp_detail_keys"] = sorted(detail.keys())[:40] if isinstance(detail, dict) else []
    if origin is None:
        rep.add("P9", "TPP origin is HashiCorp Vault", "INFO",
                "the details API did not return an Origin field on this TPP version; confirm in the TPP UI: "
                "certificate {} -> Settings -> Origin = '{}'".format(dn, EXPECTED_ORIGIN))
    else:
        rep.add("P9", "TPP origin is HashiCorp Vault", "PASS" if EXPECTED_ORIGIN.lower() in str(origin).lower() else "FAIL",
                "Origin = {}".format(origin), {"tpp_origin": origin})


# --------------------------------------------------------------------------- crypto checks
def crypto_checks(args, rep, leaf, chain, private_key):
    # type: (argparse.Namespace, Report, str, List[str], Optional[str]) -> Dict[str, Any]
    facts = cert_facts(leaf)
    rep.facts["certificate"] = facts
    if not have_openssl():
        for cid in ("P5", "P6", "P7"):
            rep.add(cid, "openssl checks", "SKIP", "openssl CLI not found")
        return facts
    tmp = tempfile.mkdtemp(prefix="venafi-proof-")
    try:
        if private_key:
            kp = write_tmp(tmp, "key.pem", private_key)
            rc1, pub_cert = run(["openssl", "x509", "-noout", "-pubkey"], leaf)
            rc2, pub_key = run(["openssl", "pkey", "-in", kp, "-pubout"])
            os.remove(kp)
            match = rc1 == 0 and rc2 == 0 and pub_cert == pub_key
            rep.add("P5", "Private key matches the certificate", "PASS" if match else "FAIL",
                    "public keys {}".format("match" if match else "differ"))
        else:
            rep.add("P5", "Private key matches the certificate", "SKIP",
                    "no private key (sign/ or --cert-file mode: the key never left the workload)")

        inters, root = split_chain(chain)
        vault_ca = "vault" in (facts.get("issuer") or "").lower()
        if root:
            ok, out = openssl_verify(tmp, leaf, inters, root)
            rep.add("P6", "Chain validates (as returned)", "PASS" if ok and not vault_ca else "FAIL",
                    "{} | issuer: {}{}".format(out.splitlines()[-1] if out else "", facts.get("issuer"),
                                               " (issuer looks like a Vault CA!)" if vault_ca else ""),
                    {"chain_length": len(chain), "root_subject": cert_facts(root).get("subject")})
        else:
            rep.add("P6", "Chain validates (as returned)", "FAIL" if not args.trust_root else "INFO",
                    "no self-signed root in the returned chain ({} CA certs); use --trust-root".format(len(chain)))

        if args.trust_root:
            with open(args.trust_root) as f:
                roots = pem_blocks(f.read())
            ok, out = openssl_verify(tmp, leaf, inters, "".join(roots))
            rep.add("P7", "Chain validates to the enterprise root (out-of-band)", "PASS" if ok else "FAIL",
                    out.splitlines()[-1] if out else "", {"trust_root": os.path.basename(args.trust_root)})
        else:
            rep.add("P7", "Chain validates to the enterprise root (out-of-band)", "SKIP", "--trust-root not given")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return facts


# --------------------------------------------------------------------------- report
def write_report(args, rep):
    # type: (argparse.Namespace, Report) -> Tuple[str, str]
    os.makedirs(args.report_dir, exist_ok=True)
    stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    base = os.path.join(args.report_dir, "venafi-pki-proof-{}".format(stamp))
    meta = {
        "generated_utc": stamp, "mode": "cert-file" if args.cert_file else "issue",
        "vault_addr": args.vault_addr, "namespace": args.namespace, "mount": args.mount, "role": args.role,
        "tpp_url": args.tpp_url, "expect_folder": args.expect_folder, "result": "FAIL" if rep.failed else "PASS",
    }
    with open(base + ".json", "w") as f:
        json.dump({"meta": meta, "facts": rep.facts, "checks": [c.as_dict() for c in rep.checks]}, f, indent=2)
    c = rep.facts.get("certificate", {})
    lines = [
        "# Venafi ⇄ Vault PKI integration — evidence report", "",
        "| | |", "|---|---|",
        "| Result | **{}** |".format(meta["result"]),
        "| Generated (UTC) | {} |".format(stamp),
        "| Mode | {} |".format(meta["mode"]),
        ("| Vault | not queried (cert-file mode) |" if args.cert_file else
         "| Vault | {} (version {}) ns `{}` mount `{}` role `{}` |".format(
             args.vault_addr, rep.facts.get("vault_version", "n/a"), args.namespace or "root", args.mount, args.role)),
        "| TPP | {} folder `{}` |".format(args.tpp_url or "not queried", args.expect_folder or "-"), "",
        "## Checks", "", "| ID | Check | Result | Detail |", "|---|---|---|---|",
    ]
    for ch in rep.checks:
        lines.append("| {} | {} | {} | {} |".format(ch.cid, ch.title, ch.status, ch.detail.replace("|", "\\|")))
    lines += ["", "## Certificate", "", "| Field | Value |", "|---|---|"]
    for k in ("subject", "issuer", "serial_hex", "not_before", "not_after", "sha1_thumbprint", "sha256_fingerprint"):
        lines.append("| {} | `{}` |".format(k, c.get(k, "n/a")))
    lines.append("| sans | {} |".format(", ".join("`{}`".format(s) for s in c.get("sans", [])) or "n/a"))
    lines += ["", "_No private key material is included in this report._", ""]
    with open(base + ".md", "w") as f:
        f.write("\n".join(lines))
    return base + ".md", base + ".json"


# --------------------------------------------------------------------------- main
def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--vault-addr", default=os.environ.get("VAULT_ADDR"))
    p.add_argument("--vault-ca", default=os.environ.get("VAULT_CACERT"), help="CA bundle for Vault's TLS cert")
    p.add_argument("--namespace", default=os.environ.get("VAULT_NAMESPACE", ""))
    p.add_argument("--mount", default="venafi-pki")
    p.add_argument("--role", help="Venafi PKI role, e.g. web-aut")
    p.add_argument("--plugin-name", default="venafi-pki-backend")
    p.add_argument("--expect-plugin-version", default="v0.16.0")
    p.add_argument("--expect-sha256", help="binary SHA-256 the catalog must carry (needs admin token)")
    p.add_argument("--common-name", help="CN for the test certificate (issue mode)")
    p.add_argument("--alt-names", help="comma-separated SANs; include the CN — the plugin does not add it")
    p.add_argument("--ttl", default="24h")
    p.add_argument("--negative-cn", help="a CN that policy must refuse, e.g. evil.example.com")
    p.add_argument("--revoke", action="store_true", help="revoke the test certificate at the end")
    p.add_argument("--cert-file", help="verify an existing PEM (leaf + chain), e.g. a cert-manager tls.crt")
    p.add_argument("--chain-file", help="extra CA PEMs for --cert-file (e.g. the secret's ca.crt)")
    p.add_argument("--trust-root", help="enterprise root CA PEM obtained from the PKI team out of band")
    p.add_argument("--tpp-url", help="TPP base URL, e.g. https://tpp.corp.example.com")
    p.add_argument("--tpp-ca", help="CA bundle for TPP's web certificate")
    p.add_argument("--tpp-wait", type=int, default=60, help="seconds to wait for TPP to index the cert")
    p.add_argument("--expect-folder", help="policy folder below \\VED\\Policy, e.g. Certificates\\Vault\\AUT\\Web")
    p.add_argument("--report-dir", default=".tmp/venafi-proof")
    a = p.parse_args(argv)
    if not a.cert_file:
        missing = [n for n, v in (("--vault-addr/VAULT_ADDR", a.vault_addr), ("--role", a.role),
                                  ("--common-name", a.common_name), ("VAULT_TOKEN", os.environ.get("VAULT_TOKEN")))
                   if not v]
        if missing:
            p.error("issue mode needs: " + ", ".join(missing))
    return a


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    rep = Report()
    private_key = None
    if args.cert_file:
        with open(args.cert_file) as f:
            blocks = pem_blocks(f.read())
        if args.chain_file:
            with open(args.chain_file) as f:
                blocks += [b for b in pem_blocks(f.read()) if b not in blocks]
        if not blocks:
            print("no PEM certificate found in --cert-file", file=sys.stderr)
            return 2
        leaf, chain = blocks[0], blocks[1:]
        rep.add("P4", "Certificate read from file", "PASS",
                "{} ({} CA cert(s) alongside)".format(os.path.basename(args.cert_file), len(chain)))
        for cid, title in (("P1", "Vault reachable and unsealed"), ("P2", "Mount runs the Venafi plugin"),
                           ("P3", "Catalog SHA-256")):
            rep.add(cid, title, "SKIP", "cert-file mode")
        vault = None
    else:
        hdrs = {"X-Vault-Token": os.environ["VAULT_TOKEN"]}
        if args.namespace:
            hdrs["X-Vault-Namespace"] = args.namespace
        vault = Http(args.vault_addr, args.vault_ca, hdrs, timeout=240)
        data = vault_checks(args, rep, vault)
        if data is None:
            md, js = write_report(args, rep)
            print("\nreport: {}\n        {}".format(md, js))
            return 1
        leaf = data["certificate"].strip() + "\n"
        chain = [c.strip() + "\n" for c in (data.get("ca_chain") or [])] or pem_blocks(data.get("issuing_ca", ""))
        private_key = data.get("private_key")

    facts = crypto_checks(args, rep, leaf, chain, private_key)
    private_key = None
    tpp_checks(args, rep, facts)

    if vault is not None:
        negative_check(args, rep, vault)
        if args.revoke:
            serial = rep.checks[[c.cid for c in rep.checks].index("P4")].evidence.get("serial_number")
            st, body = vault.call("POST", "/v1/{}/revoke/{}".format(args.mount, args.role),
                                  body={"serial_number": serial})
            rep.add("P11", "Test certificate revoked through Vault", "PASS" if st in (200, 204) else "FAIL",
                    "HTTP {} {}".format(st, "" if st in (200, 204) else errors_of(body)))
        else:
            rep.add("P11", "Test certificate revoked through Vault", "SKIP", "--revoke not given")

    md, js = write_report(args, rep)
    print("\nresult: {}\nreport: {}\n        {}".format("FAIL" if rep.failed else "PASS", md, js))
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
