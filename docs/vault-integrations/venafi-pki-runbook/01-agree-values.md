# 01 — Agree the values

**Who:** All three teams, one meeting · **Needs:** nothing · **Gives:** the filled sheet, attached to the change ticket

Every other chunk uses these values. The examples are what the commands in this manual show. Replace
them with yours.

## Steps

1. 🖱 Copy the table below into the change ticket.
2. 🖱 Fill in **Agreed value** for every row. Leave nothing blank. Write "n/a" if a row does not apply.
3. 🖱 Each owner confirms their rows in the ticket.

**Expected:** every row has a value and an owner's confirmation.

| # | Item | Example | Owner | Agreed value |
|---|---|---|---|---|
| A1 | TPP base URL | `https://tpp.corp.example.com` | Venafi | |
| A2 | TPP version | 24.x | Venafi | |
| A3 | Service account (AD or local) | `CORP\svc-vault-pki` | Venafi | |
| A3a | TPP admin AD group | `GG-TPP-Vault-Admins` | Venafi + AD | |
| A4 | API Application ID | `hashicorp-vault-by-venafi` (**do not change**) | Venafi | |
| A5 | Scope | `certificate:manage,revoke` | Venafi + Security | |
| A6 | Token validity / grant validity | 1 day / 365 days | Venafi | |
| A7 | Parent folder | `\VED\Policy\Certificates\Vault\AUT` | Venafi | |
| A8 | Leaf folder → Vault role | `Web`→`web-aut`, `Hosts`→`host-csr-aut`, `K8s`→`k8s-cert-manager` | Venafi + Vault | |
| A9 | Allowed domains per folder | `aut.corp.example.com`, `k8s.aut.corp.example.com` | Venafi + app owners | |
| A10 | CA template + issuer type | Microsoft CA → `m` | Venafi | |
| A11 | Vault VIP, namespace | `https://vault-vip.corp.example.com:8200`, `AUT` | Vault | |
| A12 | Vault nodes | `vault-01/02/03.corp.example.com` | Vault | |
| A13 | Mount path | `venafi-pki` | Vault | |
| A14 | K8s cluster, API URL, Vault auth path | `automation-k8s`, `https://automation.corp.example.com:6443`, `auth/kubernetes/automation-k8s` | K8s + Vault | |
| A15 | cert-manager version / namespace | ≥ 1.15, `cert-manager` | K8s | |
| A16 | ClusterIssuer name | `vault-venafi` (audience becomes `vault://vault-venafi`) | K8s + Vault | |
| A17 | Secure channel for the one-time token | PAM / sealed ticket | Security | |
| A18 | Change ticket(s) | CHG… | All | |

## Done when

- [ ] Sheet complete and confirmed in the ticket
