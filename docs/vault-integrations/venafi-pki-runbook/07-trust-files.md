# 07 — Trust files

**Who:** Venafi team · **Needs:** nothing · **Gives:** `tpp-chain.pem`, `enterprise-root.pem`,
`enterprise-issuing.pem` to the Vault and K8s teams

| File | What it is | Used by |
|---|---|---|
| `tpp-chain.pem` | Root + intermediates of the **TPP web server** certificate | Vault nodes, to trust TPP |
| `enterprise-root.pem`, `enterprise-issuing.pem` | Root and issuing CA of the **CA template** (A10) | The proof, to check issued certs |

## Step 1 — Export the TPP web chain

`tpp-chain.pem` must hold **every** certificate above the TPP server certificate, **up to and
including the root**. TPP normally sends the intermediates but **not the root**, so you add it yourself.

1. ⌨ Save each certificate TPP presents into its own file, and list them:
   ```bash
   H=tpp.corp.example.com
   mkdir -p tpp-chain && cd tpp-chain && rm -f presented-*.pem
   openssl s_client -connect "$H:443" -servername "$H" -showcerts </dev/null 2>/dev/null \
     | awk '/BEGIN CERT/{n++; p=1} p{print > ("presented-" n ".pem")} /END CERT/{p=0}'
   for f in presented-*.pem; do echo "== $f"; openssl x509 -in "$f" -noout -subject -issuer; done
   ```
   **Expected:** `presented-1.pem` is the TPP server certificate. Each next file's *subject* is the
   previous file's *issuer*.

2. 🖱 Look at the **last** file. If its subject and issuer are the **same**, it's the root and you have
   everything: go to part 4. If they **differ**, its issuer is the missing certificate (usually the root).

3. Get the missing certificate. Use whichever works first:
   - **From your PKI team:** ask for the certificate whose subject is the issuer from part 2, as PEM.
   - **From the AIA link** in the last certificate:
     ```bash
     openssl x509 -in presented-N.pem -noout -text | grep 'CA Issuers'   # N = the last file
     curl -sS -o missing.crt '<the http:// URL shown>'
     openssl x509 -inform DER -in missing.crt -out missing-1.pem 2>/dev/null \
       || openssl x509 -in missing.crt -out missing-1.pem
     openssl x509 -in missing-1.pem -noout -subject -issuer
     ```
     If the URL is `ldap://`, ask your PKI team instead.
   - **From a domain-joined Windows machine:** `certlm.msc` → *Trusted Root Certification Authorities*
     → *Certificates* → find it → **All Tasks ► Export** → **Base-64 encoded X.509 (.CER)**.

   Repeat for the certificate you got (`missing-2.pem`, …) until you have one whose subject = issuer.

   **Expected:** the last certificate you added is self-signed (subject = issuer).

4. ⌨ Build the file from **everything except the server certificate**, then check it:
   ```bash
   cat $(ls presented-*.pem | grep -v '^presented-1.pem$') missing-*.pem 2>/dev/null > ../tpp-chain.pem
   cd ..
   grep -c 'BEGIN CERTIFICATE' tpp-chain.pem
   openssl s_client -connect "$H:443" -servername "$H" -CAfile tpp-chain.pem </dev/null 2>/dev/null \
     | grep 'Verify return code'
   ```

**Expected:** a count of at least 1 (usually 2–3), and `Verify return code: 0 (ok)`.

| You see | Meaning | Fix |
|---|---|---|
| `2 (unable to get issuer certificate)` | A certificate's issuer is missing from the file, usually the root | Parts 2–3 |
| `20 (unable to get local issuer certificate)` | Nothing in the file signed the server certificate | You included the wrong chain, or the file is empty. Redo part 4 |
| `19 (self-signed certificate in certificate chain)` | TPP sent a root that isn't in your file | Add that root (it's one of the `presented-*.pem`) |
| `10 (certificate has expired)` | A certificate in the chain has expired | Raise with the PKI team before going further |

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

If this also gives error 2, your PKI has a middle (policy) CA between the root and the issuing CA.
Get it as `enterprise-intermediate.pem` and verify with
`openssl verify -CAfile enterprise-root.pem -untrusted enterprise-intermediate.pem enterprise-issuing.pem`.
Then hand over `enterprise-intermediate.pem` too.

## Step 3 — Hand off

1. ⌨ `sha256sum tpp-chain.pem enterprise-root.pem enterprise-issuing.pem`
2. 🖱 Send the files through your normal artifact process. Send the SHA-256 values **separately**
   (e.g. in the ticket).

**Expected:** the receiving teams confirm the hashes match.

## Done when

- [ ] Three PEM files handed over, hashes confirmed by the receivers
