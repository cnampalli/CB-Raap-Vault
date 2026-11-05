# 03 — Check the TPP platform

**Who:** Venafi team · **Needs:** nothing · **Gives:** A1 (URL), A2 (version)

## Step 1 — Record the version

1. 🖱 Sign in to Aperture → **Help** ► **About**.
2. 🖱 Write the version into A2.

**Expected:** version **20.1 or later** (API integrations need it).

## Step 2 — WebSDK is up

⌨ From your admin host:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://tpp.corp.example.com/vedsdk/
```
**Expected:** `200` or `401`. Both prove the API is answering.

## Step 3 — Same certificate on every TPP node

⌨ For each TPP node behind the load balancer:
```bash
openssl s_client -connect <tpp-node>:443 -servername tpp.corp.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -fingerprint -sha256
```
**Expected:** the same issuer and fingerprint on every node.

## Done when

- [ ] A1 and A2 filled in
- [ ] WebSDK answers; one certificate chain across all nodes

## If it fails

| You see | Fix |
|---|---|
| `000` / timeout | Network or load balancer. Fix before going further |
| Different fingerprints per node | Make the TPP web certificates consistent first. Vault trusts one chain |
