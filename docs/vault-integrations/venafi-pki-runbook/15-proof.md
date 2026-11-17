# 15 — Proof and sign-off

**Who:** Vault engineer + PKI analyst together (K8s team for E9/E11)
**Needs:** chunk 11 (and 13 for the K8s rows), `enterprise-root.pem`, `tpp-chain.pem`
**Gives:** the evidence pack E1–E14 for the change ticket

The question to answer: **"Is Venafi really governing the certificates Vault hands out?"**

## Step 1 — PKI analyst: get a read-only TPP token

⌨
```bash
export TPP_TOKEN=$(vcert getcred -u https://tpp.corp.example.com --username '<analyst>' \
  --client-id venafi-pki-proof --scope certificate --trust-bundle tpp-chain.pem --format json \
  | jq -r .access_token)
```
**Expected:** `TPP_TOKEN` set in this shell only. Valid one day.

## Step 2 — Run the proof tool

⌨ Use a **consumer** token that holds only `venafi-pki-web-aut`, not an admin token.
```bash
export VAULT_TOKEN=<consumer token>
CN="proof-$(date +%s).aut.corp.example.com"
python3 tools/venafi_pki_proof.py --namespace AUT --mount venafi-pki --role web-aut \
  --common-name "$CN" --alt-names "$CN" --ttl 24h \
  --negative-cn evil.example.com \
  --trust-root ./enterprise-root.pem \
  --tpp-url https://tpp.corp.example.com --tpp-ca ./tpp-chain.pem \
  --expect-folder 'Certificates\Vault\AUT\Web' --revoke
# with an admin token you can add:  --expect-sha256 48eec755…c99ec
```
**Expected:** every check PASS. The tool writes a Markdown + JSON report (no private keys). The
Origin check may say **INFO** if your TPP version's API doesn't return Origin. Then use the
screenshot in Step 3.

## Step 3 — PKI analyst: check it in TPP

1. 🖱 Aperture → **Inventory** → search for the proof CN (`$CN`).
2. 🖱 Open the certificate. Screenshot: **folder** `…\AUT\Web`, **Origin = HashiCorp Vault**, issuer,
   validity.
3. 🖱 After the tool's revoke: refresh and screenshot the **Revoked** status.

**Expected:** the certificate is in the right folder, Origin is HashiCorp Vault, status Revoked.

## Step 4 — Failover

1. ⌨ `vault operator step-down` on the leader. Wait for a new leader.
2. ⌨ Re-run Step 2 with a new CN.

**Expected:** PASS on the new leader (evidence **E13**).

## Step 5 — Token refresh

⌨ More than 12 h after chunk 11, re-run Step 2 **without** touching the secret.

**Expected:** PASS. Vault refreshed its own TPP token (evidence **E14**).

## The evidence pack

| # | Evidence | Proves | From |
|---|---|---|---|
| E1 | Per-node verify lines | Correct binary on every node | 08 Step 2 |
| E2 | TLS to TPP per node | Trust bundle + flow #11 per node | 08 Step 4 |
| E3 | `conn_check.sh` output | Flows #11–#14 | 09 |
| E4 | `vault plugin info` | Catalog pinned to the binary hash | 10 Step 1 |
| E5 | Mount versions | Mount runs v0.16.0 | 10 Step 2 |
| E6 | Proof report: issue, key match, chain | Cert chains to the enterprise root; no Vault CA | 15 Step 2 |
| E7 | Proof report + screenshot | TPP holds that exact cert under `…\AUT\Web` | 15 Steps 2–3 |
| E8 | Proof report + screenshot | TPP records Origin = HashiCorp Vault | 15 Steps 2–3 |
| E9 | `verify-cert-manager.sh` report | Same for a cert issued to Kubernetes | 13 Step 8 |
| E10 | Denied requests | Bad names blocked: Vault/TPP (proof), cluster (13 Step 6), TPP (06 Step 4) | 06, 13, 15 |
| E11 | Renewed serial | cert-manager renews through Vault/TPP | 13 Step 8 |
| E12 | Proof report + screenshot + CRL | Revoke through Vault reaches TPP and the CA | 15 Steps 2–3 |
| E13 | Re-run after step-down | Works on another node | 15 Step 4 |
| E14 | Re-run after 12 h | Token refresh works | 15 Step 5 |

## Done when

- [ ] E1–E14 attached to the change ticket, all PASS (E8 may be the screenshot)
- [ ] Demo resources removed: ⌨ `kubectl delete ns venafi-demo`
- [ ] Proof certificates revoked
