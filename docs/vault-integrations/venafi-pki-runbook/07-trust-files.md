# 07 — Trust files

**Who:** Venafi team · **Needs:** nothing · **Gives:** `tpp-chain.pem`, `enterprise-root.pem`,
`enterprise-issuing.pem` to the Vault and K8s teams

| File | What it is | Used by |
|---|---|---|
| `tpp-chain.pem` | Root + intermediates of the **TPP web server** certificate | Vault nodes, to trust TPP |
| `enterprise-root.pem`, `enterprise-issuing.pem` | Root and issuing CA of the **CA template** (A10) | The proof, to check issued certs |

## Step 1 — Export the TPP web chain

Run the ⌨ `bash` blocks in **Git Bash** or **MobaXterm** (both include `openssl`). A domain-joined
Windows Server is the easiest place: the root CA is already in its trust store.

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

3. Get the missing certificate. Written for a **domain-joined Windows Server** with Git Bash (or
   MobaXterm) and Chrome. Your AD root CA is already in the server's **Trusted Root** store, so you
   don't need the AIA link. Use **one** option:

   **Option A — certutil (built into Windows), then Git Bash.** Takes about 1 minute.
   1. ⌨ In **Command Prompt** or **PowerShell** (not Git Bash, which can mangle certutil's arguments),
      in the `tpp-chain` folder. Use the **CN** from the issuer line in part 2:
      ```cmd
      certutil -store Root "CORP-Root-CA"
      ```
      **Expected:** one certificate block whose *Subject* matches. Note its **Cert Hash(sha1)**. If
      several match (an old and a renewed root), pick the one whose *NotAfter* is in the future.
   2. ⌨ Export it by that hash (remove the spaces from the hash):
      ```cmd
      certutil -store Root <sha1-hash> missing.cer
      ```
   3. ⌨ Back in **Git Bash**, in the same folder, convert it to PEM and check it:
      ```bash
      openssl x509 -inform DER -in missing.cer -out missing-1.pem
      openssl x509 -in missing-1.pem -noout -subject -issuer -fingerprint -sha256
      ```

   **Option B — Chrome**, all clicks:
   1. 🖱 Open `https://tpp.corp.example.com` in Chrome → click the icon left of the address →
      **Connection is secure** → **Certificate is valid**.
   2. 🖱 **Details** tab → **Certificate Hierarchy** → click the **top** entry (the root).
   3. 🖱 **Export…** → type **Base64-encoded ASCII, single certificate** → save as `missing-1.pem` in
      the `tpp-chain` folder.
   4. ⌨ Git Bash: `openssl x509 -in missing-1.pem -noout -subject -issuer -fingerprint -sha256`

   **Option C — certlm.msc**, if Chrome's viewer differs: Start → `certlm.msc` → *Trusted Root
   Certification Authorities* → *Certificates* → right-click the root → **All Tasks ► Export** →
   **Base-64 encoded X.509 (.CER)** → save as `missing-1.pem`.

   **Option D — ask your PKI team** for the root as PEM.

   **Expected:** subject = issuer (it's the root) **and** subject = the issuer from part 2. Send the
   SHA-256 fingerprint to your PKI team to confirm it's the right root, because Vault will trust it.

   If there's still a gap (the certificate you got isn't self-signed), repeat with its issuer and save
   as `missing-2.pem`. Use the **Intermediate Certification Authorities** store
   (`certutil -store CA "<CN>"`) instead of `Root`. If **more than one** certificate is missing, use
   part 3b instead.

3b. **Several certificates missing (more than one intermediate):** let Windows build the whole chain.
   Windows looks in the server's certificate stores **and** follows the AIA links, including
   `ldap://` ones, using the server's domain login. It writes `tpp-chain.pem` for you, so skip part 4's
   `cat` line.

   ⌨ In **PowerShell**, in the `tpp-chain` folder (part 1 must have run):
   ```powershell
   $X = 'System.Security.Cryptography.X509Certificates'
   $files = Get-ChildItem presented-*.pem | Sort-Object { [int]($_.BaseName -replace '\D') }
   $leaf  = New-Object "$X.X509Certificate2" $files[0].FullName
   $chain = New-Object "$X.X509Chain"
   $chain.ChainPolicy.RevocationMode = 'NoCheck'
   $files | Select-Object -Skip 1 | ForEach-Object {
     [void]$chain.ChainPolicy.ExtraStore.Add((New-Object "$X.X509Certificate2" $_.FullName)) }
   "Chain complete: $($chain.Build($leaf))"
   $chain.ChainStatus | ForEach-Object { $_.StatusInformation }
   $pems = foreach ($e in ($chain.ChainElements | Select-Object -Skip 1)) {
     $c = $e.Certificate
     Write-Host "$($c.Subject)   <- issued by $($c.Issuer)"
     $b64 = [Convert]::ToBase64String($c.RawData) -replace '(.{64})', "`$1`n"
     "-----BEGIN CERTIFICATE-----`n$($b64.TrimEnd())`n-----END CERTIFICATE-----"
   }
   [IO.File]::WriteAllText((Join-Path (Split-Path $PWD) 'tpp-chain.pem'), ($pems -join "`n") + "`n")
   ```
   **Expected:**
   - `Chain complete: True`, and no status lines.
   - One line per certificate above the server certificate. The **last** line's subject = its issuer
     (the root).
   - `tpp-chain.pem` written next to the `tpp-chain` folder.

   | You see | Meaning | Fix |
   |---|---|---|
   | `Chain complete: False` + *partial chain* | Windows couldn't find a certificate in its stores or through AIA | Ask the PKI team for the issuer of the **last** line printed. Save it as `missing-1.pem` in `tpp-chain`, run `certutil -addstore -user CA missing-1.pem` (or `Root` if it's the root), and re-run |
   | `Chain complete: False` + *not trusted* / *untrusted root* | Chain is complete, but this server doesn't trust the root | The file is still written. Confirm the root's fingerprint with the PKI team before using it |
   | Lines print but the last one isn't self-signed | Same as *partial chain* | As above |

   Manual alternative: in Chrome, the **Certificate Hierarchy** (Option B) shows the full chain
   Windows built. Select **each** entry except the bottom one, **Export** each as Base64, and put them
   all in `missing-*.pem`.

4. ⌨ Build the file from **everything except the server certificate**, then check it. After part 3b,
   skip the `cat` line and just run `cd ..` and the checks:
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
