# 17 — Troubleshooting

Find your symptom, then go to the chunk shown.

| Seen by | Symptom | Most likely | Go to |
|---|---|---|---|
| Venafi | AD service account not in the TPP Users list | Normal. AD accounts are found by **search**, never listed | 02 |
| Venafi | Can't add an AD account to permissions or an integration | Signed in as a **local** admin (`tpp_admin`) | 02 |
| Venafi | AD account not found in the search | Its OU is not under a connector Search Root | 02 Step 2 |
| Venafi | Login test `invalid_grant` / 401 | Username format, password, locked account | 05 Step 3 |
| Venafi | `write-secret`: `unwrap failed` | Token expired or **already used** | 11 Step 1 (report if used) |
| Venafi | `write-secret`: `x509: … unknown authority` | Trust bundle missing on the active node | 08 Step 4 |
| Venafi | `write-secret`: `invalid_grant` | Wrong client id / scope / refresh off | 05 |
| Vault | `checksums did not match` after failover | One node has a different binary | 08 Step 2 |
| Vault | Mount fails `unknown plugin` | Root pipeline not run, or version text differs | 10 Step 1 |
| Vault | Issue fails `PolicyLocked` / `does not match policy` | Role key or subject vs the folder's locked policy | 06 Step 3, guide 08 §8 |
| Vault | Issue works, cert has no SANs | `alt_names` not sent | 12 Step 2 |
| Vault | Everything fails after months with 401 | Grant expired (`refresh_until`) | 11 (repeat) |
| K8s | ClusterIssuer `invalid audience` | Vault role audience ≠ `vault://<name>` | 13 Step 4 |
| K8s | ClusterIssuer `TokenReview` 401 | auth-delegator, API audience, or flow #12 | 13 Steps 2–5, 09 |
| K8s | CertificateRequest `permission denied` | Policy lacks cert-manager's parameters | 10 Step 2 |
| K8s | `ca.crt` in the Secret looks wrong | Role `chain_option=first` | guide 08 §8 |
| K8s | Requests stay *Pending approval* | No matching approver-policy or RBAC `use` | 13 Step 6 |
