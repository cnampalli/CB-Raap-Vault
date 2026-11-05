# 14 — Kubernetes (Vault Agent Injector) — optional

**Who:** Kubernetes team + Vault team · **Needs:** chunk 11, flows #12/#13 · **Gives:** a certificate as a file in the pod

Use this only for workloads that **cannot** read a Kubernetes Secret. Otherwise use chunk 13.

## Step 1 — Install the injector

⌨ Install the injector only, pointed at the external Vault. The command is in the header of
`docs/vault-integrations/examples/k8s/04-vault-agent-injector-demo.yaml`.

**Expected:** the `vault-agent-injector` pod is Running.

## Step 2 — Vault team: role for the workload

1. 🖱 Add Kubernetes role `web-agent`, bound to ServiceAccount `web` in namespace `venafi-demo`, policy
   `venafi-pki-web-aut`.
2. ⌨ Bind that ServiceAccount to `system:auth-delegator`.

**Expected:** `vault read -namespace=AUT auth/kubernetes/automation-k8s/role/web-agent` shows the binding.

## Step 3 — Deploy and check

⌨
```bash
kubectl apply -f docs/vault-integrations/examples/k8s/04-vault-agent-injector-demo.yaml
kubectl -n venafi-demo exec deploy/web -- openssl x509 -in /vault/secrets/tls.pem -noout -issuer
```
**Expected:** the issuer is your enterprise CA.

## Step 4 — Prove it

1. ⌨ Copy `/vault/secrets/tls.pem` out of the pod.
2. ⌨ `python3 tools/venafi_pki_proof.py --cert-file tls.pem …` (same TPP flags as chunk 15).

**Expected:** PASS.

Here Vault generates the key, so the Vault policy's CN/SAN checks do apply (watch for commas in names).
