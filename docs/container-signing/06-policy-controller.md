# 06 — Kubernetes Admission: Sigstore Policy Controller

> **Prereqs:** `01`–`05` complete. Images signed with the Venafi key and present in `container-prod`.
> The Venafi public key exported per `01 §8`.
>
> **Ownership:** **Kubernetes platform** owns the controller and policies. **PKI team** owns the public
> key and its rotation. **AppSec** signs off on enforcement scope.

---

## 1. ⚠ Read this before you deploy — the transparency-log problem

**This is the highest-risk item in the entire SOP. Validate it in a sandbox cluster before any
production rollout.**

The problem:

- We sign with `--tlog-upload=false` (`04 §10`) because we have no public Rekor and our images are
  private. **Our signatures therefore have no transparency-log entry.**
- **cosign 2.x verifies Rekor entries for key-based signatures**, not only for keyless ones.
- Policy Controller's documentation states: *"When `ctlog` key is not specified, the public Rekor
  instance will be used."*
- The v1beta1 `TLog` type exposes **only `url` and `trustRootRef`** — there is **no `disable` field**,
  unlike Kyverno which has an explicit `ignoreTlog: true`.
- There is an open regression about failures when `ctlog` is absent
  ([sigstore/policy-controller#479](https://github.com/sigstore/policy-controller/issues/479)).

**The risk:** Policy Controller attempts a public Rekor lookup for our signature, finds nothing, and
rejects the image. Because admission fails *closed*, discovering this in production means every
deployment into an enforced namespace stops.

### Decide between two paths — do this before writing any policy

**Path 1 — no transparency log (try this first).** Configure a `key` authority with `ctlog` omitted and
test whether your Policy Controller version verifies without a tlog lookup. Some versions set the
ignore-tlog behaviour automatically for key authorities. **If it works on your version, pin that version
and add a regression test** (`08`) — this behaviour has changed between releases before.

**Path 2 — run a private Rekor (the robust answer).** Deploy an internal Rekor instance, sign with
`--rekor-url=https://rekor.corp.example.com` and tlog upload **enabled**, then point the policy at it:

```yaml
ctlog:
  url: https://rekor.corp.example.com
```

This is more infrastructure, but it is the configuration Policy Controller is designed around, it removes
version-dependent behaviour, and it gives you a genuine tamper-evident signing log — real audit value,
not just a workaround. **If you choose Path 2, update `04 §10`**: remove `--tlog-upload=false`, add
`--rekor-url`, and drop `--insecure-ignore-tlog` from the verify gate.

> **Honest note on your tooling choice.** You selected Policy Controller, and it is a reasonable,
> actively-maintained choice (v0.15.x, monthly minor releases, sigstore-go TUF client). But Kyverno's
> `verifyImages` has an explicit `ignoreTlog: true` that makes Path 1 a supported configuration rather
> than a version-dependent behaviour. If sandbox testing shows Path 1 does not work on your version and
> you do not want to run a private Rekor, **switching to Kyverno is a smaller change than it looks** —
> the signing pipeline is identical and only this document changes. Make that call during validation,
> not after rollout.

---

## 2. Install

```bash
helm repo add sigstore https://sigstore.github.io/helm-charts
helm repo update

helm install policy-controller sigstore/policy-controller \
  --namespace cosign-system --create-namespace \
  --version <pinned-version>
```

Pin the chart and image versions. Given §1, an unpinned upgrade can change verification behaviour and
break admission cluster-wide.

---

## 3. Close the namespace opt-in gap

By default the controller **only validates namespaces labelled `policy.sigstore.dev/include: "true"`**:

```bash
kubectl label namespace payments policy.sigstore.dev/include=true
```

> **This default is a real bypass.** A team creating a new namespace gets no enforcement and no warning.
> Every namespace created after rollout silently escapes policy — and nothing surfaces it.

**Invert it to opt-out.** Change `matchExpressions` in both the `ValidatingWebhookConfiguration` and the
`MutatingWebhookConfiguration` to:

```yaml
matchExpressions:
  - key: policy.sigstore.dev/exclude
    operator: DoesNotExist
```

Now every namespace is enforced unless explicitly excluded:

```bash
kubectl label namespace kube-system policy.sigstore.dev/exclude=true
```

Rollout sequence — do not skip steps:

1. Exclude system namespaces **first** (`kube-system`, `kube-public`, `cosign-system`, your CNI/CSI/
   monitoring namespaces). The vendor warns opt-out *"might cause some grief in system namespaces"*.
2. Set `no-match-policy: warn` during rollout so unmatched images warn rather than block.
3. Deploy policies in `mode: warn`.
4. Watch warnings for a full deployment cycle; fix what surfaces.
5. Flip policies to `mode: enforce`, then tighten `no-match-policy` to `deny`.

If you keep the opt-in default instead, you **must** add a compensating control — an audit policy or
scheduled job that alerts on namespaces lacking the `include` label. Track it as a real control, not a
best-effort script.

---

## 4. The ClusterImagePolicy

```yaml
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: venafi-signed-production-images
spec:
  # Start in warn; flip to enforce after a full validation cycle (§3)
  mode: warn

  images:
    - glob: "harbor.corp.example.com/container-prod/**"

  authorities:
    - name: venafi-codesign-prod
      key:
        hashAlgorithm: sha256
        data: |
          -----BEGIN PUBLIC KEY-----
          MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...        # container-prod.pub from 01 §8
          -----END PUBLIC KEY-----
      # ctlog: OMITTED for Path 1 (no transparency log).
      # For Path 2, uncomment and point at your private Rekor:
      # ctlog:
      #   url: https://rekor.corp.example.com
```

Notes on the schema, confirmed against the v1beta1 API:

- `key.data` — inline PEM public key. A `KeyRef` must specify **exactly one** of `secretRef`, `data`, or `kms`.
- `key.hashAlgorithm` — defaults to `sha256`; set explicitly for clarity. Must match the signing algorithm
  (EC P-256 → sha256, per `01 §1`).
- `key.secretRef` — alternative; references a secret **in the namespace where policy-controller is
  installed** (`cosign-system`), and uses the first key value in the secret.
- `mode` — `enforce` (default, reject) or `warn` (admit with a warning).
- `images[].glob` — golang `filepath.Match` semantics plus `**`. **Always include the registry host.**
  Without a host, `index.docker.io` is defaulted, and a hostless glob will silently fail to match your
  Harbor images.

**Combination semantics — get this right or you will build a policy that does nothing:**

> Each matching `ClusterImagePolicy` is **AND**ed for admission; **authorities within one policy are
> OR**ed.

So a second authority added to this policy *weakens* it (any one may pass). To require multiple
independent conditions, use **separate** ClusterImagePolicies.

---

## 5. Default-deny for everything else

A policy that only matches `container-prod` leaves every other image unconstrained. Add a catch-all and
explicitly allow what must be permitted:

```yaml
# Explicitly permit approved third-party/system images that carry no signature
apiVersion: policy.sigstore.dev/v1beta1
kind: ClusterImagePolicy
metadata:
  name: allow-approved-unsigned
spec:
  images:
    - glob: "registry.k8s.io/**"
    - glob: "harbor.corp.example.com/mirror-approved/**"
  authorities:
    - name: allow
      static:
        action: pass
```

`static` authorities skip signature checking entirely and apply the declared `action` (`pass` or `fail`).
Use them deliberately and keep the list short and reviewed — every glob here is an exception to your
supply-chain control.

Then set the controller's `no-match-policy` to `deny` so an image matching no policy is rejected rather
than admitted. Do this **last**, after the warn cycle in §3.

---

## 6. Digest resolution

Policy Controller *"resolves the image tags to ensure the image being ran is not different from when it
was admitted"* — the mutating webhook rewrites tags to digests at admission.

This closes the tag-mutation gap end to end: we sign a digest (`04 §8`), and admission pins the running
workload to a digest. Keep the **mutating** webhook enabled; disabling it leaves a TOCTOU window between
admission and image pull.

---

## 7. Key rotation

The public key is embedded in the CIP, so rotation is a policy change. To rotate without an outage, add
the new key as a **second authority** (remember: authorities are OR'ed, so both are accepted during
overlap):

```yaml
  authorities:
    - name: venafi-codesign-prod-v1     # outgoing
      key: { data: "<old PEM>" }
    - name: venafi-codesign-prod-v2     # incoming
      key: { data: "<new PEM>" }
```

Sequence: add v2 → cut the pipeline over to the v2 key → wait for every running image signed with v1 to
be redeployed or re-signed → remove v1. Full procedure in `07 §2`.

---

## 8. Validation (must all pass before `mode: enforce`)

| # | Test | Expected |
|---|---|---|
| 1 | Deploy an image signed with the Venafi prod key | **Admitted** |
| 2 | Deploy an unsigned image into an enforced namespace | **Rejected** |
| 3 | Deploy an image signed with a *different* key | **Rejected** |
| 4 | Deploy by tag | Admitted **and rewritten to a digest** |
| 5 | Delete the signature accessory in Harbor, redeploy | **Rejected** |
| 6 | Deploy into an excluded namespace | Admitted (no enforcement) |
| 7 | Create a brand-new namespace, deploy unsigned | **Rejected** (proves the opt-out inversion in §3) |
| 8 | Restart the policy-controller pods, re-run test 1 | Admitted — **no dependence on a cached tlog result** |
| 9 | Block egress to `rekor.sigstore.dev`, re-run test 1 | **Admitted** — proves no public Rekor dependency (§1) |

> **Test 9 is the one that matters most.** If it fails, Path 1 is not viable on your version and you must
> take Path 2 (private Rekor) or move to Kyverno. Run it in a sandbox cluster with egress genuinely
> blocked — not merely assumed to be blocked.

---

## 9. Operational guard rails

- **Fail-closed blast radius.** A broken CIP or an unavailable controller blocks all deployments. Keep a
  documented break-glass: label a namespace `policy.sigstore.dev/exclude=true` to bypass, restricted to
  the on-call platform role and alerted on.
- **Alert on webhook health.** Admission webhook failures should page — silent controller failure with
  `failurePolicy: Ignore` means unsigned images flow freely.
- **Pin versions** (§1) and test upgrades in a sandbox against the §8 matrix.
- **Review `static: pass` globs quarterly** — they are documented exceptions and tend to accumulate.

---

## Sources

- [Sigstore Policy Controller overview](https://docs.sigstore.dev/policy-controller/overview/)
- [Policy Controller API types (v1beta1)](https://github.com/sigstore/policy-controller/blob/main/docs/api-types/index.md)
- [sigstore/policy-controller#479 — failure when `ctlog` is absent](https://github.com/sigstore/policy-controller/issues/479)
- [Kyverno — verify images / Sigstore](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/) (fallback option, §1)
