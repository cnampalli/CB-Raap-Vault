# 09 — Firewall

**Who:** Vault team raises, network team opens · **Needs:** A1, A11, A12, A14 · **Gives:** flows open (evidence E3)

## Step 1 — Raise the requests

🖱 Raise one firewall request with these flows (A18):

| # | From | To | Port | Why |
|---|---|---|---|---|
| 11 | **each** Vault node | TPP (`/vedsdk/*`, `/vedauth/*`) | 443 | Vault requests certificates and refreshes tokens |
| 12 | **each** Vault node | each K8s API server | 6443 | Vault checks cert-manager's identity (only for chunk 13) |
| 13 | K8s nodes | Vault VIP | 8200 | cert-manager calls Vault (only for chunk 13) |
| 14 | Venafi admin host | Vault VIP | 8200 | Venafi team connects Vault to TPP (chunk 11) |

#11 and #12 must be open from **every** node, not just the leader. Any node can become the leader.

**Expected:** the request is approved and implemented.

## Step 2 — Prove each flow

⌨
```bash
docs/shared/conn_check.sh --hop flow11-vault-01-to-tpp   # repeat for -02, -03
docs/shared/conn_check.sh --hop flow12-vault-01-to-k8s   # repeat for -02, -03
docs/shared/conn_check.sh --app vault-from-k8s           # from a K8s node or debug pod
docs/shared/conn_check.sh --app vault                    # from the Venafi admin host
```
**Expected:** all green. 🖱 Save the output (evidence **E3**).

## Done when

- [ ] E3: every flow green, #11/#12 from every node
