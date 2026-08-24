# 07 — Operations Appendix

> **Scope:** day-2 operations for the container signing chain — rotation, revocation, incident response,
> troubleshooting, audit evidence, and tracked follow-ups.

---

## 1. Routine operations calendar

| Cadence | Task | Owner |
|---|---|---|
| Per build | Grant acquired and revoked; signature verified | Automated (`04`) |
| Weekly | Sample-verify production images (`cosign verify`) | Platform (automated job) |
| Monthly | Review Venafi signing audit log for volume anomalies and unexpected source hosts | PKI + AppSec |
| Quarterly | Review `static: pass` exceptions in ClusterImagePolicies (`06 §5`) | Platform + AppSec |
| Quarterly | Review Vault `bound_claims` against current folder structure (`03 §4`) | CI + Vault |
| 90 days | Rotate Harbor robot tokens; rotate Venafi password (Option A only) | Registry / PKI |
| Annually | Signing key rotation (§2) | PKI |
| On release | Test client/cosign/policy-controller upgrades against the `06 §8` matrix | Platform |

---

## 2. Signing key rotation

Rotation must not create a window where running workloads fail admission. Both keys are trusted during
overlap.

1. **Create** a new environment (or new key in the existing environment) in CodeSign Protect — `01 §5.2`.
2. **Export** the new public key — `01 §8`.
3. **Add** the new key as a *second authority* in the ClusterImagePolicy — `06 §7`. Authorities are OR'ed,
   so both old and new signatures now verify. **Deploy this before changing the pipeline.**
4. **Cut over** the pipeline: change `VENAFI_OBJECT` to the new label (`04 §3`).
5. **Re-sign or rebuild** every image still running that was signed with the old key. Inventory them:
   ```bash
   kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
     | sort -u | grep 'harbor.corp.example.com/container-prod'
   ```
   Re-signing an existing digest is valid — you do not need to rebuild:
   ```bash
   cosign sign --key "${NEW_KEY_URI}" --tlog-upload=false --yes \
     harbor.corp.example.com/container-prod/<repo>@sha256:<digest>
   ```
6. **Verify** nothing depends on the old key, then **remove** the old authority from the CIP.
7. **Revoke** key use on the old environment in TPP.

> Do not shortcut step 5. Removing the old authority while old-signed images are still running turns the
> next pod restart into an outage — and it will happen at 3am during an unrelated node drain.

---

## 3. Harbor robot token rotation

1. Create a **new** robot in Harbor with identical permissions (`05 §3`).
2. Update Vault: `vault kv put secret/ci/container-signing/harbor-robot username=... token=...`
3. Run a build to confirm push, sign, and verify all succeed.
4. Delete the old robot.

Create-then-swap, never delete-then-create — the latter guarantees a broken window.

---

## 4. Break-glass: signing unavailable

If TPP is down or grants cannot be issued:

1. Confirm the outage: `pkcs11config health`, then `checkgrant` on a signing agent.
2. Decide with the change authority whether to proceed unsigned.
3. If yes, run with `SKIP_SIGN=true` (`04 §11`) **plus** the approval gate. The image lands in
   `container-build` only.
4. The unsigned image **cannot** reach production — Policy Controller rejects it. For a genuine
   production emergency, deploy to a namespace labelled `policy.sigstore.dev/exclude=true`, restricted to
   the on-call platform role, and record it.
5. **When signing is restored, sign the existing digest** — no rebuild needed:
   ```bash
   cosign sign --key "${KEY_URI}" --tlog-upload=false --yes \
     harbor.corp.example.com/container-build/<repo>@sha256:<digest>
   ```
   Then promote and remove the namespace exclusion.
6. Close the change record with the digest, the reason, and the remediation timestamp.

---

## 5. Incident: suspected signing compromise

**Objective: stop signing immediately, then determine what was signed.**

Immediate (minutes):

1. **Revoke key use** for `svc-container-signer` on `container-prod` in TPP (`01 §7`). This is faster and
   more complete than credential rotation — it stops in-flight grants.
2. Disable the signing job in CloudBees CI.
3. Revoke the Harbor build robot.
4. Revoke the Vault role: `vault delete auth/jwt-ci-ctrlA/role/container-signing`.

Assess (hours):

5. Pull the CodeSign Protect audit log for the exposure window. **Every signature request is recorded
   against the requesting identity** — this is the authoritative record of what could have been signed.
6. Reconcile each signing event against a CloudBees build (`04 §3` emits `SIGNED-ARTIFACT ... build=...`).
   **Any signing event without a matching build is the incident.**
7. Inventory running images signed in the window (`§2` step 5 query).

Recover:

8. Rotate the signing key (§2) — treat the old key as compromised and remove its authority **without** the
   usual overlap grace once unauthorised signatures are confirmed.
9. Re-sign known-good digests with the new key.
10. Restore the Vault role, robot, and job with tightened `bound_claims`.

> **The property that makes this recoverable:** the key never left TPP, so an attacker could only *request*
> signatures during a live grant — they could not take the key. Rotation genuinely ends the exposure. This
> is the concrete payoff of the whole design.

---

## 6. Monitoring and alerting

| Signal | Source | Alert on |
|---|---|---|
| Signing volume on `container-prod` | Venafi audit → SIEM | Deviation from the build-rate baseline |
| Signing from an unexpected host | Venafi audit → SIEM | Any host outside the `container-signer` pool |
| Signing event without a matching build | SIEM correlation | Any occurrence — **highest severity** |
| Grant outliving its build | Venafi audit | Grant age > max build duration (detects `post{}` cleanup failure) |
| `SKIP_SIGN=true` used | CloudBees | Any occurrence |
| Verify-gate failure | CloudBees | Any occurrence |
| Admission rejection: no matching signature | Policy Controller | Rate spike (indicates key/pipeline/GC problem) |
| Admission webhook unavailable | Kubernetes | Any occurrence — enforcement is down |
| Weekly sample verification | Scheduled job | Any failure (catches signature GC — `05 §6`) |

---

## 7. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| **Cannot find** Certificate Authority Templates or Environment Templates anywhere in the web UI | They are not in a browser. CodeSign Protect admin is the **Venafi CodeSign Protect Administration MMC snap-in** — a Windows desktop app | Install and launch it — `01 §3.1` |
| Aperture: **Template dropdown greyed out** when adding an environment | No Environment Template exists — it is created in the MMC snap-in, not Aperture | `01 §4.3` |
| Environment Template created but **never appears** in Aperture | Five causes — **wrong console**, visibility, type mismatch between consoles (silent, no error), partial save, session cache | Ordered diagnostic in `01 §4.5`. **Check the console first**, then Visibility |
| `Common Name … does not end with a valid domain name for this folder. Valid domains have been configured in the Domain Whitelist` | **Usually: you are in TLS Protect, not CodeSign Protect** — domain whitelisting is a TLS control behaving correctly. Less often: TLS policy inherited onto the Code Signing branch | Confirm the console first — `01 §3.1`. If genuinely in CodeSign Protect, clear **Allowed Domains** or use a domain-shaped CN — `01 §4.4` |
| Users cannot create code signing projects at all | No environment template is visible to them | Check Visibility on every environment template — `01 §4.5` |
| Environment Template's CA tab lists no CA templates | CA template missing, or on a TLS Protect branch rather than `\VED\Policy\Code Signing\Certificate Authority Templates\` | `01 §4.1` |
| Microsoft CA connector: **Retrieve** returns no templates | Credential lacks Read/Enroll on ADCS templates, or Service Name is wrong | Service Name must match the **CN of the CA's certificate**, not the hostname — `01 §4.2b` |
| Certificate issues but cannot sign code | ADCS template lacks the Code Signing EKU | Fix the **ADCS-side** template; no Venafi setting can add it — `01 §4.2b` |
| `cosign` errors on a `pkcs11:` URI; no `pkcs11-tool` subcommand | Wrong cosign build | Install the `pivkey-pkcs11key` asset — `02 §3` |
| `cosign sign` → 401 from Harbor, but `podman login` succeeded | podman/cosign auth-file mismatch | Align `DOCKER_CONFIG` + `REGISTRY_AUTH_FILE` — `04 §6` |
| `cosign sign` → 403 / denied on push | Robot lacks push, or enforcement enabled on the build project | `05 §3`, `05 §2` (harbor#22650) |
| Signing fails only under parallel builds | Grant collision | Set `LIBHSMINSTANCE` and per-build `HOME` — `02 §6` |
| `checkgrant` returns 1 | No grant / expired | `getgrant --force`; check `/vedauth` reachability |
| `invalid_grant` — *"username/password combination not valid"* | **Authentication** failed, not authorisation. Usually username *format*, or a stored refresh token masking the new credential | Try UPN, then `DOMAIN\\user`, then bare `sAMAccountName`; always pass `--force` when testing credentials — `02 §5.1` |
| `no rule/permission for identity AD:<user> exists` — HTTP 400 | **Authentication succeeded, authorisation failed.** TPP knows the identity and has no key-use rule for it | Most often the identity holds a **second role** (commonly Owner-group membership) and the exclusivity rule excludes it — `01 §7.5`. Then nested-group membership — `01 §2.4`. Then simply not a Key User — `01 §6.1`. Full table in `02 §5.1` |
| A **human** gets `no rule/permission…` on `container-signing-prod` | **Expected — that is the control working.** Prod signing is CI-only | Do **not** add a human as Key User on prod. Test interactively on `container-signing-dev` — `01 §7.1` |
| `failed to load pkcs11 module` | Wrong module path. Venafi's cosign page documents the **macOS** path; on Linux the module is at `/opt/venafi/codesign/lib/venafipkcs11.so` | Confirm with `test -f` before anything else — `02 §8.1`. If the path exists, run `ldd` on it and look for `not found` |
| Grant acquisition fails with TLS errors | CA trust not configured | `pkcs11config trust --certfile:` — `02 §4`. **Do not** disable Chain Validation |
| `pkcs11config: unknown command getgrant` | TPP/client upgraded to 25.3+ | Commands renamed to `login`/`checklogin`/`logout` — §9 |
| **Cannot select an individual user** in the Key User field — **no** individual resolves, not even your own account | Global setting *"Role members must be in groups"* is enabled. **Expected behaviour, not a fault** | Assign a single-purpose group instead of unchecking it — `01 §6.2`, `01 §2.4`, `01 §3.3` |
| Picker shows **some** AD identities but **not** the service account, though it exists in AD | Its OU falls outside every configured **search root** on the AD connector — TPP cannot see it, and reports nothing | Platform/AD team extends search roots on the **existing** connector — `01 §2.2`. **Do not add a second AD connector**; overlapping connections can stop the user resolving entirely |
| Key User picker shows **local users only**, zero AD identities | **You are signed in as a local identity.** *"Local users can't add Active Directory users or groups"* — no setting reverses this, and nothing about the AD connector is wrong | Sign in as an **AD** account and redo the assignment — `01 §2.1`. If your AD account cannot see the project, it needs **CodeSign Protect Administrator**, granted from VCC → System Roles on the TPP server — `01 §2.6` |
| ⚠ You were told to fix isolation via Policy Tree → Local Identity → Provider → Options → Permissions | **That setting runs the other way.** It *"permits external identities to see local identities"* — it lets AD users see local accounts, never the reverse | Ignore it for this symptom — `01 §2.1` |
| Signed in as AD, but the **project is not visible at all** | The AD account holds no role on it. *"The Owner, Code Signing Administrator, and Master Admin can make changes to the project"* — it is none of those | Grant **CodeSign Protect Administrator** to an AD group: VCC → System Roles, **on the TPP server** — `01 §2.6` |
| Account **is** in the group, group **is** Key User, signing still denied | Second project role inherited via a group (most common), or a **nested group not resolved** by the AD connector | Check the inherited role first — `01 §7.5`. If clean, flatten to a single-member group — `01 §2.4` |
| "The AD account was created an hour ago and still is not visible — has it synced?" | Wrong model. AD connections are *"read-only… in real time"* — there is **no import job and no propagation delay** | Stop waiting; it is a search root or a wrong-session problem — `01 §2.2`, `01 §2.1` |
| `list` shows no objects | Identity is not a **Key User** on the project — creating the identity grants nothing | Add it: Aperture → project → Properties → Users & Approvers → Key User — `01 §6.1` step 2 |
| Signing succeeds but no audit records exist | **Signing Archive** disabled or retention too short | `01 §3.3`. Fix before relying on `§5` incident response or `08 V-44` |
| Signing fails with a permissions error, but config looks correct | The account holds a **second project role**, possibly inherited from a group. Key Users may not hold other roles, and roles are checked **at key use**, not at setup | `01 §7.5` — check group-inherited roles first |
| A developer can sign with the production key | Dev and prod environments are in the **same project** — Key Users are project-scoped | Split into two projects — `01 §7` |
| Token is not `Remote Token` | Talking to a local token, not TPP | Stop; investigate — `02 §8` |
| Admission rejects a correctly signed image | Rekor lookup attempted | **`06 §1`** — run test 9 in `06 §8` |
| Admission rejects after a Harbor GC | Signature accessory deleted | `05 §6`; re-sign the digest |
| Policy appears to do nothing | Glob missing the registry host (defaults to `index.docker.io`) | `06 §4` |
| Adding an authority weakened the policy | Authorities are OR'ed | Use separate CIPs — `06 §4` |
| New namespace not enforced | Opt-in label default | Invert to opt-out — `06 §3` |

Enable verbose PKCS#11 logging for hard cases — Venafi's documented approach is to substitute the library
path with the tracing variant; see the troubleshooting section of the [cosign integration
page](https://docs.venafi.com/Docs/24.3/TopNav/Content/CodeSigning/t-codesigning-integration-sigstore.php)
and `pkcs11config trace`.

---

## 8. Audit evidence pack

Keep these current; they answer most control questions without a scramble:

| Evidence | Source |
|---|---|
| Key custody: keys in the Secret Store, no HSM, never on agents | `00 §2`, TPP environment config |
| Key generation approval record | Aperture project/environment approval — `01 §5.2` |
| Least-privilege key use | TPP permission export — `01 §7` |
| Only CI can sign production | Environment user list + `container-signer` label binding |
| Every signature attributable | CodeSign Protect audit log ↔ build correlation — `04 §3`. **Prerequisite:** Signing Archive retention configured and long enough — `01 §3.3`. If archiving is disabled, this evidence does not exist |
| Vulnerable images cannot be signed | Pipeline stage order + archived `scan-result.json` — `04 §3` |
| Only signed images run | ClusterImagePolicy + `06 §8` results |
| Secrets not exposed | Vault policy, audit log, console-log review — `03`, `04 §7` |
| Rotation and revocation are exercised | §2, §3, §5 run records |

**Explain `--insecure-ignore-tlog` proactively** (`04 §10`). It is the flag most likely to be flagged by a
reviewer pattern-matching on the word "insecure", and the explanation is short: no public transparency log
applies to private images signed with an internal enterprise key; signature verification is fully enforced.

---

## 9. Tracked follow-ups

| # | Item | Trigger | Notes |
|---|---|---|---|
| 1 | **Resolve the tlog question** | Before production | `06 §1`. Path 1 (no tlog), Path 2 (private Rekor), or Kyverno. **Blocks enforce mode.** |
| 2 | **Adopt JWT Mapping (`01 §6.3`)** if Option A shipped first | Next sprint | Removes the last long-lived Venafi credential |
| 3 | **Client command rename on upgrade** | TPP 25.3+ | `getgrant`→`login`, `checkgrant`→`checklogin`, `revokegrant`→`logout`, `setgrant`→`settoken`. Keep these in one shell function in the shared library so the change is a single edit. |
| 4 | Confirm `pin-source` support | Validation | `02 §7`. May be moot if the placeholder PIN is confirmed sufficient. |
| 5 | Enable build concurrency | After validation | Requires the `LIBHSMINSTANCE` test in `04 §5` |
| 6 | Evaluate `sigstore-kms-venafi` | Annually | §10 |
| 7 | Add SBOM attestation (`cosign attest`) | Roadmap | Same key and grant model; extends attestation policy in the CIP |

---

## 10. Future simplification: the `sigstore-kms-venafi` plugin

Venafi publishes a Sigstore **KMS plugin** ([Venafi/sigstore-kms-venafi](https://github.com/Venafi/sigstore-kms-venafi))
that removes PKCS#11 entirely:

```bash
cosign sign --key "venafi://container-signing\container-prod" --tlog-upload=false <image>
```

Authentication is by `VSIGN_URL` plus `VSIGN_TOKEN` **or `VSIGN_JWT`** — and the JWT option would reuse the
same CloudBees OIDC token pattern as Vault, removing the grant lifecycle (`02 §5`), the
`LIBHSMINSTANCE` isolation problem (`02 §6`), and the PIN handling question (`02 §7`) in one step.

**Not adopted now**, because:

- Requires cosign **v2.4.3+** (we may be on an older pinned build).
- Must be **built from source** and self-supported — no vendor package.
- Supports **Certificate environments only** (we use one — `01 §1` — so this is satisfied).
- **Not referenced by the 24.1 or 24.3 product documentation**, so it is unsupported for our version.

Re-evaluate annually, or sooner if CyberArk brings it into the supported product. The `01 §1` decision to
use a Certificate Environment was made partly to keep this door open.

---

## 11. Version upgrade checklist

When upgrading TPP, the client, cosign, or policy-controller:

- [ ] Read the release notes for changes to `pkcs11config` command names (§9 item 3)
- [ ] Confirm the cosign asset is still the `pivkey-pkcs11key` variant
- [ ] Re-run `cosign pkcs11-tool list-keys-uris` — confirm the URI is unchanged
- [ ] Re-run the full `06 §8` admission matrix, **especially test 9** (Rekor egress blocked)
- [ ] Test in a sandbox cluster before production
- [ ] Update terminology if moving to 25.3+ (*Code Sign Manager - Self-Hosted*, *Code Sign Client*)
