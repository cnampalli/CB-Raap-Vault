# 05 — Harbor: Projects, Robots, Signatures & Enforcement

> **Prereqs:** Harbor **2.5+** (2.5 introduced cosign signature support). Project-admin rights.
>
> **Ownership:** **Registry team** owns projects, robots and policy. **CI engineering** consumes the
> robot account. **AppSec** signs off on the enforcement configuration.

---

## 1. How Harbor stores cosign signatures

cosign writes a signature as a **separate OCI artifact** tagged `sha256-<digest>.sig`, alongside the
image. Harbor 2.5+ understands this and presents it as a **signature accessory** on the artifact rather
than as a stray tag.

Three consequences that shape everything below:

1. **Signing is a push.** The robot account needs push permission, not just pull. A read-only robot will
   fail at `cosign sign` with a 401.
2. **Signatures are subject to retention and GC.** A retention policy that deletes the `.sig` artifact
   leaves a signed image that no longer verifies. See §6.
3. **Signatures replicate**, if your replication rule matches them. See §7.

---

## 2. Project topology — build and production are separate

**Do not enforce signature policy on the project you push builds into.** Use two projects with a
promotion step:

| Project | Enforcement | Purpose |
|---|---|---|
| `container-build` | **Off** | CI pushes here, scans, signs. Short retention. |
| `container-prod` | **On** | Promoted, signed images only. Consumed by Kubernetes. |

> **⚠ Why this split is required, not merely tidy.** Harbor's cosign deployment security policy has a
> known defect where enabling it **blocks manifest reads during signing operations**
> ([goharbor/harbor#22650](https://github.com/goharbor/harbor/issues/22650)) — cosign must read the
> manifest it is about to sign, the policy denies that read because the artifact is not yet signed, and
> you get an unbreakable chicken-and-egg. Enabling enforcement on the project CI pushes to will stop
> signing from working at all.
>
> Verify the current behaviour on your Harbor version during validation. Even once fixed, the split is
> good practice: it keeps unsigned build output out of the project production pulls from.

Promotion options, in order of preference:

1. **Harbor replication** from `container-build` → `container-prod`, filtered to signed artifacts, with
   signatures included (§7).
2. A promotion pipeline stage that re-tags and pushes by digest into `container-prod`, then re-verifies.

Either way, **promote by digest**, never by tag.

---

## 3. Robot accounts

Create one robot per project with the minimum permission set.

**Build robot** — `robot$container-build+ci`:

| Resource | Permission | Why |
|---|---|---|
| repository | pull, push | Image push and **signature push** |
| artifact | read | cosign reads the manifest before signing |
| tag | create | Tagging |
| scan | create, read | twistcli / Harbor scan integration |

**Production pull robot** — `robot$container-prod+k8s`:

| Resource | Permission |
|---|---|
| repository | pull |
| artifact | read |

Configuration:

- Expiry **90 days**; rotation procedure in `07 §3`. Never set "never expires".
- Token stored in Vault at `secret/ci/container-signing/harbor-robot` (`03 §2`).
- Scope each robot to a **single project**. A system-level robot here is a standing cross-project
  compromise.

> The build robot can push signatures — meaning it can push *a* signature. It cannot forge a valid one,
> because it has no access to the Venafi key. A stolen robot token lets an attacker push images and
> unverifiable signatures; Policy Controller (`06`) still rejects them. This is the layered control
> working as designed.

---

## 4. Verifying a signature landed

After a build, confirm in the Harbor UI: the artifact row shows a **signature accessory** (a signed
badge / expandable accessory list) against the digest.

From the CLI:

```bash
# List accessories for a digest via the Harbor API
curl -sS -u "${ROBOT_USER}:${ROBOT_TOKEN}" \
  "https://harbor.corp.example.com/api/v2.0/projects/container-build/repositories/payments-api/artifacts/sha256:<digest>/accessories" \
  | jq '.[].type'
# expect: "signature.cosign"

# Or authoritatively, with cosign
cosign verify --key "${KEY_URI}" --insecure-ignore-tlog=true \
  harbor.corp.example.com/container-build/payments-api@sha256:<digest>
```

> Harbor showing a signature accessory means *a* signature exists. It does **not** mean the signature is
> from your key. Only `cosign verify` (and Policy Controller) establish that. Do not treat the Harbor
> badge as an authorisation decision.

---

## 5. Enforcement on the production project

On `container-prod` → **Configuration**:

- **Deployment security → Cosign:** enable *"Prevent artifacts from being pulled unless they are signed
  with a Cosign signature"*.
- **Prevent vulnerable images from running:** enable, threshold aligned with the twistcli gate in `04 §3`
  (defence in depth — the pipeline gate is primary).
- **Automatically scan images on push:** enable.

> **Harbor's enforcement is a useful backstop, not the primary control.** It checks that *a* signature
> exists, not that it chains to your key, and it only applies to pulls Harbor mediates. The authoritative
> gate is Policy Controller (`06`), which verifies against the Venafi public key at admission. Configure
> both; rely on the latter.

---

## 6. Retention and garbage collection

> **Failure mode:** a retention rule that keeps the last N image artifacts but not their `.sig`
> accessories will silently delete signatures. Images then fail admission with "no matching signatures",
> and nothing in the build pipeline flags it because the image is still present.

Configure and then verify:

- Retention rules on `container-prod` must retain signature accessories alongside their subject artifact.
  Harbor 2.5+ treats accessories as bound to the subject — **confirm this on your version** by running a
  retention job in a sandbox project and re-verifying afterwards.
- After any GC run on `container-prod`, re-run `cosign verify` against a sample of images as a smoke test.
- Add a scheduled job that verifies a sample of production images weekly and alerts on failure (`07 §7`).

---

## 7. Replication

If replicating `container-build` → `container-prod`, or to a DR/edge registry:

- Signatures replicate **only if the replication rule matches them**. Harbor applies the rule to the
  signature the same way it applies it to the signed artifact.
- Filters on tag patterns can silently exclude `sha256-*.sig` artifacts. Prefer digest/label-based
  filters, or explicitly confirm signatures arrive.
- **Validate after configuring:** replicate one image, then run `cosign verify` against the *destination*
  registry reference. An image that verifies at source and not at destination means the signature did not
  replicate.

---

## 8. Acceptance checklist

- [ ] `container-build` (unenforced) and `container-prod` (enforced) projects exist
- [ ] Build robot has push + artifact read; production robot is pull-only; both scoped to one project; 90-day expiry
- [ ] `cosign sign` succeeds against `container-build` (confirms the #22650 split works)
- [ ] Signature accessory visible in the UI and via the accessories API
- [ ] `cosign verify` passes against the Harbor reference
- [ ] Enforcement on `container-prod` blocks an unsigned artifact (negative test)
- [ ] Promotion by digest carries the signature; verify at the destination
- [ ] Retention/GC validated in a sandbox — signatures survive
- [ ] Robot tokens stored in Vault, not in job configuration

---

## Sources

- [Harbor — Sign artifacts with Cosign or Notation](https://goharbor.io/docs/2.13.0/working-with-projects/working-with-images/sign-images/)
- [Harbor — Implementing content trust](https://goharbor.io/docs/2.8.0/working-with-projects/project-configuration/implementing-content-trust/)
- [Introducing Cosign in Harbor v2.5.0](https://goharbor.io/blog/cosign-2.5.0/)
- [goharbor/harbor#22650 — Cosign deployment policy blocks manifest reads during signing](https://github.com/goharbor/harbor/issues/22650)
