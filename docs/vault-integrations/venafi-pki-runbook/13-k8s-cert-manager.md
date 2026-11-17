# 13 — Kubernetes (cert-manager)

**Who:** Kubernetes team, with the Vault team for Step 4 · **Needs:** chunk 11, flows #12/#13, A14–A16
**Gives:** a ClusterIssuer that gets certificates from Venafi through Vault

Files: [`../examples/k8s/`](../examples/k8s/).

## Step 1 — Check cert-manager

⌨
```bash
kubectl -n cert-manager get deploy cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
**Expected:** version **≥ 1.15**. Note the controller ServiceAccount name (Helm default `cert-manager`).

## Step 2 — Identity and RBAC

⌨
```bash
kubectl apply -f docs/vault-integrations/examples/k8s/00-vault-venafi-issuer-rbac.yaml
kubectl auth can-i create serviceaccounts --subresource=token -n cert-manager \
  --as=system:serviceaccount:cert-manager:cert-manager
kubectl auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:cert-manager:vault-venafi-issuer
```
**Expected:** both print `yes`.

## Step 3 — Collect what Vault needs

⌨
```bash
kubectl get --raw /.well-known/openid-configuration | jq -r .issuer
kubectl config view --raw --minify \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > k8s-api-ca.pem
```
**Expected:** an issuer URL (the API audience) and a PEM file.

🖱 Send the API URL and `k8s-api-ca.pem` to the Vault team.

## Step 4 — Vault team: Kubernetes auth role

1. 🖱 In `configs/applications/automation.yaml` → `auth_methods.kubernetes.automation-k8s`, set the API URL
   and CA, and this role:
   ```yaml
   - role_name: "cert-manager-venafi"
     bound_service_account_names: ["vault-venafi-issuer"]
     bound_service_account_namespaces: ["cert-manager"]
     audience: "vault://vault-venafi"     # vault://<ClusterIssuer name> (A16)
     policies: ["venafi-pki-k8s-cert-manager"]
     ttl: 600
   ```
2. 🖱 Run the application pipeline.

⌨ Check: `vault read -namespace=AUT auth/kubernetes/automation-k8s/role/cert-manager-venafi`

**Expected:** audience and policy as above. No `token_reviewer_jwt` is stored.

## Step 5 — ClusterIssuer

1. 🖱 Edit `01-clusterissuer-vault-venafi.yaml`:
   - `caBundle`: ⌨ `base64 -w0 < vault-listener-ca.pem` (Vault's **listener** CA, not the Venafi CA)
   - the audience from Step 3, `namespace: AUT`, `mountPath: /v1/auth/kubernetes/automation-k8s`
2. ⌨ `kubectl apply -f docs/vault-integrations/examples/k8s/01-clusterissuer-vault-venafi.yaml`
3. ⌨ `kubectl get clusterissuer vault-venafi`

**Expected:** `READY True`, message `Vault verified`.

## Step 6 — Block bad names in the cluster (recommended)

1. 🖱 Install approver-policy, and set cert-manager `disableAutoApproval=true`.
2. 🖱 Set the domains in `03-approver-policy.yaml` from A9.
3. ⌨ `kubectl apply -f docs/vault-integrations/examples/k8s/03-approver-policy.yaml`
4. ⌨ Create a Certificate for `evil.example.com` against `vault-venafi`.

**Expected:** its CertificateRequest is **Denied** before it reaches Vault (evidence **E10**).

## Step 7 — Demo certificate

⌨
```bash
kubectl apply -f docs/vault-integrations/examples/k8s/02-certificate-demo.yaml   # CN/SANs from A9
kubectl -n venafi-demo get certificate demo-tls
kubectl -n venafi-demo get certificaterequest -o wide
```
**Expected:** Certificate `READY True`. CertificateRequest `APPROVED True`, `READY True`.

## Step 8 — Prove it from the cluster

⌨ `TPP_TOKEN` comes from the read-only proof token (chunk 15 Step 1).
```bash
TPP_URL=https://tpp.corp.example.com TPP_CA=./tpp-chain.pem TPP_TOKEN=<read-only token> \
TRUST_ROOT=./enterprise-root.pem EXPECT_FOLDER='Certificates\Vault\AUT\K8s' RENEW=1 \
  docs/vault-integrations/examples/k8s/verify-cert-manager.sh
```
**Expected:** PASS for chain, enterprise root, TPP inventory under `…\AUT\K8s`, Origin, and a **new
serial** after the forced renewal (evidence **E9**, **E11**).

## Done when

- [ ] ClusterIssuer Ready
- [ ] Demo certificate Ready; bad name Denied
- [ ] E9, E11 PASS

## If it fails

| You see | Fix |
|---|---|
| ClusterIssuer `invalid audience` | Vault role audience must be `vault://vault-venafi` (Step 4) |
| `TokenReview` / `service account lookup failed` | auth-delegator binding (Step 2), audience (Step 5), or flow #12 |
| `x509` on the ClusterIssuer | Wrong `caBundle`: it must be Vault's listener CA |
| CertificateRequest `permission denied` | Vault policy lacks cert-manager's parameters (chunk 10, cert-manager policy variant) |
| Requests stay *Pending approval* | No matching approver-policy, or missing RBAC `use` (Step 6) |
| Secret's `ca.crt` looks wrong | Role `chain_option=first` (guide 08 §8) |
