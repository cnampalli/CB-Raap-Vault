# 07 — Trust files

**Who:** Venafi team · **Needs:** nothing · **Gives:** `tpp-chain.pem`, `enterprise-root.pem`,
`enterprise-issuing.pem` to the Vault and K8s teams

| File | What it is | Used by |
|---|---|---|
| `tpp-chain.pem` | Root + intermediates of the **TPP web server** certificate | Vault nodes, to trust TPP |
| `enterprise-root.pem`, `enterprise-issuing.pem` | Root and issuing CA of the **CA template** (A10) | The proof, to check issued certs |

## Step 1 — Export the TPP web chain

1. ⌨ Show the chain TPP presents:
   ```bash
   openssl s_client -connect tpp.corp.example.com:443 -showcerts </dev/null
   ```
2. 🖱 Copy each **issuer** certificate (every `-----BEGIN CERTIFICATE-----` block **after the first**)
   into `tpp-chain.pem`. Add the root from your PKI team if TPP doesn't send it.
3. ⌨ Check it:
   ```bash
   openssl s_client -connect tpp.corp.example.com:443 -CAfile tpp-chain.pem </dev/null 2>/dev/null \
     | grep 'Verify return code'
   ```

**Expected:** `Verify return code: 0 (ok)`.

## Step 2 — Export the enterprise CA certificates

1. 🖱 Get the root and issuing CA certificates of the CA in A10 from your PKI team's published location
   (or the CA console → CA certificate → export as Base-64 / PEM).
2. 🖱 Save as `enterprise-root.pem` and `enterprise-issuing.pem`.
3. ⌨ Check them:
   ```bash
   openssl x509 -in enterprise-root.pem -noout -subject -issuer   # subject = issuer (self-signed)
   openssl verify -CAfile enterprise-root.pem enterprise-issuing.pem
   ```

**Expected:** the root is self-signed; `enterprise-issuing.pem: OK`.

## Step 3 — Hand off

1. ⌨ `sha256sum tpp-chain.pem enterprise-root.pem enterprise-issuing.pem`
2. 🖱 Send the files through your normal artifact process. Send the SHA-256 values **separately**
   (e.g. in the ticket).

**Expected:** the receiving teams confirm the hashes match.

## Done when

- [ ] Three PEM files handed over, hashes confirmed by the receivers
