# Container Image Signing — Venafi CodeSign Protect + cosign + CloudBees CI + Harbor

SOP and learning set for signing container images with **Venafi CodeSign Protect 24.1** keys from
**CloudBees CI**, using **cosign** and **podman**, scanned by **Prisma Cloud (twistcli)**, pushed to
**Harbor**, with credentials from **HashiCorp Vault Enterprise** and runtime enforcement by **Sigstore
Policy Controller**.

**Key custody: no HSM.** Private keys are held in the CodeSign Protect **Secret Store** on TPP and never
reach a build agent. See `00 §2` for why this is not SoftHSM.

---

## Delivery track — build it

| Doc | What it covers | Primary owner |
|---|---|---|
| [00 — Architecture overview](00-architecture-overview.md) | Design, key custody, trust boundaries, end-to-end flow, RACI | All |
| [01 — Venafi CodeSign Protect setup](01-venafi-codesign-setup.md) | Project, environment, key, CI identity, permissions, IP restriction | PKI / Venafi |
| [02 — Signing agent build](02-signing-agent-build.md) | Client install, cosign binary, grant lifecycle, concurrency isolation | Platform engineering |
| [03 — Vault secrets](03-vault-secrets.md) | Namespace, JWT role, policies, secret paths | Vault team + CI |
| [04 — CloudBees pipeline](04-cloudbees-pipeline.md) | The Jenkinsfile, end to end | CI engineering |
| [05 — Harbor configuration](05-harbor-config.md) | Projects, robots, signature accessories, enforcement | Registry team |
| [06 — Policy Controller](06-policy-controller.md) | Kubernetes admission enforcement | Kubernetes platform |
| [07 — Operations appendix](07-operations-appendix.md) | Rotation, revocation, troubleshooting, audit evidence | All |
| [08 — Validation runbook](08-validation-runbook.md) | Test plan `V-01`…`V-44`, evidence capture, sign-off | Platform + AppSec |
| [09 — Rollout plan](09-rollout-plan.md) | Phased rollout, go/no-go gates, rollback, timeline | Platform lead |

## Learning track — understand it

| Doc | What it covers |
|---|---|
| [10 — Venafi concepts primer](10-venafi-concepts-primer.md) | The mental model: projects, environments, templates, flows, grants, roles, what actually happens during a signing operation |
| [11 — Glossary](11-venafi-glossary.md) | Venafi, Sigstore, Harbor and pipeline terminology, with the commonly-confused terms flagged |
| [12 — Hands-on lab](12-hands-on-lab.md) | Guided sandbox lab: zero to signed image in 14 exercises, including deliberate failures |

---

## Where to start

**New to Venafi?** `10` → `11` → `12` → then the delivery track. The lab is worth the two hours: it turns
the runbooks from instructions into things you understand.

**Delivering it?** `00` → `01`–`07` in order → `08` to validate → `09` to roll out.

**Reviewing or auditing it?** `00` (design and trust boundaries) → `07 §8` (evidence pack) → `08` (test
results). `04 §10` explains the `--insecure-ignore-tlog` flag before you ask.

**On call?** `07 §7` (troubleshooting matrix) and `09 §10` (rollback summary).

**By role:** PKI/Venafi → `10`, `01`, `07 §2`/`§5`. Platform → `02`, `06`, `08`, `09`. CI → `03`, `04`.
Registry → `05`. AppSec → `00 §5`, `06`, `08 §6`, `07 §8`.

---

## Before you start — three things that will bite you

1. **Use the right cosign binary.** The stock `cosign-linux-amd64` has **no PKCS#11 support**. You need the
   release asset with `pivkey-pkcs11key` in its filename. → `02 §3`
2. **Resolve the transparency-log question before enforcing admission.** Our signatures have no Rekor entry;
   Policy Controller may attempt a public Rekor lookup and fail closed. This is the highest-risk item in the
   set and is the Gate 0 decision. → `06 §1`, test `V-35` in `08 §6`
3. **Do not enable Harbor's cosign deployment policy on the project CI pushes to.** It blocks the manifest
   reads cosign needs in order to sign ([harbor#22650](https://github.com/goharbor/harbor/issues/22650)).
   Use separate build and production projects. → `05 §2`

## Validation status

Written from vendor documentation; not executed against our environment. `08` must pass in a sandbox before
production enforcement — especially **`V-35` (Rekor egress blocked)**, which decides the enforcement
architecture. Open items are tracked in `07 §9`.

## Related

- [`../vault-integrations/`](../vault-integrations/) — Vault foundation, CloudBees OIDC, and the JWT patterns
  this SOP builds on
