# 06 — Folders and policy

**Who:** Venafi team, signed in as the right admin (chunk 02) · **Needs:** `svc-vault-pki` (chunk 04)
**Gives:** policy folders (A7, A8), CA turnaround time

TPP folder policy is what limits **which names** Vault can get certificates for. Vault cannot enforce
this on its own (guide 08 §9), so the domain whitelist in Step 3 matters.

## Step 1 — Create the folders

1. 🖱 Aperture → **Policy Tree**.
2. 🖱 Right-click `\VED\Policy\Certificates` → **Add** ► **Policy Folder** → name `Vault`.
3. 🖱 Under `Vault`, add `AUT`.
4. 🖱 Under `AUT`, add `Web`, `Hosts`, `K8s` (A8).

**Expected:** `\VED\Policy\Certificates\Vault\AUT\{Web,Hosts,K8s}` visible in the tree.

## Step 2 — Give the service account rights on `AUT` only

1. 🖱 Select `AUT` → **Permissions** → **Add** → search `svc-vault-pki` → select.
2. 🖱 Tick: **View**, **Read**, **Write**, **Create**, and **Revoke** (only if A5 includes revoke).
3. 🖱 Leave **unticked**: Delete, Admin, Private Key Read, Private Key Write.
4. 🖱 **Save**. The three leaf folders inherit these rights.

**Expected:**
- 🖱 `AUT` → Permissions → Effective permissions → `svc-vault-pki`: the rights above.
- 🖱 `Vault` (the parent) → Effective permissions → `svc-vault-pki`: **nothing**.

## Step 3 — Set and lock the policy on each leaf folder

For each of `Web`, `Hosts`, `K8s`:

1. 🖱 Select the folder → **Policy** tab (certificate policy).
2. 🖱 Set each value below, then click its **lock** so requests cannot override it.
3. 🖱 **Save**.

| Setting | `Web` | `Hosts` | `K8s` |
|---|---|---|---|
| CA template | A10 | A10 | A10 |
| Management type | Enrollment | Enrollment | Enrollment |
| CSR generation | allow *User provided*. **Do not lock to Service Generated** | same | same |
| Key | RSA ≥ 2048 | RSA ≥ 2048 or EC P-256 | RSA ≥ 2048 |
| Subject O / OU / L / ST / C | your values, locked | locked | locked |
| **Domain whitelist** | `aut.corp.example.com` + subdomains | host domain | `k8s.aut.corp.example.com` |
| Whitelist applies to SANs | Yes | Yes | Yes |
| Wildcards | Off | Off | Off |
| Disable automatic renewal | **Yes** (consumers renew) | Yes | Yes (cert-manager renews) |
| Validity | flexible if consumers choose `ttl`, else fixed | same | same |

**Expected:** each leaf shows the values with lock icons.

## Step 4 — Negative test: a bad name is rejected

1. 🖱 In `Web` → **Add** ► **Certificate** → Common Name `evil.example.com` → **Save** / **Submit**.

**Expected:** TPP **rejects** it with a policy / domain whitelist error. Screenshot it (evidence E10).

## Step 5 — Positive test: time the CA

1. 🖱 In `Web` → **Add** ► **Certificate** → Common Name `test-<date>.aut.corp.example.com` → submit.
   Start a timer.
2. 🖱 Wait until its status is **Issued**. Stop the timer.
3. 🖱 Open the certificate → details. Note the **CRL distribution point** and **OCSP** URL.
4. 🖱 Revoke and delete this test certificate.

**Expected:** issued in **under 60 s**, with CRL/OCSP URLs present.

## Done when

- [ ] Folders exist; `svc-vault-pki` has rights on `AUT` only
- [ ] Policy locked on all three leaves
- [ ] `evil.example.com` rejected (screenshot)
- [ ] Turnaround time sent to the Vault team (they raise `server_timeout` if it is over 120 s)

## If it fails

| You see | Fix |
|---|---|
| Can't add `svc-vault-pki` to Permissions | Signed in as local admin for an AD account. Use your AD admin (chunk 02) |
| `evil.example.com` was issued | Whitelist not set or not locked on that folder. Fix Step 3, revoke the cert |
| Issuance takes minutes | Raise with the CA team. Vault waits 180 s at most |
