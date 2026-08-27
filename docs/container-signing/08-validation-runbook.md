# 08 — Validation Runbook

> **Purpose:** prove the signing chain works, prove it fails closed, and produce the evidence pack. Run
> every test in a **sandbox** before production enforcement.
>
> **Prereqs:** `01`–`06` implemented in a non-production environment: a sandbox TPP project/environment, a
> sandbox Harbor project pair, a sandbox Kubernetes cluster, and a test CloudBees job.
>
> **Ownership:** **Platform engineering** runs; **AppSec** witnesses the negative tests (§6); **PKI** owns
> the Venafi-side results.

---

## How to use this runbook

Each test has a stable ID (`V-nn`). Record **actual output**, not "pass" — the evidence pack in `07 §8`
depends on it. A test that cannot be run is a **fail**, not a skip.

Fill in as you go:

| Field | Value |
|---|---|
| Date | |
| Environment | sandbox / pilot |
| TPP version | 24.1 (docs baseline 24.3 — see `00 §6`) |
| CodeSign client version | |
| cosign version + asset name | |
| policy-controller version | |
| Harbor version | |
| Run by / witnessed by | |

**Stop conditions.** Halt and fix before continuing if any of these fail: `V-03` (wrong cosign build),
`V-12` (scan gate), `V-31` (unsigned rejected), `V-35` (Rekor egress blocked).

---

## 1. Phase A — Agent and client (`V-01` … `V-08`)

| ID | Test | Command | Expected |
|---|---|---|---|
| V-01 | Client installed and healthy | `pkcs11config health` | Exit 0 |
| V-02 | Client version recorded | `pkcs11config version` | Version + build timestamp captured |
| V-03 | **cosign has PKCS#11 support** | `cosign pkcs11-tool --help` | Exit 0. **Stop condition** — failure means the wrong binary (`02 §3`) |
| V-04 | cosign asset name is correct | `ls -l $(command -v cosign)`; check install source | Filename/source contains `pivkey-pkcs11key` |
| V-05 | TPP endpoints reachable | `curl -sSI https://<tpp>/vedauth` and `/vedhsm` | TLS handshake succeeds, no cert error |
| V-06 | Chain validation is ON | `pkcs11config option` (inspect Chain Validation) | Not `No`/`Disabled`/`0` |
| V-07 | Grant acquisition | `pkcs11config getgrant --force ...` | Exit 0 |
| V-08 | Grant status check | `pkcs11config checkgrant; echo $?` | `0` |

> **`V-06` matters.** Disabled chain validation makes the signing channel man-in-the-middleable and the
> vendor states it *"must not be used in production environments"*. Check it explicitly — it is easy to
> leave enabled from a troubleshooting session.

---

## 2. Phase B — Venafi key access (`V-09` … `V-11`)

| ID | Test | Command | Expected |
|---|---|---|---|
| V-09 | Key objects visible | `pkcs11config list` | The `container-prod` label appears |
| V-10 | Token is remote | `cosign pkcs11-tool list-tokens --module-path $PKCS11_MODULE` | **`Remote Token`** |
| V-11 | Key URI discoverable | `cosign pkcs11-tool list-keys-uris --module-path $PKCS11_MODULE` | URI with `object=container-prod`; record it verbatim |

> **`V-10` is the key-custody proof.** `Remote Token` confirms signing is serviced by TPP and no key
> material is local. A different token name means you are using a local token — stop and investigate.
> Capture this output for the evidence pack; it substantiates the claim in `00 §2`.

---

## 3. Phase C — Pipeline (`V-12` … `V-20`)

| ID | Test | Method | Expected |
|---|---|---|---|
| V-12 | **Scan gate blocks signing** | Build an image with a known critical CVE | Build fails at scan; **no signature exists**. **Stop condition** |
| V-13 | Clean image proceeds | Build a clean image | Reaches the sign stage |
| V-14 | Digest captured from registry | Inspect `image.digest` | Matches the digest Harbor reports |
| V-15 | Signature references the digest | `cosign verify ...@sha256:<digest>` | Verification passes |
| V-16 | Vault secrets retrieved | Build log + Vault audit log | Reads attributed to the signing job's `sub` |
| V-17 | **Wrong job denied by Vault** | Run a job outside the `bound_claims` path | Vault denies; build fails |
| V-18 | Grant revoked on success | `pkcs11config checkgrant` after build; `echo $?` | `1` (no grant) |
| V-19 | Grant revoked on **failure** | Force a mid-pipeline failure | `1` — `post{}` cleanup ran |
| V-20 | **No secrets in console log** | Read the full console log; grep for fragments of each secret | No matches |

**`V-20` procedure** — do this manually, do not assume plugin masking:

```bash
# Fetch the console log and grep for known secret fragments
curl -sS -u "$JENKINS_USER:$JENKINS_TOKEN" \
  "https://<controller>/job/<path>/<build>/consoleText" > /tmp/console.txt

for frag in "$HARBOR_TOKEN_FRAGMENT" "$PRISMA_PASS_FRAGMENT" "$VAULT_TOKEN_FRAGMENT"; do
  grep -c -- "$frag" /tmp/console.txt
done
# every count must be 0
```

**`V-17` is the one people skip.** It proves `bound_claims` actually constrains access rather than merely
being present in the config. Without it you have no evidence that any job on the controller can't read the
signing secrets.

---

## 4. Phase D — Concurrency (`V-21` … `V-23`)

Only required if you intend to remove `disableConcurrentBuilds` (`04 §5`).

| ID | Test | Method | Expected |
|---|---|---|---|
| V-21 | Two concurrent builds both sign | Trigger 2 builds on one agent simultaneously | Both produce valid signatures |
| V-22 | Grants are isolated | Inspect `LIBHSMINSTANCE` per build in logs | Distinct instance per build |
| V-23 | One build's cleanup does not break the other | Fail build A mid-run while B is signing | B completes successfully |

> **Run these repeatedly (10+ iterations).** The failure mode is a race — a single passing run proves
> very little. If you cannot run them, keep `disableConcurrentBuilds` enabled.

---

## 5. Phase E — Harbor (`V-24` … `V-30`)

| ID | Test | Method | Expected |
|---|---|---|---|
| V-24 | Signature accessory present | Harbor UI / accessories API | `signature.cosign` accessory on the digest |
| V-25 | Signing works on the build project | Full pipeline run | Succeeds — confirms the harbor#22650 split (`05 §2`) |
| V-26 | Enforcement blocks unsigned pull | Push an unsigned image to `container-prod`, pull it | Pull denied |
| V-27 | Promotion carries the signature | Promote by digest, verify at destination | `cosign verify` passes at the destination |
| V-28 | Replication carries the signature | If replicating, verify at the replica | Passes |
| V-29 | **Signatures survive retention/GC** | Run retention + GC in the sandbox project, re-verify | Passes |
| V-30 | Robot least privilege | Attempt an out-of-scope action with the build robot | Denied |

> **`V-29` catches a silent, delayed failure.** A retention rule that drops `.sig` accessories leaves
> images that verify today and fail admission weeks later, with nothing in CI to flag it. Test it before
> you rely on it, and keep the weekly sample verification job (`07 §6`) as the ongoing detector.

---

## 6. Phase F — Admission (`V-31` … `V-38`)

**AppSec should witness this phase.** This is where "only signed images run" is either true or not.

| ID | Test | Method | Expected |
|---|---|---|---|
| V-31 | Signed image admitted | Deploy a correctly signed image | **Admitted**. **Stop condition** if it fails |
| V-32 | Unsigned image rejected | Deploy an unsigned image | **Rejected** |
| V-33 | Wrong-key signature rejected | Sign with a different key, deploy | **Rejected** |
| V-34 | Tag rewritten to digest | Deploy by tag | Admitted, pod spec shows `@sha256:` |
| V-35 | **Rekor egress blocked** | Block egress to `rekor.sigstore.dev`, redeploy a signed image | **Admitted**. **Stop condition** — see below |
| V-36 | Deleted signature rejected | Delete the accessory in Harbor, redeploy | **Rejected** |
| V-37 | New namespace enforced | Create a fresh namespace, deploy unsigned | **Rejected** (proves the opt-out inversion, `06 §3`) |
| V-38 | Controller restart is stateless | Restart policy-controller pods, rerun V-31 | Admitted |

### V-35 — the decisive test

```bash
# Apply a NetworkPolicy (or firewall rule) that genuinely blocks egress to the public Rekor,
# then redeploy a known-good signed image.
kubectl -n <test-ns> rollout restart deploy/<test-app>
kubectl -n <test-ns> rollout status deploy/<test-app> --timeout=120s
```

- **Admitted** → Path 1 (no transparency log) is viable on this version. **Pin the version** and re-run
  this test on every upgrade (`07 §11`).
- **Rejected**, with an error mentioning tlog / Rekor / transparency log → Path 1 is **not** viable. Take
  Path 2 (private Rekor) or move to Kyverno, per `06 §1`.

Record the exact error text either way. This single result determines the enforcement architecture, and
it is the item blocking `mode: enforce` in `07 §9`.

> Block egress **genuinely** — a NetworkPolicy that is not enforced by your CNI, or a rule that the
> controller's node bypasses, produces a false pass. Confirm the block itself first (e.g. `kubectl exec`
> into a pod in the same namespace and `curl` the Rekor URL; it must fail).

---

## 7. Phase G — Operational resilience (`V-39` … `V-44`)

| ID | Test | Method | Expected |
|---|---|---|---|
| V-39 | Grant expiry is actionable | Revoke the grant mid-pipeline | Build fails with a clear error, not a silent skip |
| V-40 | TPP unavailable | Block egress to `/vedhsm` | Sign stage fails fast; error names the cause |
| V-41 | Break-glass works | Run with `SKIP_SIGN=true` | Approval enforced; unsigned image cannot reach an enforced namespace |
| V-42 | Re-sign an existing digest | `cosign sign` an already-pushed digest | Succeeds without a rebuild (`07 §4`) |
| V-43 | Key rotation overlap | Add a second authority, sign with the new key | **Both** old- and new-signed images admit |
| V-44 | Audit correlation | Compare the Venafi audit log to build records | Every signing event maps to a build |

> **`V-39` and `V-40` are about failure quality, not failure.** They will fail — the point is whether an
> on-call engineer at 3am can tell *why* in under a minute. If the error is opaque, improve the error
> handling in the pipeline and re-run.
>
> **`V-44` is the control that makes `07 §5` (incident response) possible.** If you cannot map signing
> events to builds during a calm sandbox run, you certainly cannot during an incident.

---

## 8. Evidence capture

For each test record: ID, timestamp, command, **actual output** (trimmed but unedited), pass/fail, and the
operator. Suggested layout:

```
evidence/
  V-10-remote-token.txt          # key custody proof
  V-12-scan-gate.txt             # vulnerable image blocked
  V-17-vault-denied.txt          # bound_claims enforced
  V-20-console-scan.txt          # no secrets leaked
  V-31..V-38-admission/          # admission matrix, incl. V-35 verbatim error
  V-44-audit-correlation.csv     # Venafi events ↔ builds
  run-metadata.yaml              # versions from the header table
```

Retain with the control narrative. `07 §8` maps these artefacts to the control questions they answer.

---

## 9. Sign-off

Production enforcement requires all of the following. Partial sign-off is not sign-off.

- [ ] Phase A–C complete, no stop conditions triggered
- [ ] Phase D complete, **or** `disableConcurrentBuilds` remains enabled
- [ ] Phase E complete, including `V-29` retention/GC
- [ ] Phase F complete and **witnessed by AppSec**, with `V-35` resolved and the enforcement path decided
- [ ] Phase G complete, failure messages judged actionable
- [ ] Evidence pack assembled
- [ ] Open items in `07 §9` either closed or explicitly risk-accepted with an owner and a date

| Role | Name | Date | Signature |
|---|---|---|---|
| Platform engineering | | | |
| PKI / Venafi | | | |
| CI engineering | | | |
| Registry | | | |
| AppSec | | | |

Proceed to `09-rollout-plan.md`.
