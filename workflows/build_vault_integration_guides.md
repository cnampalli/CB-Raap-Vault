# Workflow: Build & Maintain the Vault Integration Guides

## Objective

Produce and keep current the **zero-trust Vault Enterprise integration
documentation** for CloudBees CI, CloudBees CD/RO, and Ansible Automation
Platform (AAP). Two audiences, two layers:

- **Beginner series** — `docs/getting-started/` — task-oriented, copy-paste,
  self-contained steps a newcomer can follow in an **airgapped** environment.
- **Reference layer** — `docs/vault-integrations/` (00–05) — the architect-level
  design/runbook suite. Keep it consistent with the beginner series.

The guides must be accurate for the **customer's confirmed versions** and apply
**best-practice security policies** (least privilege, short TTLs, no static
secrets, response-wrapped credential delivery, audit-to-SIEM).

## Inputs

Confirmed environment (re-confirm these before each doc revision — versions drift):

| Component | Value |
|---|---|
| CloudBees CI | Client Controller `2.528.3.35200-rolling` (CJOC + 2–10 controllers, VMs) |
| OIDC Provider plugin | `111.v29fd614b_3617` — **is the SECURITY-3574 fix** (affected ≤ `96.vee8ed882ec4d`); no security upgrade needed |
| CloudBees CD/RO | 2024.x (airgapped VMs) |
| Vault Enterprise | `1.20.8+ent`, namespace `AUT` |
| AAP | **2.4** (automation controller **4.5.25**) — 2.5 ships controller 4.6.x; native OIDC is 2.7 Tech Preview |
| AAP → Vault auth | **AppRole (hardened)** via the native HashiCorp Vault credential plugin |
| CI → Vault auth | OIDC per-build JWT (OIDC Provider plugin) |
| CD/RO → Vault | brokered via a CI OIDC job (no native issuer, airgapped) |

**Airgap constraint:** the customer environment cannot run our scripts or fetch
from the internet. Beginner-doc *content* is therefore pure manual CLI/UI steps.
Our `tools/` are operator/agent-side helpers only.

## Tools

- **`tools/inspect_jwt_claims.py`** — decode a captured OIDC ID token to see the
  exact `iss`/`aud`/`sub`/`job` claims, so the Vault JWT role's `bound_issuer`,
  `bound_audiences`, and `bound_claims` can be set correctly. Stdlib-only, no
  network, no signature verification.
- **`tools/check_oidc_discovery.py`** — from a permitted host, verify a CI
  controller's `/oidc/.well-known/openid-configuration` + JWKS are reachable
  (firewall **flow #1**, the classic silent failure). Stdlib-only.
- **Research (read-only):** use context-mode `ctx_fetch_and_index` for official
  docs (HashiCorp Vault, Red Hat AAP, Jenkins security advisories). Keep raw
  pages in the sandbox; cite versions in the guides.

Order of work: (1) confirm inputs → (2) run/refresh research → (3) write/refresh
beginner series → (4) reconcile the reference layer → (5) validate with the tools
and the per-guide verification sections.

## Outputs

- `docs/getting-started/README.md` + `00`–`05` (beginner series).
- Reconciling edits to `docs/vault-integrations/00`–`05`.
- The two `tools/` helpers above.
- No secrets in any file. Placeholders like `<vault-vip>`, `<ci-ctrl>`,
  `10.20.0.0/24` stay as clearly-marked placeholders.

## Edge cases / known quirks

- **AAP version mislabel.** Controller `4.5.25` is **AAP 2.4**, not 2.5 (2.5 =
  controller 4.6.x). Verified via Red Hat release notes. Fix any doc that says
  "4.5.25 = 2.5."
- **AAP Vault plugin field names.** The exact automation-controller credential
  field labels (Secret Lookup / Signed SSH) for AppRole must be confirmed against
  the AAP 2.4 controller docs / AWX `credential_plugins/hashivault.py`; where a
  label can't be confirmed from a primary source, mark it "verify in your
  environment (AAP 2.4 controller)" rather than guessing.
- **SECURITY-3574 gate.** `oidc-provider` ≤ `96.vee8ed882ec4d` is vulnerable
  (CVE-2025-47884, Critical). The fix is `111.v29fd614b_3617` — the customer's
  version. Upgrading to `212.v7657c4d7b_29f` is optional maintenance and needs
  Jenkins core `2.541.3`.
- **Firewall flow #1** (Vault → each controller `/oidc/**`) is the most common
  silent JWT-login failure. Always validate it first with
  `check_oidc_discovery.py`.
- **AppRole secret_id** is a bootstrap secret. It is only zero-trust-aligned when
  delivered response-wrapped (`-wrap-ttl`), single-use (`secret_id_num_uses=1`),
  short-lived (`secret_id_ttl`), CIDR-bound to AAP hosts, and stored only in
  AAP's encrypted credential store — never in git/playbooks/inventory.
- **TTL/rotation SLA.** The reference docs previously carried "pending SLA"
  placeholders. The beginner series ships concrete zero-trust defaults (Vault
  token 15–30 min, SSH cert ≤ 2 h, wrap 90 s); flag that they are overridable
  once a formal SLA is provided.
- **Never overwrite the reference docs' intent without confirming.** Per project
  policy, don't restructure `docs/vault-integrations/` beyond the agreed
  reconciling edits without asking.

## Verification

Run the per-guide verification sections end-to-end; at minimum:
`check_oidc_discovery.py <ctrl>` passes; a CI build mints a JWT that
`inspect_jwt_claims.py` shows with the expected `aud`/`iss`; `vault token lookup`
shows short TTL + the intended policies; an AAP job resolves a KV value and a
single-use `secret_id` is rejected on reuse.
