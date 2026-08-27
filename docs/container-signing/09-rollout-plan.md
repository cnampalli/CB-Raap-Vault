# 09 — Rollout Plan and Go/No-Go Gates

> **Purpose:** sequence the delivery so that enforcement is switched on only after it is proven, and so
> that a failure at any stage is recoverable without an outage.
>
> **Prereqs:** `08` validation passed in a sandbox.
>
> **Ownership:** **Platform engineering** drives. Each gate has a named approver.

---

## 1. Principles

1. **Enforcement is always last.** Build, scan, sign and verify can all run for weeks in observe-only mode.
   Nothing breaks until a policy moves to `enforce`.
2. **Warn before you block.** Every enforcement point has a warn mode. Use it and read the output.
3. **One variable at a time.** Do not roll out signing and enforcement together — when something breaks you
   will not know which caused it.
4. **A rollback must be a config change, not a redeploy.** Every gate below has a defined back-out.
5. **The build pipeline is not the risk. Admission is.** A signing failure fails one build. An admission
   misconfiguration stops every deployment in the cluster.

---

## 2. Phases

```
Phase 0  Sandbox            ── 08 validation                    ── no production exposure
Phase 1  Foundations        ── TPP, Vault, Harbor, agents        ── no pipeline change
Phase 2  Pilot signing      ── one app signs, observe-only       ── nothing enforced
Phase 3  Fleet signing      ── all apps sign                     ── nothing enforced
Phase 4  Admission (warn)   ── policies deployed, mode: warn     ── nothing blocked
Phase 5  Admission (enforce)── mode: enforce, no-match deny      ── enforcement live
Phase 6  Steady state       ── 07 operations                     ── BAU
```

---

## 3. Phase 0 — Sandbox validation

**Goal:** prove the chain and decide the enforcement architecture.

| Item | Detail |
|---|---|
| Entry | `01`–`06` implemented in sandbox |
| Work | Run `08` in full |
| Exit | All `08` phases pass; **`V-35` resolved** and Path 1 / Path 2 / Kyverno decided (`06 §1`) |
| Duration | 1–2 weeks |
| Back-out | N/A — no production exposure |

> **Gate 0 — approver: Platform lead + AppSec.**
> Do not proceed without a decided answer to the transparency-log question. Everything downstream depends
> on it, and discovering it at Phase 5 means unwinding enforcement under pressure.

---

## 4. Phase 1 — Production foundations

**Goal:** stand up the production-side components. **No pipeline changes yet** — nothing signs.

| Item | Detail |
|---|---|
| Work | TPP project/environments (`01`); signing agent pool (`02`); Vault role and secrets (`03`); Harbor project pair and robots (`05`) |
| Verify | Re-run `08` phases A, B and E against production components |
| Exit | A production agent can obtain a grant, list the key, and see `Remote Token` |
| Duration | 1–2 weeks |
| Back-out | Remove the agent label; revoke the grant. Nothing else is consuming these components. |

> **Gate 1 — approver: PKI lead + Platform lead.**
> Confirm key-use permissions are least-privilege (`01 §7`) and the environment's **IP restriction** is
> scoped to the signing agent pool.

---

## 5. Phase 2 — Pilot signing (one application)

**Goal:** one real application signs real images. Nothing consumes the signatures yet.

Pick a pilot with: an active but not business-critical release cadence, an engaged team, and a
non-trivial image. Avoid both the noisiest app and a dormant one.

| Item | Detail |
|---|---|
| Work | Add the signing stages to the pilot's Jenkinsfile (`04`) |
| Verify | `08` phase C on the pilot; signatures visible in Harbor |
| Monitor | Sign-stage success rate, added build duration, grant cleanup (`V-18`/`V-19`) |
| Exit | 20 consecutive green builds; no grant leaks; added duration acceptable to the team |
| Duration | 2 weeks |
| Back-out | Set `SKIP_SIGN=true` or remove the stages. Builds continue unchanged. |

> **Gate 2 — approver: Platform lead + pilot app owner.**
> Explicitly capture the **build-time cost**. If signing adds two minutes to every build, teams will
> resist the fleet rollout — know the number before you ask for it.

---

## 6. Phase 3 — Fleet signing

**Goal:** every production image is signed. Still nothing enforced.

| Item | Detail |
|---|---|
| Work | Roll the shared library into remaining pipelines, in waves of ~5 apps |
| Verify | Per wave: signatures present in Harbor for every image |
| Monitor | Aggregate sign-stage failure rate; Venafi signing volume vs build volume; agent pool saturation |
| Exit | ≥98% of production images built in the last 30 days carry a valid signature; the remainder are identified and explained |
| Duration | 4–8 weeks, depending on estate size |
| Back-out | Per-app: `SKIP_SIGN=true`. Fleet: revert the shared library version. |

**Coverage query** — run before claiming exit:

```bash
# For every image running in production, is there a valid signature?
kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' \
  | sort -u | grep 'harbor.corp.example.com/container-prod' \
  | while read -r img; do
      if cosign verify --key "${KEY_URI}" --insecure-ignore-tlog=true "$img" >/dev/null 2>&1; then
        echo "SIGNED   $img"
      else
        echo "UNSIGNED $img"
      fi
    done
```

> **This query is the Phase 4 entry criterion, and it is not optional.** Every `UNSIGNED` line is a
> deployment that *will* break the moment you enforce. Resolve them all now — this is the single most
> effective thing you can do to avoid an enforcement incident.
>
> Watch for the long tail: infrequently-deployed services, DR-only workloads, batch jobs that run monthly,
> and anything deployed from a pipeline nobody owns. They will not appear in a week of observation.

**Also enumerate what will never be signed by you:** third-party images, base images, operators, and
system components. These need `static: pass` entries (`06 §5`). Build that list here, not at Phase 5.

> **Gate 3 — approver: Platform lead + AppSec.**
> Sign-off requires the coverage query output and the reviewed third-party allow-list.

---

## 7. Phase 4 — Admission in warn mode

**Goal:** deploy admission policy that blocks nothing, and read what it would have blocked.

| Item | Detail |
|---|---|
| Work | Install policy-controller (`06 §2`); exclude system namespaces **first**; set `no-match-policy: warn`; deploy CIPs with `mode: warn` |
| Verify | `08` phase F, expecting warnings rather than rejections |
| Monitor | Every admission warning, daily |
| Exit | A full deployment cycle (including monthly/quarterly batch jobs) with **zero unexpected warnings** |
| Duration | 2–4 weeks — must span your slowest deployment cadence |
| Back-out | Delete the ClusterImagePolicies. Instant, no workload impact. |

> **Warnings are your production dress rehearsal.** Each one is a deployment that would have failed. Treat
> the warning count reaching zero as the gate — not the calendar.
>
> **Do not shorten this phase to hit a date.** The workloads that break under enforcement are precisely
> the ones that deploy rarely, so a two-week window on a monthly cadence proves nothing.

> **Gate 4 — approver: Platform lead + AppSec + application representatives.**
> Requires: zero unexpected warnings across a full cycle, and the exclusion list reviewed.

---

## 8. Phase 5 — Enforcement

**Goal:** unsigned images stop running.

Sequence — **one step per change window**, never combined:

1. Flip the production CIP to `mode: enforce`, scoped to **one namespace** first.
2. Soak 48 hours. Watch admission rejections and deployment success.
3. Expand to remaining application namespaces in waves.
4. Soak one week.
5. Tighten `no-match-policy` to `deny`.
6. Invert the namespace webhook to opt-out (`06 §3`) if not already done, and re-run `V-37`.

| Item | Detail |
|---|---|
| Verify | `08` phase F in enforce mode after each step |
| Monitor | Admission rejection rate; deployment failure rate; webhook availability |
| Exit | One week at full enforcement with no unplanned rejections |
| Duration | 3–4 weeks |
| Back-out | Set `mode: warn` on the CIP — takes effect in seconds and unblocks deployments immediately. **This is the emergency lever; make sure on-call knows it.** |

> **Gate 5 — approver: Platform lead + AppSec + change authority.**
> Before flipping: confirm on-call knows the `mode: warn` back-out and the namespace-exclusion
> break-glass (`06 §9`), and that webhook-availability alerting is live. Enforcement that fails closed
> without an alerted, rehearsed rollback is an outage waiting for a quiet Sunday.

---

## 9. Phase 6 — Steady state

Hand over to `07`. Confirm before closing the project:

- [ ] Operations calendar (`07 §1`) has named owners
- [ ] Monitoring and alerts (`07 §6`) are live and tested
- [ ] Weekly sample-verification job running (catches signature GC)
- [ ] Break-glass procedures rehearsed, not merely documented
- [ ] Evidence pack (`08 §8`) filed
- [ ] Open follow-ups (`07 §9`) have owners and dates
- [ ] On-call runbook references `07 §7` troubleshooting

---

## 10. Rollback summary

Know these before you need them:

| Phase | Symptom | Back-out | Time |
|---|---|---|---|
| 2–3 | Signing failures block builds | `SKIP_SIGN=true`, or revert the shared library | Minutes |
| 2–3 | Venafi/TPP outage | `SKIP_SIGN=true` fleet-wide; re-sign digests later (`07 §4`) | Minutes |
| 4 | Excessive warnings | Delete the CIPs | Seconds |
| 5 | Deployments blocked | CIP `mode: warn` | Seconds |
| 5 | One namespace blocked | Label it `policy.sigstore.dev/exclude=true` | Seconds |
| 5 | Controller unavailable | Investigate; do **not** leave `failurePolicy: Ignore` as a permanent fix | — |
| Any | Suspected key compromise | `07 §5` incident procedure | Immediate |

---

## 11. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Transparency-log behaviour blocks admission | Medium | High | Gate 0 decision; `V-35`; Path 2 or Kyverno available (`06 §1`) |
| Unsigned long-tail workloads break at enforce | **High** | High | Phase 3 coverage query; Phase 4 full-cycle warn period |
| Harbor GC deletes signatures | Medium | Medium | `V-29`; weekly verification job |
| Grant collisions under concurrency | Medium | Medium | `LIBHSMINSTANCE` (`02 §6`); `V-21`–`V-23` |
| Version upgrade changes verification behaviour | Medium | High | Pin versions; `07 §11` re-runs `V-35` |
| Signing adds unacceptable build time | Low | Medium | Measured at Gate 2 before fleet commitment |
| Team resistance to a new blocking gate | Medium | Medium | Long warn phases; app reps approve Gate 4 |

---

## 12. Timeline

| Phase | Duration | Cumulative |
|---|---|---|
| 0 — Sandbox | 1–2 wk | 2 wk |
| 1 — Foundations | 1–2 wk | 4 wk |
| 2 — Pilot | 2 wk | 6 wk |
| 3 — Fleet | 4–8 wk | 14 wk |
| 4 — Warn | 2–4 wk | 18 wk |
| 5 — Enforce | 3–4 wk | 22 wk |

**Roughly five months** for a mid-sized estate. Phases 3 and 4 dominate and are the ones under pressure to
compress — they are also the two that prevent an enforcement outage. Compress Phase 1 or 2 if you must;
protect the coverage work in Phase 3 and the full-cycle warn period in Phase 4.
