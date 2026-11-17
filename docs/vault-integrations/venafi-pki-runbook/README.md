# Venafi ⇄ Vault PKI — instructions manual

Switch on Vault Enterprise **1.20.8+ent**'s Venafi PKI secrets engine (`venafi-pki-backend` **v0.16.0**),
connect Kubernetes through cert-manager, and prove Venafi governs the certificates.

**Why it works this way:** [`../08-venafi-pki-secrets-engine.md`](../08-venafi-pki-secrets-engine.md).

## How to use this manual

- Each chunk is **one file** and can be done on its own, by one team, in one sitting.
- Each chunk starts with **Who**, **Needs** (and which chunk produces it) and **Gives**.
- Every step ends with **Expected**. If you don't see it, stop and use that chunk's *If it fails*
  table, or [17 — Troubleshooting](17-troubleshooting.md).
- 🖱 = manual step in a UI. ⌨ = command.
- Venafi UI labels move slightly between TPP versions. If a label differs, look for the nearest match
  and note it in the change ticket.

## The chunks

| # | Chunk | Who | Needs | Gives |
|---|---|---|---|---|
| 01 | [Agree the values](01-agree-values.md) | All | — | Filled agreement sheet |
| 02 | [AD admin access to TPP](02-tpp-ad-admin-access.md) | Venafi + AD + TPP server admin | — | An AD login with TPP admin rights |
| 03 | [Check the TPP platform](03-tpp-platform-check.md) | Venafi | — | TPP URL, version |
| 04 | [Service account](04-tpp-service-account.md) | Venafi (+ AD) | 02 if AD | `svc-vault-pki` |
| 05 | [API integration](05-tpp-api-integration.md) | Venafi | 04 | Client ID, scope, validity |
| 05a | [CA template](05a-tpp-ca-template.md) | CA admin + Venafi | — | A10: the CA template TPP issues through |
| 06 | [Folders and policy](06-tpp-folders-policy.md) | Venafi | 04, 05a | Policy folders, CA turnaround |
| 07 | [Trust files](07-trust-files.md) | Venafi | — | `tpp-chain.pem`, `enterprise-root.pem` |
| 08 | [Vault nodes](08-vault-nodes.md) | Vault | 07 | Verified binary + trust bundle on every node |
| 09 | [Firewall](09-firewall.md) | Vault (raises) | — | Flows #11–#14 open |
| 10 | [Plugin and mount](10-vault-plugin-mount.md) | Vault | 08 | Mount, roles, policies |
| 11 | [Connect Vault to TPP](11-bootstrap-secret.md) | Vault + Venafi together | 05, 06, 07, 09, 10 | Live TPP tokens in Vault, `refresh_until` date |
| 12 | [Consumers](12-consumers.md) | Vault | 11 | CI / AAP can issue |
| 13 | [Kubernetes (cert-manager)](13-k8s-cert-manager.md) | K8s + Vault | 11 | ClusterIssuer Ready |
| 14 | [Kubernetes (Agent Injector)](14-k8s-agent-injector.md) — optional | K8s + Vault | 11 | Cert in a pod file |
| 15 | [Proof and sign-off](15-proof.md) | All | 11 (+13) | Evidence E1–E14 |
| 16 | [Monitoring and day 2](16-monitoring-day2.md) | Vault + Venafi | 15 | Alerts, renewal calendar |
| 17 | [Troubleshooting](17-troubleshooting.md) | All | — | — |

## Order

```
Venafi:  01 → 02 → 03 → 04 → 05 → 05a → 06 → 07 ─┐
Vault:   01 → 08 → 09 → 10 ──────────────────────┼─► 11 → 12 → 15 → 16
K8s:                                             └─► 13 (after 11) ──┘
```

Venafi and Vault work in parallel until chunk 11, which needs both teams at the same time.

## Who owns what

| Area | Venafi | Vault | K8s |
|---|---|---|---|
| TPP identities, API integration, folders, policy, CA | **Owns** | Consulted | — |
| Plugin on nodes, catalog, mount, roles, policies | — | **Owns** | — |
| Firewall tickets | Consulted | **Raises** | Consulted (#13) |
| TPP tokens into Vault (chunk 11) | Types the password | Issues the one-time token | — |
| cert-manager, ClusterIssuer | — | Vault role | **Owns** |
| Grant renewal every year | **Owns** | Issues the token | — |
