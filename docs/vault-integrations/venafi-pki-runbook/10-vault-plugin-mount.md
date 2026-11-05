# 10 — Plugin and mount

**Who:** Vault team · **Needs:** chunk 08 done, A8, A9, A11, A13
**Gives:** plugin registered, `venafi-pki` mounted in `AUT` with roles and policies (E4, E5)

Use the Terraform path (`vault-enterprise-config`). The CLI path is the fallback.

## Step 1 — Register the plugin in the root catalog

**Terraform**
1. 🖱 Raise a PR to `vault-enterprise-config` with the `plugins:` entry in `configs/root-namespace.yaml`.
2. 🖱 After merge, run `jenkins/Jenkinsfile.root`.

**CLI fallback** (does Step 1 and Step 2):
```bash
SKIP_REGISTER=0 NS=AUT docs/vault-integrations/examples/venafi-pki-configure.sh
```

⌨ Check:
```bash
VAULT_NAMESPACE= vault plugin info -version=v0.16.0 secret venafi-pki-backend
```
**Expected:** `sha256 48eec755…c99ec`, `version v0.16.0`, `command venafi-pki-backend`. 🖱 Save it (**E4**).

## Step 2 — Mount, roles and policies in `AUT`

**Terraform**
1. 🖱 In `configs/applications/automation.yaml` → `secret_engines.venafi_pki`, set the zones and domains
   from A8/A9.
2. 🖱 Run `jenkins/Jenkinsfile.namespace` with `APPLICATION=automation`.

⌨ Check:
```bash
vault secrets list -namespace=AUT -detailed -format=json \
  | jq '."venafi-pki/" | {type, plugin_version, running_plugin_version}'
vault list -namespace=AUT venafi-pki/roles
vault policy list -namespace=AUT | grep venafi-pki-
```
**Expected:**
- type `venafi-pki-backend`, both versions `v0.16.0`
- roles `web-aut`, `host-csr-aut`, `k8s-cert-manager` (or your A8 names)
- `venafi-pki-*` policies listed

🖱 Save it (**E5**). Issuing a certificate **does not work yet**. That's expected until chunk 11.

## Done when

- [ ] E4: catalog pinned to the right hash and version
- [ ] E5: mount running v0.16.0, roles and policies present

## If it fails

| You see | Fix |
|---|---|
| `unknown plugin` on mount | Root pipeline not run, or the version text differs from `v0.16.0` |
| `checksums did not match` | One node has a different binary. Back to chunk 08 Step 2 |
