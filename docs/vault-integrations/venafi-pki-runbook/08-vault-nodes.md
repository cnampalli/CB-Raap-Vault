# 08 — Vault nodes

**Who:** Vault team · **Needs:** `tpp-chain.pem` (chunk 07) · **Gives:** every node ready to run the plugin

The plugin binary is placed on the nodes by Ansible. This chunk proves it is right on **every** node,
because any node can become the leader.

⌨ All commands assume:
```bash
export VAULT_ADDR=https://vault-vip.corp.example.com:8200 VAULT_CACERT=/path/vault-listener-ca.pem
```

## Step 1 — Cluster health

```bash
vault status                    # Version 1.20.8+ent, Sealed false, HA Enabled true
vault operator raft list-peers  # all voters present
vault read sys/license/status   # licence valid
```
**Expected:** healthy, licensed, all peers listed.

## Step 2 — Binary is correct on every node

```bash
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml
# no Ansible? on each node:  sudo docs/vault-integrations/examples/venafi-pki-verify-node.sh
```
**Expected:** every node passes:
- `plugin_directory` set in the server config, a real directory, not mounted `noexec`
- binary SHA-256 **`48eec75510d01cc721f971b68b692838cd5b09d3661082ce9b73a6dd961c99ec`**
- group `vault`, not writable by group/other

🖱 Save the `EVIDENCE host=…` and `SUMMARY host=…` lines (evidence **E1**).

## Step 3 — Restart nodes if `plugin_directory` was just added

Only if Step 2 shows Ansible **added** `plugin_directory` and the nodes haven't restarted since.

1. 🖱 Restart **one standby** node. ⌨ `vault operator raft list-peers` → wait until it is back as a voter.
2. 🖱 Repeat for the other standby.
3. ⌨ On the leader: `vault operator step-down`. Wait for a new leader. Restart the old leader.

**Expected:** all nodes back as voters, one leader.

## Step 4 — TPP trust bundle on every node

```bash
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml \
  --tags trust_bundle -e trust_bundle_src=./tpp-chain.pem
ansible-playbook -i inventory docs/vault-integrations/examples/ansible/venafi-pki-verify.yml \
  -e tpp_host=tpp.corp.example.com
```
**Expected:** `/etc/vault/tls/tpp-chain.pem` on every node, and `Verify return code: 0 (ok)` to TPP from
every node (evidence **E2**). This needs firewall flow #11 (chunk 09).

## Done when

- [ ] E1: all nodes pass with the right hash
- [ ] E2: TLS to TPP verifies from every node

## If it fails

| You see | Fix |
|---|---|
| Hash differs on one node | Re-run the Ansible install for that node. Never register a different hash |
| `noexec` | Move `plugin_directory` to a filesystem without `noexec` |
| `Verify return code` ≠ 0 | Wrong or incomplete `tpp-chain.pem`. Back to chunk 07 |
| Connection timeout to TPP | Flow #11 not open from that node (chunk 09) |
