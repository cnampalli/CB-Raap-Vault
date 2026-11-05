# 16 — Monitoring and day 2

**Who:** Vault team (alerts), Venafi team (yearly re-connect) · **Needs:** chunk 15 signed off
**Gives:** alerts live, renewal owned

## Step 1 — Log alerts (Vault team)

🖱 On the Vault server logs of **all** nodes, alert on:
- `invalid_grant`
- `error validating access token`
- `401` together with `venafi`
- `checksums did not match`
- `could not execute files`

**Expected:** a test log line raises an alert. 🖱 Record the alert rule IDs (evidence **E14**).

## Step 2 — Daily synthetic check (Vault team)

🖱 Schedule a daily CI job that runs `tools/venafi_pki_proof.py` (chunk 15 Step 2) with `--ttl 1h --revoke`.
Alert when it exits non-zero.

**Expected:** the first scheduled run passes.

## Step 3 — Renewal calendar (both)

🖱 Check the `refresh_until − 30 days` entry from chunk 11 Step 4 exists.

**Expected:** entry present, both teams invited.

## Day-2 events

| Event | Owner | Do |
|---|---|---|
| 30 days before `refresh_until` | Venafi + Vault | Repeat **chunk 11**. Nothing else warns you, and after that date all issuance stops |
| TPP web cert renewed with a new chain | Venafi | New `tpp-chain.pem` (chunk 07) to the Vault team; they redo chunk 08 Step 4 **before** the switch |
| `svc-vault-pki` password rotated | Venafi | No effect on live tokens. Record it |
| AD account disabled / expired | Venafi + AD | No effect until the next re-connect, which will fail. Keep it enabled |
| Folder policy changed | Venafi | Tell the Vault team; role key size/curve may need to match |
| Plugin upgrade (e.g. v0.17.0) | Vault | Guide 08 §12 |
| New namespace wants its own mount | Vault + Venafi | Its **own** TPP identity and tokens. Never copy `tpp` |
| Raft snapshot | Vault | Treat it as secret material: it holds live tokens |
