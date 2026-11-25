# Impact Assessment — <Change name>

<!--
Baseline template for impact assessments. Derived from the CyberArk PSM impact assessment
(docs/cyberark-psm/impact-assessment.md), which is a worked example of every section.

Writing rules
- The main body is read end to end in about 30 minutes. Put reference detail in the appendices.
- State each fact once and link to it from everywhere else. Never copy a number into a second table.
- Prefer one table per topic over paragraphs. Every row that commits someone names an owner and a gate.
- Write complete sentences in the active voice. Avoid "etc.", "as required", "where possible".
- Every open item has one owner (a role) and a needed-by gate. Calendar dates are set at G0.
- Mark vendor facts with a source tag and unconfirmed statements with "(to be validated)" and the check
  that will confirm them.
- Diagrams: SVG generated from a script kept next to the document, with zones as containers, a legend,
  and existing components shown with a dashed outline. The accepted standard style is the one produced by
  docs/cyberark-psm/tools/build_diagrams.py: copy that script and adapt the figure functions.
- Delete these comments and every "<...>" placeholder before review.
-->

| | |
|---|---|
| **Status** | DRAFT v0.x for stakeholder review. Becomes v1.0 when approved at G0 |
| **Date** | <date> |
| **Author** | <role, name> |
| **Scope** | <environments, classifications, sites> |
| **Platform** | <product and version> |
| **Change type** | <Minor / Significant / Major>, confirmed by <change authority> |
| **Decision sought** | <one sentence> |

**How to read this document.**

| Reader | Read | Approve at |
|---|---|---|
| <Steering group> | Executive summary, Delivery plan, Costs | G0 |
| <Architecture forum> | Scope, Solution design, Appendices 1–2 | G1, G2 |
| <Accreditation authority> | Solution design (security), Risks | G4 |
| <Workstream leads> | Workstream commitments, Appendices 3–4 | G1 |

**Conventions.** <Owner and needed-by rule; source tags; identifier prefixes: A, R, D, DEC, KD, G, WP, F, Q.>

**Signing** this document confirms that the signatory has read the sections for their role, accepts
their team's commitments and effort, and agrees the gate at which they approve next.

| Role | Name | Signature and date |
|---|---|---|
| <role> | | |

---

## Executive summary

<!-- One page. A funding approver should need nothing else. -->

**What.** <What changes, in three or four sentences.>

**Why.** <The problem today, in two sentences.>

**Decision sought at G0.** <Numbered list: scope, gates, plan, funding, BAU funding.>

**Recommendation.** <Option, its key dates, its condition, and the fallback.>

| At a glance | |
|---|---|
| Users | |
| New infrastructure | <counts, with totals linked to Appendix 1> |
| Network | <zones, sites, flows, linked to Appendix 2> |
| Effort | <range by plan; largest team share> |
| Duration | <first value; full completion> |
| Ongoing run cost | <FTE> |
| Top risks | <three to five, by ID> |

<Figure 1 — Solution overview: one picture of the end state, steps numbered in order.>

---

## Context

### Current state

| Area | Today |
|---|---|

### Outcomes and measures

<!-- These measures are reported in the closure report. -->

| Outcome | Measure |
|---|---|

---

## Scope

| In scope | Out of scope |
|---|---|

### Assumptions

| # | Assumption | Status (owner, needed by) |
|---|---|---|

### Dependencies

| # | Dependency | Owner | Needed by |
|---|---|---|---|

---

## Solution design

<!-- The basis of the high-level design. One table or figure per subsection. -->

### Components

| Component | Per environment | Sites | Purpose |
|---|---|---|---|

### Network zones

| Zone | Contains | Trust | Accepts connections from |
|---|---|---|---|

<Figure — Network zones and component placement.>

### Sites, high availability and load balancing

<Figure — Site placement.>

| Design point | Design |
|---|---|

### Flows, security controls and operations

<!-- Session or data flows, security controls, logging and detection, as tables and sequence
diagrams. Each failure has a named fallback path. -->

### Capacity

| Item | Basis |
|---|---|

### Resilience and recovery

| Component | On failure | RTO | RPO |
|---|---|---|---|

### Versions and lifecycle

| Item | Decision |
|---|---|

### Decision log

| # | Decision | Status (decided by, gate) |
|---|---|---|

---

## Requirements and deliverables

### Requirements

| # | Requirement ("shall") | Verified by |
|---|---|---|

### Key deliverables

<!-- Group by stage: design and approval; build; assurance; transition and closure. -->

| # | Deliverable | Owner | Approver | Gate | Accepted when |
|---|---|---|---|---|---|

---

## Workstream commitments

<!-- One row per team. Effort is the sum of the team's work-package shares in Appendix 4. -->

| Team | Commits to | Needs (from, by) | Effort (d) | Phases |
|---|---|---|---|---|
| **Total** | | | | |

---

## Delivery plan

### Governance and gates

| Gate | When | Approved by | Evidence | Outcome |
|---|---|---|---|---|

### Recommended plan

<Figure — Delivery schedule with gates.>

| Phase | Content | Exit | Back-out |
|---|---|---|---|

### Entry, exit and acceptance criteria

| Gate | Criteria |
|---|---|

### Testing

| Area | Coverage | Where |
|---|---|---|

---

## Impact

| Area | Rating | Why |
|---|---|---|

### People and ways of working

| Who | What changes | Impact |
|---|---|---|

### Service operations

| Team | Ongoing effort |
|---|---|

### Communications and training

| When | Audience | What |
|---|---|---|

### Debt and concessions

| Item | Owner | Status |
|---|---|---|

---

## Risks

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|

---

## Costs

| Item | Quantity | Amount |
|---|---|---|

---

## Open questions

| # | Question | Owner | Needed by |
|---|---|---|---|

---

# Appendices

## Appendix 1 — Resource summary
<!-- Build specification per role; counts by site and environment; totals for CPU, memory, storage,
IP addresses, DNS records, certificates and licences, calculated from the first two tables. -->

## Appendix 2 — Network flows
<!-- Zone-to-zone flow matrix with ports and initiator; trust-boundary controls; non-production flows. -->

## Appendix 3 — Workstream detail
<!-- Tasks and acceptance criteria for each team. -->

## Appendix 4 — Work packages and RACI

## Appendix 5 — Templates for other teams

## Appendix 6 — Options considered

## Appendix 7 — Decision trail
<!-- Answered questions, superseded decisions, review findings and their resolution. -->

## Appendix 8 — Version history, glossary and references
