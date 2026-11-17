# Tools — the Execution (WAT Layer 3)

Python scripts that do the actual, deterministic work: API calls, data
transformations, file operations, database queries. These should be consistent,
testable, and fast.

## Conventions

- **Target Python 3.6+, standard library only.** CI agents run Python 3.6.8 in an
  airgapped environment, so scripts must not use 3.7+ syntax (no PEP 585 `list[...]`,
  no PEP 604 `X | None`, no `from __future__ import annotations`) and must not require
  `pip install` — no third-party packages. Use `typing.List`/`Optional` for annotations.
- One script per task, verb-first, snake_case — e.g. `scrape_single_site.py`.
- Read credentials from `.env` (via environment variables). Never hard-code
  secrets, and never store them anywhere but `.env`.
- Fail loudly with clear error messages and non-zero exit codes so the agent can
  react and recover.
- Write intermediates to `.tmp/`; final deliverables go to cloud services.

## Before adding a new tool

Check whether an existing script already covers the task. Only create a new one
when nothing here fits.

## `venafi_pki_proof.py`

Evidence report that Vault's Venafi PKI secrets engine really issues through Venafi TPP
(guide `vault-integrations/09` §5). Checks P1–P11: Vault health, mount type/version, catalog SHA-256,
issuance, key/cert match, chain (as returned and against an out-of-band enterprise root), TPP
inventory under the expected folder, TPP `Origin = HashiCorp Vault`, a refused out-of-policy name,
and revoke. `--cert-file` mode proves a certificate taken from Kubernetes (cert-manager `tls.crt`).

```bash
export VAULT_ADDR=... VAULT_TOKEN=<consumer token> TPP_TOKEN=<read-only TPP token>
python3 tools/venafi_pki_proof.py --namespace AUT --role web-aut --common-name "$CN" --alt-names "$CN" \
  --trust-root enterprise-root.pem --tpp-url https://tpp.corp.example.com --tpp-ca tpp-chain.pem \
  --expect-folder 'Certificates\Vault\AUT\Web' --negative-cn evil.example.com --revoke
```

Tokens come from the environment only. Needs the `openssl` CLI for chain checks. Writes
`.tmp/venafi-proof/venafi-pki-proof-<UTC>.md|json` (no private key material). Exit 0 = PASS/SKIP only.

