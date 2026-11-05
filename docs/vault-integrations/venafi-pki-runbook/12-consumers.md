# 12 — Consumers (CI, AAP, others)

**Who:** Vault team · **Needs:** chunk 11 · **Gives:** consumers can request certificates

## Step 1 — Attach the policy to the consumer's auth role

**Terraform**
1. 🖱 In `vault-enterprise-config`, add `venafi-pki-<role>` (e.g. `venafi-pki-web-aut`) to the
   `policies` of each auth role that should issue (CI JWT role, AAP AppRole, …).
2. 🖱 Run the application pipeline.

**CLI fallback:** add the policy to the role's `token_policies`.

**Expected:** a consumer logs in and `vault token lookup` shows `venafi-pki-web-aut` under `policies`.

## Step 2 — Request a test certificate as the consumer

⌨ With the **consumer's** token, not an admin token:
```bash
vault write -namespace=AUT -format=json venafi-pki/issue/web-aut \
  common_name=app1.aut.corp.example.com alt_names=app1.aut.corp.example.com ttl=720h \
  | jq -r .data.certificate | openssl x509 -noout -subject -issuer -ext subjectAltName
```
Always put the CN in `alt_names` too. The plugin doesn't copy it into the SANs.

**Expected:** a certificate whose issuer is your enterprise CA, with the SAN present.

## Done when

- [ ] Each consumer role has its policy
- [ ] A consumer token can issue a certificate
