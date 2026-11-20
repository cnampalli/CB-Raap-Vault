# Impact Assessment — CyberArk Privileged Session Manager (PSM, PSM for SSH, PTA)

| | |
|---|---|
| **Document status** | DRAFT v0.5, for review with every workstream named in section 3.6 |
| **Date** | 2026-11-20 |
| **Author** | CyberArk team (TBC) |
| **Environments** | OFFICIAL, PROTECTED and SECRET (production) |
| **Target platform** | CyberArk PAM Self-Hosted **14.6** |
| **Change type** | **Major technical change** (section 1.3) |
| **Planning horizon** | 12 months |

**How to read this document**

- Section 3.6 lists **what each team is signing up for**: the requests, inputs, acceptance criteria and
  effort. Each team should read its own subsection and the work packages in section 6.
- Section 6 lists **work packages (WP01–WP27)**. Each one has an owner, dependencies and effort, and can
  become an implementation ticket as it stands.
- **TBC (Qn)** = waiting for an answer to open question *n* (section 8). *Assumed* = a working
  assumption; correct it if wrong. Effort and cost figures are **indicative** until each team confirms
  them.
- Sizing and version statements cite CyberArk documentation (section 7). The docs.cyberark.com pages
  could not be opened from the authoring environment (the site's CDN returned a cached "Page not found"),
  so CyberArk facts marked **[CA]** come from CyberArk's own pages as indexed by web search (20 Nov
  2026). Confirm them on the live pages before baselining. Anything still unconfirmed is marked
  **(verify 14.6)**.

---

## 1. Overview

### 1.1 Summary

CyberArk PAM (Vault, PVWA, CPM) is in production in the OFFICIAL, PROTECTED and SECRET environments. It stores
and rotates privileged credentials, but most privileged access still goes **directly** from user
workstations to target systems.

This change introduces **isolated, recorded, ticket-controlled privileged sessions** in all three
classifications:

| Component | Purpose |
|---|---|
| **PSM** (Windows, Remote Desktop Session Host) | Sessions to Windows/RDP targets, databases, web applications and other client-based targets |
| **PSM for SSH (PSMP)** (Linux) | SSH sessions to Linux/Unix servers and network devices |
| **PSM HTML5 Gateway** | Browser-based PSM sessions without an RDP client; **assessed** in Phase 0 (section 2.1.3) |
| **Privileged Threat Analytics (PTA)** | **Mandatory.** Detects risky privileged activity and PSM bypass; feeds the SIEM |
| **Vault administration VM** | Dedicated, hardened VM per classification from which the CyberArk team administers the Vault (PrivateArk Client, PARClient and admin tools), so no one logs on to the Vault servers interactively |
| **ServiceNow ticketing integration** | Every session or credential use needs a valid Incident or Change |
| **SIEM integration** | CyberArk → Cribl → Splunk → DSOC: logs, dashboards, alerts, use cases |
| **Load balancing** | Highly available PSM and PSMP pools with health checks and site distribution |
| **Onboarding** | All in-scope target accounts, platforms, Safes, CPM/reconcile policies, connection components, break-glass accounts, and application local credentials where rotation is natively supported |
| **Bypass prevention** | Network, credential, platform and detection controls so privileged access can't skip PSM/PSMP |

### 1.2 Drivers and outcomes

| Outcome | Measure of success |
|---|---|
| No standing knowledge of privileged passwords | In-scope accounts are used through PSM/PSMP only; passwords rotated by CPM; *Retrieve* not granted to end users |
| Every privileged session is authorised by a ticket | 100% of PSM/PSMP sessions carry a valid ServiceNow Incident/Change, or a logged and alerted emergency bypass |
| Every privileged session is recorded and auditable | Recordings retrievable by authorised auditors for the retention period (TBD, Defence) |
| Bypass is prevented and detected | Direct RDP/SSH/DB/admin-web access to in-scope targets blocked from user networks; attempts alerted in Splunk/DSOC |
| Resilient service | No single point of failure in PSM/PSMP pools; node loss does not stop new sessions |
| Supportable for its lifetime | Supported OS (Windows Server uplift, section 2.1.2), version-aligned pools, documented upgrade path |

### 1.3 Change type: Major technical change

| Criterion | Assessment |
|---|---|
| New infrastructure | Yes: 36 PSM/PSMP servers, plus PTA (3) and, if approved, HTML5 Gateway (6), load balancer VIPs |
| Changes how people work | Yes: about 540 privileged users (250 PROTECTED, 200 SECRET, 90 OFFICIAL) change how they reach Windows, Linux, network, database and web targets |
| Network | Yes: new flows in all three classifications; direct administrative paths removed (enforcement) |
| Identity | Yes: AD OUs, GPOs, service accounts, delegations; break-glass account changes |
| Enterprise integrations | Yes: ServiceNow, Cribl/Splunk/DSOC, monitoring, backup |
| Security / accreditation | Yes: new components and new data (recordings) at PROTECTED and SECRET |
| Licensing / procurement | Yes: RDS CALs, CyberArk PSM/PSMP/PTA entitlement, RHEL, client tools, Splunk ingest |
| Operating system lifecycle | Yes: Windows Server 2019 → newer version for PSM (section 2.1.2) |

**Classification: Major.** Confirm against the change framework's criteria (Q12).

---

## 2. Scope

### 2.1 Description

#### 2.1.1 Server inventory

Per classification (identical in OFFICIAL, PROTECTED and SECRET; CND pools in OFFICIAL *Assumed*, Q32):

| Pool | Role | Nodes | Users | VIP |
|---|---|---|---|---|
| Consumer PSM | PSM (Windows) | 4 | Consuming teams | `psm-<env>` (RDP 3389; 443 if HTML5) |
| Consumer PSMP | PSM for SSH (Linux) | 4 | Consuming teams | `psmp-<env>` (SSH 22) |
| CND PSM | PSM (Windows) | 2 | CND only | `psm-cnd-<env>` |
| CND PSMP | PSM for SSH (Linux) | 2 | CND only | `psmp-cnd-<env>` |
| **Subtotal** | | **12** | | 4 VIPs |
| PTA | Privileged Threat Analytics (**mandatory**) | 1 (HA/DR per CyberArk guidance, Q24) | Security / DSOC | — |
| Vault admin VM | Windows Server 2022, hardened; CyberArk admin tools only; administers Vault **and DR Vault** (3.6.14a) | 1 | CyberArk team only | — |
| HTML5 Gateway | **Optional**, decided in Phase 0 (2.1.3) | 2 | Consumers (and CND if required) | `psm-gw-<env>` (443) |

**Totals across the three classifications:** 36 PSM/PSMP servers, **plus 3 PTA and 3 Vault admin VMs
(42 firm), plus 6 HTML5 Gateway if approved.** Procurement and Data Centre Engineering need to plan for
**up to 48 VMs** (plus up to 4 scale-out PSM nodes, section 3.6.1) and 12–15 VIPs.
OFFICIAL has fewer users (section 3.6.1): its consumer pools could be right-sized to 3 + 3 after the
performance test; this draft keeps 4 + 4 for consistency.

CND pools are separate from consumer pools: separate VIPs, Safes and RBAC, so CND's tooling and access
are isolated from the consumer service. *Assumed:* CND pools are reached only from CND networks (Q20).

#### 2.1.2 Operating system and versions

| Item | Decision / recommendation |
|---|---|
| CyberArk version | **14.6** for every PSM, PSMP, HTML5 Gateway and PTA node (14.6 builds: PSM 14.6.0.28, PSMP 14.6.0.13 [CA]). **The same PSM version must be installed on every PSM server in a load-balanced environment** [CA] |
| Windows Server for PSM | **Windows Server 2022.** PSM and CPM for PAM Self-Hosted are **not supported on Windows Server 2025** [CA], and the TLS 1.3 option requires PSM on Windows 2022 [CA]. Microsoft lifecycle (checked 20 Nov 2026): **2019** mainstream ended 9 Jan 2024, extended ends **9 Jan 2029** (inside this service's life); **2022** mainstream ended 13 Oct 2026, extended ends **14 Oct 2031**; 2025 extended ends 14 Nov 2034. So: uplift PSM from 2019 to **2022** now; revisit 2025 when CyberArk supports it (before 2031) |
| Windows Server uplift feasibility | Go/no-go gate in Phase 0 (WP06): SOE availability in all three classifications, CIS/hardening baseline, AppLocker and EDR support, RDS role tested with PSM 14.6. If not feasible within the 12 months, build on 2019 and record **concession debt** with a planned uplift |
| Linux for PSMP / PTA / HTML5 Gateway | **PSMP:** RHEL 8 or 9 (all minor versions), Rocky Linux 8 [CA]; SLES 15 and Ubuntu 22.04/24.04 are also listed, and PSMP on Ubuntu (new in 14.6) needs PVWA and PTA 14.6 or later [CA]. PSMP needs a **dedicated** machine [CA]. **PTA:** minimal English install of RHEL **8.8+** or **9.3+** (Rocky/Alma at the same minimums; Oracle Linux RHCK 8.10/9.6) [CA]. Note a known issue: installation on RHEL 9.0 fails with SELinux enabled (9.1+ unaffected) [CA]. **Recommendation:** RHEL 9 (current minor) for PSMP and PTA, if the RHEL 9 SOE exists in all three classifications. **HTML5 Gateway:** Linux (Apache Guacamole-based) per CyberArk's tiered guidance [CA] |
| RDS CAL version | Buy CALs of the **same or newer** version as the PSM operating system. Prefer the newest version available, because newer CALs also license older servers. This avoids a second CAL purchase at the next OS uplift |

#### 2.1.3 HTML5 Gateway assessment (Phase 0)

| Include the HTML5 Gateway if… | Leave it out if… |
|---|---|
| Users' workstations can't run the native RDP client from PVWA *Connect*, or that is restricted | All users have a supported RDP client and PVWA *Connect* works |
| Firewall policy prefers HTTPS 443 from user networks over RDP 3389 | Opening 3389 from user networks to the PSM VIP is acceptable |
| Clipboard/file-transfer controls need to be enforced at the gateway | PSM-side controls are sufficient |

Decision owner: CyberArk architect and Security, end of Phase 0. The cost is 2 Linux nodes per
classification, a VIP and certificates (WP12).

#### 2.1.4 Access methods and "native RDP"

"Native RDP" means two different things, and only one of them skips ticketing:

| Method | What happens | Ticket checked? | In scope |
|---|---|---|---|
| **PVWA *Connect* → RDP file** | User picks the account in PVWA, enters the ticket; PVWA validates it, then hands the user's **own native RDP client (mstsc)** a one-time RDP file to the PSM VIP | **Yes**, at PVWA, before the session | **Yes** (default) |
| PVWA *Connect* → HTML5 Gateway | As above, session in the browser | Yes, at PVWA | If the gateway is approved (2.1.3) |
| **RDP client straight to PSM** (user types a PSM *connection string* into mstsc, never visits PVWA) | PSM starts the session itself | **Not by PVWA**; whether 14.6 can prompt for or pass a ticket on this path is unconfirmed (verify 14.6) | **No**, unless verified (options N1–N4 below) |
| Native SSH through PSMP | User's own SSH client to the PSMP VIP | **Yes**: PSMP asks for the ticketing system and ticket ID and passes them to **PVWA**, which validates them before credentials are released [CA] | **Yes** |
| Password *Show/Copy* (*Retrieve*) | — | — | Break-glass only, under check-out/check-in, dual control and a ticket |

So users **do** keep their native RDP client: it's launched by PVWA after the ticket check. What is
excluded is starting a PSM session from mstsc without going through PVWA.

**Decision (20 Nov 2026): N1.** The direct connection-string path to PSM is disabled. Options considered:

| Option | How | Ticket enforced | Notes |
|---|---|---|---|
| N1. PVWA *Connect* with RDP file (recommended) | As above | Every session | Native client; one extra step (PVWA). No extra build |
| N2. Access request, then native connection string | User submits an access request in PVWA with a ticket (dual-control/request workflow); once approved for a time window, connects with mstsc and the connection string | Once per request window, if PSM honours the approved request on the connection-string path (verify 14.6) | Fewer PVWA visits for long jobs. **Test before relying on it**; if PSM does not enforce the request on that path, N2 is not acceptable |
| N3. Ticket in the connection string / PSM prompt | User supplies the ticket on the direct path, validated by the same ticketing plugin | Every session | Only if 14.6 supports it on the RDP connection-string path (verify 14.6) |
| N4. Allow the direct path with detection only | Direct connection-string sessions allowed; Splunk flags sessions without a ticket for review | After the fact | Doesn't meet "ticket first"; record as a concession if chosen |

#### 2.1.4a PSMP: ticket entry for native SSH

Users keep their own SSH client and enter the ticket at PSMP. The design and the tests that prove it:

| Item | Design |
|---|---|
| How the user gives the ticket | After the user authenticates, PSMP asks for the **ticketing system name and ticket ID**; both can also be given in the PSMP connection string [CA]. Ticket IDs can't contain `( ) = ,` [CA] |
| Who validates | **PVWA**, with the same ServiceNow integration and rules as PVWA *Connect* [CA]. So **PSMP needs a network path to PVWA** (not to ServiceNow), and one rule set covers RDP and SSH |
| ServiceNow side | Validation logic lives in ServiceNow (2.1.5a), not in scripts on PSMP |
| MFA | PVWA MFA caching (SSH key) so the smart-card login at PVWA covers SSH; ticket still asked per session |
| Failure | ServiceNow unreachable or ticket invalid: session refused; emergency path as 3.6.9 |
| Fallbacks (only if the Phase 2 test fails) | P1. Access request first in PVWA, PSMP allows sessions only while approved. P2. SSH launched from PVWA *Connect* through PSM (PSM-SSH); users lose their native SSH client. P3. Reason only, reconciled in Splunk (concession) |


#### 2.1.5 ITSM integration options (ServiceNow and SM9)

**Decision (20 Nov 2026): I1, ServiceNow in each classification** (three instances or connectors). The
other options are kept below for the record.

The ticketing check runs in PVWA through a ticketing-system plugin configured per platform, so
different platforms (or classifications) can use different ITSM systems (more than one ticketing system
can be configured; PSMP users name the system with the ticket [CA]).

| Option | Description | Pros | Cons / dependencies |
|---|---|---|---|
| **I1. ServiceNow, CyberArk's ServiceNow integration** | PVWA plugin queries ServiceNow (Incident/Change) over its API at connect time: exists, type, state, window, assignment, CI | Vendor-supported; rich validation; matches the user's answer | PVWA in each classification must reach a ServiceNow instance at that classification (Q23) |
| **I2. SM9 (OpenText/Micro Focus Service Manager), CyberArk's HP Service Manager integration** | CyberArk has historically shipped an HP Service Manager (HPSM) ticketing integration; SM9 is its successor line | Uses the ITSM already in place where SM9 is the system of record | **Verify** that 14.6 still ships and supports it, and for which SM9 versions/APIs (SOAP/REST). PVWA must reach SM9 |
| **I3. Per-classification mix** | e.g. ServiceNow where available, SM9 where it is the system of record (often the higher classification) | Each environment uses its own ITSM | Two integrations to build, test and support |
| **I4. Custom ticketing plugin / broker** | CyberArk's ticketing SDK (custom plugin), or a small internal broker API that answers "is ticket X valid for user Y and target Z?" by querying ServiceNow or SM9 | Works when PVWA can't reach the ITSM directly; one interface for both ITSMs; rules under your control | Development and ownership (like custom authentication, chunk 11 of the PKIPN guide); support boundary with CyberArk |
| **I5. ITSM-initiated access** | ServiceNow (or SM9) approves a request and calls the CyberArk REST API to grant time-boxed access (Safe membership or approved request) | Access only exists while the ticket is approved; good audit trail in the ITSM | Integration build in the ITSM; must still block sessions outside the window; CyberArk also offers ServiceNow apps for this (verify availability for Self-Hosted 14.6) |
| **I6. Format check + after-the-fact reconciliation** | PVWA requires a ticket reference in a valid format (no live lookup); Splunk joins session data with an ITSM export daily | No live dependency on the ITSM; quick to build | Not "ticket first"; invalid tickets found only afterwards. Fallback or interim only |

**Common to all options:** deny by default when the ITSM is unreachable; emergency bypass by named
roles with dual control, always alerted (3.6.9); ticket stored with the session and sent to Splunk.

#### 2.1.5a ServiceNow-side validation ("validation scripts in ServiceNow")

Yes, the rules can live in ServiceNow. Recommended pattern, keeping the CyberArk side standard:

| Layer | What it does |
|---|---|
| ServiceNow business rules / script includes | Keep a **computed eligibility** on each Incident and Change, for example a field "CyberArk access allowed" = true only when: type and state allowed (Incident *In Progress*; Change *Implement*), now within the Change's planned window, assignment group or assignee set, CI present. Recomputed on every update, and by a scheduled job at window start and end |
| ServiceNow ACLs | The CyberArk integration user can read only the fields it needs, including the eligibility field |
| CyberArk ticketing integration (I1) | Queries the ticket and checks the eligibility field (plus the basic fields it supports natively). Exact query capability of the 14.6 plugin to confirm (Q33) |
| Per-request checks that need the user or target | The ServiceNow integration can confirm that the **requester matches the person on the ticket** (since 10.6) [CA]. Matching the **target CI** needs the plugin to send the target (verify 14.6). If the standard plugin can't, either a ServiceNow **Scripted REST API** that takes ticket + user + target and returns allow/deny, called by a small **custom ticketing plugin** (I4), or accept ticket-level checks only |
| Audit | ServiceNow logs each validation call; CyberArk stores the ticket with the session; both go to Splunk |

ServiceNow-side effort is in WP16 (validation logic, ACLs, tests, three instances).

#### 2.1.6 Targets and onboarding in scope

| Target type | Connection | Typical connection components / plugins |
|---|---|---|
| Windows servers | PSM (RDP) | PSM-RDP |
| Linux / Unix servers | PSMP (SSH); PSM-SSH as a fallback | PSMP; PSM-SSH (PuTTY-based) |
| Network devices | PSMP (SSH); PSM for HTTPS management UIs | PSMP; web connectors |
| Databases | PSM, through a client on the PSM server | e.g. SSMS, SQL Developer, Toad, pgAdmin (client list TBC Q21) |
| Web applications / admin consoles | PSM, browser-based | PSM web application connection components (Chromium/Edge + web driver) |
| Virtualisation / out-of-band (vCenter, ESXi, iLO/iDRAC, storage, backup) | PSM web or SSH | Web connectors, SSH |

**Onboarding includes:** all in-scope target accounts; platforms (password policy, CPM change/verify/
reconcile, session settings); Safes and RBAC; reconcile accounts; connection components and plugins;
AD changes for CPM and PSM; **break-glass accounts** for every in-scope platform (local Administrator,
root, network device local accounts, application local admins, emergency domain accounts) under
check-out/check-in; and **application local credentials rotated off natively** wherever a CPM plugin or
the application's own API supports it (databases, network devices, virtualisation, out-of-band
controllers, applications with a supported plugin). Where an application can't be rotated natively, its
accounts are still vaulted, used through PSM and recorded, and the gap is recorded as **concession
debt** with an owner.

### 2.2 Assumptions

| # | Assumption | Confirm |
|---|---|---|
| A1 | Vault, DR Vault, PVWA and CPM in all three classifications are healthy and on 14.6, or will be before PSM goes live | Q3 |
| A2 | PSM, PSMP and PTA are within the current CyberArk licence entitlement, or will be bought | Q14 |
| A3 | PSM specs match the existing PSM-equivalent environment ("match other envs"); CyberArk's minimum is the floor (section 3.6.1) | Q22 |
| A4 | Privileged users: **250 PROTECTED, 200 SECRET** (90 OFFICIAL, see Q29); peak concurrent sessions sized at **2–4 per active user** (section 3.6.1) | answered |
| A5 | PSM servers are domain-joined, in a dedicated OU with the CyberArk PSM hardening GPO | Q6 |
| A6 | PSMP authenticates users against AD (AD Bridge) and uses PVWA MFA caching (SSH key), so SSH access inherits PVWA's smart-card authentication | Q6 |
| A7 | **ServiceNow in each classification** (answered); PVWA and PSMP of each classification reach that classification's instance | answered / Q23 for connectivity |
| A8 | Each classification has its own Cribl workers and Splunk indexes, feeding DSOC | Q11 |
| A9 | Two data centres (sites) per classification; pools split evenly across sites | Q25 |
| A10 | SECRET has no internet access; media, plugins, Ansible collections and client tools are brought in through the approved transfer process | Q9 |
| A11 | Session recording retention is **TBD** (Defence); design supports a configurable retention period | Q8 |
| A12 | Existing jump hosts stay available until bypass prevention (Phase 5), then are retired or restricted | Q26 |

### 2.3 Risks

| # | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | Up to 48 VMs across three classifications delayed by procurement or capacity | M | H | Raise the capacity request in Phase 0; build PROTECTED first | DCE / Procurement |
| R2 | Firewall changes across many target networks take longer than planned | H | H | One consolidated firewall matrix per classification; target inventory up front; waves | Network |
| R3 | **Capacity**: above CyberArk's 60-sessions-per-PSM ceiling, 4 consumer PSM nodes don't cover the top of the PROTECTED/SECRET estimate (section 3.6.1) | M | H | Performance test in Phase 2; scale-out trigger agreed; specs matched to existing env | CyberArk / DCE |
| R4 | RDS CAL shortfall, or no RD Licensing server: PSM refuses sessions after the grace period | M | H | Licence model and quantities agreed in Phase 0 (section 4) | Procurement / Identity |
| R5 | ITSM (ServiceNow / SM9) outage blocks all privileged access | M | H | Defined failure mode: deny with controlled emergency bypass (section 3.6.9), alerted | SNOW team / Security |
| R6 | Vault storage exhausted by recordings | M | H | Sizing formula (section 3.6.12); monitoring and thresholds; archive design | CyberArk / DCE |
| R7 | Hardening, AppLocker or EDR blocks PSM components or client tools | M | M | Agreed exclusions and AppLocker rules before build (WP17) | DevSecOps |
| R8 | Windows Server 2022 SOE not ready in time | M | M | Phase 0 gate; fallback to 2019 with concession and dated uplift | Windows Platform |
| R9 | Load balancer health checks pass while PSM is broken (TCP open, service down) | M | H | Monitoring-driven node drain plus LB checks (section 3.6.3) | Network / M&C |
| R10 | Users bypass PSM through cached or known passwords or other paths | H | H | Rotate all onboarded credentials at onboarding; block direct paths; detection in PTA and Splunk | CyberArk / Network / DSOC |
| R11 | User productivity loss and resistance to the new access method | M | M | Pilot team, guides, drop-in sessions, phased enforcement, hypercare | CyberArk / Service Ops |
| R12 | Application local credentials can't be rotated natively | M | M | Vault + PSM + recording; concession with owner and date | App owners |
| R13 | Break-glass unusable when CyberArk is down | L | H | Documented offline procedure for CyberArk's own emergency access; tested twice a year | CyberArk / Security |
| R14 | Version drift inside a load-balanced pool after partial upgrades | M | M | Pool-level upgrade procedure (section 5.6) | CyberArk |
| R15 | Accreditation of new components at SECRET delays go-live | M | H | Security engaged from design; artefacts produced per phase | Security |
| R16 | Splunk ingest cost or licence exceeded by new sources | M | M | Volume estimate from the pilot; Cribl filtering | SIEM |
| R17 | Known PKI issues (sub-CA pushed into Trusted Root by GPO) affect new servers | H | M | Apply `docs/cyberark-pvwa-pkipn` lessons; fix the GPO at source | Identity / PKI |
| R18 | Onboarding volume unknown, so effort can't be confirmed | H | H | Discovery in WP01; unit rates in section 6 | CyberArk / target owners |

### 2.4 Dependencies

| # | Dependency | Owner | Needed by |
|---|---|---|---|
| D1 | Capacity and VMs (up to 48) to spec | DCE | Phase 1 |
| D2 | Windows Server SOE decision (2022/2025/2019) and RHEL SOE | Windows / Linux Platform | Phase 0 gate |
| D3 | IP addresses, DNS records, VIPs, health checks | Network | Phase 1 |
| D4 | Firewall rules: component flows (Phase 1), target flows (per onboarding wave), bypass blocks (Phase 5) | Network | Phases 1, 4, 5 |
| D5 | AD: OUs, GPOs, service accounts, CPM delegations, RD Licensing | Identity / AD | Phase 1 |
| D6 | Certificates for PSM RDP, HTML5 Gateway, VIP names, PTA, syslog TLS | PKI | Phase 1 |
| D7 | RDS CALs, CyberArk licences, RHEL, client tool licences | Procurement | Phase 1 |
| D8 | ServiceNow instance access, integration user, business rules | ServiceNow team | Phase 2 |
| D9 | Cribl routes, Splunk indexes and add-on, DSOC use cases | SIEM / DSOC | Phase 2 |
| D10 | Monitoring and alerting | M&C | Phase 2 |
| D11 | Ansible execution environment (offline in SECRET), scanning, EDR/AppLocker | DevSecOps | Phase 1 |
| D12 | Target inventories and test users per team; account owners | Consuming teams | Phase 0 (inventory), Phase 4 |
| D13 | Retention period for recordings | Defence | Before go-live (design supports TBD) |
| D14 | Security assessment and accreditation | Security | Phases 2 and 3 |
| D15 | Backup of new servers' configuration | Backup team | Phase 2 |

### 2.5 Exclusions

- Non-production PSM environments (*Assumed*; Q1).
- Changes to Vault, PVWA or CPM architecture beyond what PSM, ticketing and onboarding need (version
  alignment to 14.6 is a dependency, not part of this change).
- RDP sessions started on PSM without PVWA (connection string), unless option N2/N3 is proven (section 2.1.4).
- Remote access from outside the classification networks.
- Endpoint (user workstation) changes beyond publishing guides and, if needed, the RDP client setting.
- Application changes needed to make credentials rotatable; recorded as concessions (R12).
- Cross-classification access (each classification is self-contained).

---

## 3. Requirements

### 3.1 Key deliverables

| # | Deliverable | Acceptance |
|---|---|---|
| KD1 | 36 PSM/PSMP servers built from automation, hardened, registered to the Vault, version-aligned | Build evidence; hardening scan; pool version check |
| KD2 | Load-balanced pools (12 VIPs, 15 with HTML5, across three classifications) with health checks and site distribution | Failover tests passed (section 5.3) |
| KD3 | PTA (mandatory) deployed and integrated (Vault, PSM/PSMP, AD events, SIEM) | Detections fire in test; alerts in Splunk |
| KD4 | HTML5 Gateway decision, and build if approved | Decision record; tests passed |
| KD5 | ServiceNow ticketing integration with validation rules, failure modes and bypass controls | Ticketing test cases passed |
| KD6 | CyberArk → Cribl → Splunk → DSOC integration: sources, dashboards, alerts, use cases | Each use case fires in test |
| KD7 | Monitoring and alerting for all new components | Alerts tested |
| KD8 | Platforms, Safes, RBAC, CPM/reconcile policies, connection components for all in-scope target types | Test matrix passed |
| KD9 | All in-scope accounts onboarded, including break-glass and native application credentials | Onboarding reports; rotation success rate |
| KD10 | Bypass prevention in force (network, credential, platform, detection) | Bypass test cases fail as intended; detections fire |
| KD11 | Recording storage, retention, archive, retrieval and disposal process | Process tested; records sign-off |
| KD12 | Test evidence: functional, security, HA/failover, ticketing, logging, performance, DR, UAT | Test report signed off |
| KD13 | Service transition: runbooks, knowledge articles, support model, training, hypercare | Service acceptance |
| KD14 | Lifecycle and upgrade procedure for pools and components | Procedure reviewed; dry run |

### 3.2 Other artifacts

- HLD update and LLD (PSM, PSMP, PTA, HTML5 Gateway, ticketing, SIEM, load balancing) per classification.
- Network flow and firewall matrix (component, target, bypass-block flows) per classification.
- Server inventory and sizing record; capacity model.
- Build and hardening guides; Ansible playbooks and inventories (all classifications); as-built records.
- Safe and RBAC design; platform catalogue; connection component catalogue; onboarding runbook.
- ServiceNow integration specification (validation rules, states, failure modes).
- SIEM integration specification (sources, formats, Cribl routes, indexes, use case catalogue).
- Test strategy, test plans, test report.
- User guides (PVWA *Connect*, PSMP SSH syntax, ticket entry, break-glass), FAQ, training material.
- Runbooks: operations, patching, upgrade, failover, recording retrieval/disposal, break-glass, incident.
- Security documentation updates; risk register; concession register.

### 3.3 Baseline documentation

TBC (Q15). Expected: CyberArk HLD/LLD; system security documentation for PROTECTED and SECRET; network
diagrams; SOE build standards; ServiceNow integration standards; SIEM onboarding standard; this
repository's `docs/cyberark-pvwa-pkipn/` (PVWA certificate login, PKI lessons, strong-mapping analysis).

### 3.4 Specification impact

| Specification | Impact |
|---|---|
| CyberArk HLD/LLD | New tiers (PSM, PSMP, HTML5, PTA); ticketing; SIEM; load balancing; recording storage |
| SOE / build standards | PSM role (RDSH + PSM hardening + AppLocker), PSMP role, PTA/HTML5 roles; Windows Server version |
| Network architecture | New flows; enforcement removes direct administrative access; VIPs |
| Identity standards | PSM OU and GPOs; service accounts; delegations; break-glass account standard |
| Access policy | Privileged access to in-scope systems only through PSM/PSMP with a ticket |
| ITSM process | Ticket requirements for privileged access; emergency bypass process |
| Logging and monitoring standard | New sources and use cases |
| Records management | Session recordings as records: retention, disposal |

### 3.5 Functional and non-functional requirements

| # | Requirement |
|---|---|
| FR1 | Users start Windows/RDP, database, web and other client sessions from PVWA *Connect* through the consumer PSM pool |
| FR2 | Users start SSH sessions natively through the PSMP pool, authenticated via AD and PVWA MFA caching |
| FR3 | Every session requires a valid ServiceNow ticket (rules in section 3.6.9) |
| FR4 | Every session is recorded (video for PSM; text/keystrokes for SSH and supported clients) and stored per retention |
| FR5 | Live session monitoring and termination available to authorised operators |
| FR6 | Break-glass accounts use exclusive check-out/check-in with automatic rotation on check-in, dual control and a ticket |
| FR7 | CPM verifies, changes and reconciles onboarded credentials on a policy schedule |
| FR8 | PTA analyses Vault, PSM/PSMP and AD activity and raises alerts to Splunk/DSOC and PVWA |
| FR9 | CND uses its own pools, Safes and roles, isolated from consumers |
| NFR1 | **Availability:** no single point of failure in each pool; loss of one node does not stop new sessions; loss of one site leaves at least half the pool |
| NFR2 | **Capacity:** peak concurrency (section 3.6.1) served with one node out of service (N-1) |
| NFR3 | **Performance:** session launch target ≤ 15 s from PVWA *Connect* to target desktop (to agree in Phase 0) |
| NFR4 | **Security:** hardened to CyberArk guidance and the SOE baseline; no direct user logon to PSM/PSMP servers outside sessions |
| NFR5 | **Logging:** all security-relevant events in Splunk within 5 minutes (to agree with DSOC) |
| NFR6 | **Lifecycle:** all pool nodes on the same CyberArk version; supported OS for the planned service life |

### 3.6 Requirements by workstream: what each team is signing up for

Summary first; details follow.

| Team | What you deliver | Main inputs from the CyberArk team | Effort (indicative) | When |
|---|---|---|---|---|
| Data Centre Engineering | Up to 48 VMs (three classifications), placement across sites, storage, backup policy | Sizing sheet, placement rules | 30–50 d | Phase 1 |
| Network (firewall, DNS, LB) | IPs, DNS, 12–15 VIPs with health checks, component flows, target flows per wave, bypass blocks | Flow matrix per phase | 65–105 d | Phases 1, 4, 5 |
| Windows Platform | Windows Server SOE for PSM (2022/2025 decision), RDSH role baseline | PSM OS requirements | 14–28 d | Phase 0–1 |
| Linux Platform | RHEL SOE for PSMP, PTA, HTML5 Gateway | Component OS requirements | 7–14 d | Phase 0–1 |
| Identity / AD | OUs, GPOs, service accounts, CPM delegations, RD Licensing, break-glass accounts, target GPOs for bypass prevention | AD change list | 28–50 d | Phases 1, 4, 5 |
| PKI | Certificates for PSM, VIPs, HTML5, PTA, syslog TLS; GPO sub-CA fix | Certificate list | 7–12 d | Phase 1 |
| Procurement / licensing | RDS CALs, CyberArk entitlement, RHEL, client tool licences, capacity | Quantities (section 4) | 6–12 d | Phase 0–1 |
| ServiceNow team | Integration user and roles, API access, **validation logic (2.1.5a)**, test tickets, bypass process, in three instances | Integration spec | 25–40 d | Phase 2 |
| SIEM (Cribl, Splunk) | Cribl routes, Splunk indexes/sourcetypes/add-on, dashboards | Source list, samples | 28–50 d | Phase 2 |
| DSOC | Use cases, alert triage runbooks, PTA alert handling | Use case catalogue | 14–28 d | Phase 2–3 |
| Monitoring & Control | Health checks, alerts, capacity dashboards, LB drain integration | Monitoring spec | 11–21 d | Phase 2 |
| DevSecOps | Ansible environment (offline in SECRET), pipelines, scanning, EDR/AppLocker policy | Playbooks, exclusions | 20–35 d | Phase 1–2 |
| Security & Accreditation | Assessment, documentation, pen test, concession approvals | Design, test evidence | 28–50 d | Phases 0–3 |
| Backup | Configuration backup for new servers | Backup scope | 3–6 d | Phase 2 |
| Service Operations / Service Desk | Support model, KB articles, incident categories, training | Runbooks, guides | 14–21 d | Phase 5–6 |
| Records management | Recording retention/disposal procedure | Recording design | 3–5 d | Phase 2 |
| Consuming teams (each) | Target and account inventory, account owners, UAT, rotation tests, application local-credential analysis | Templates, onboarding waves | 3–8 d per team (Q27) | Phases 0, 4 |
| CND | Inventory for CND pools, UAT | Same as consumers | 3–5 d | Phases 0, 4 |
| CyberArk team | Design, build, config, onboarding, testing, handover | — | 450–700 d | All |

#### 3.6.1 Data Centre Engineering

**Deliver:**
- VMs per classification: 4 + 2 PSM (Windows), 4 + 2 PSMP (Linux), 1 PTA (Linux), 1 Vault admin VM
  (Windows), and 2 HTML5 Gateway (Linux) if approved. **Up to 16 per classification, 48 in total.**
- Placement: split each pool evenly across the two sites (A9); no two nodes of a 2-node pool on the same
  host (anti-affinity).
- Storage and backup policy for configuration (recordings live in the Vault, not on the VM).

**Sizing.** Match the specs of the existing equivalent environment (A3, Q22). CyberArk's floor for PSM
is **8 cores, 8 GB RAM, 80 GB system disk + 80 GB temporary workspace** (PSM system requirements).
CyberArk's sizing tiers are 1–5, 6–30 and 31–60 concurrent sessions, and **a PSM server should not
exceed 60 concurrent sessions** [CA, cloud sizing pages]. Proposed starting point, to confirm against the matched environment and the Phase 2
performance test:

| Role | vCPU | RAM | Disks | NICs | Notes |
|---|---|---|---|---|---|
| PSM (Windows) | 8 (floor) – 16 | 16–32 GB | 80+ GB OS; 80+ GB temporary recordings (fast storage) | 1 (management/session) | Each RDP/web session runs a client process on the server; RAM is usually the limit |
| PSMP (Linux) | 4 (floor) – 8 | 8 (floor) – 16 GB | 10 GB install + 40 GB temporary workspace (floor) [CA]; 80 GB proposed | 1 | Dedicated machine [CA]; text recordings |
| PTA (Linux) | per CyberArk PTA recommended server specifications (verify 14.6 figures) | | | 1 | Minimal RHEL 8.8+/9.3+ [CA]; sized by event volume |
| HTML5 Gateway (Linux) | per CyberArk's tiered guidance (verify 14.6 figures) [CA] | | | 1 | Only if approved; browsers need TLS 1.2 [CA] |
| Vault admin VM (Windows) | 4 | 8–16 GB | 100 GB | 1 | Admin tools only; match the existing CyberArk admin build if one exists |

**Concurrency model** (A4, Q19):

| Input | PROTECTED | SECRET | OFFICIAL |
|---|---|---|---|
| Privileged users | 250 | 200 | 90 |
| Active at peak (*Assumed* 30–40%) | 75–100 | 60–80 | 27–36 |
| Sessions per active user | 2–4 | 2–4 | 2–4 |
| Peak concurrent sessions | 150–400 | 120–320 | 54–144 |
| PSM share (*Assumed* 60%; confirm from target mix) | 90–240 | 72–192 | 32–86 |
| PSMP share (40%) | 60–160 | 48–128 | 22–58 |
| **Consumer PSM per node, N-1 (3 serving)** | **30–80** | **24–64** | **11–29** |
| Consumer PSMP per node, N-1 | 20–55 | 16–43 | 7–20 |

**Result against CyberArk's 60-session ceiling** [CA]: with one node down, 3 consumer PSM nodes carry
at most **180** sessions (3 × 60). PROTECTED's estimate is 90–240 and SECRET's 72–192, so **the upper
end exceeds the 4-node pool in both**. Keeping a 70% design margin (≈ 42 sessions per node), PROTECTED
would need up to **6–7** consumer PSM nodes and SECRET up to **5–6** at the top of the range. OFFICIAL
(32–86) fits in 3–4. **Decision:** build 4 per classification as agreed, measure real concurrency in
the pilot, and hold capacity and budget for **+2 PSM nodes in PROTECTED and +2 in SECRET** (R3, section 4
contingency). The scale-out trigger is 70% of 60 sessions per node at peak.

**Acceptance:** VMs delivered to spec; placement evidence; backups configured.

#### 3.6.2 Network: firewall and DNS

**Deliver, per classification:**
- IP addresses and DNS records for every node and VIP.
- **Component flows** (Phase 1). Typical; confirm against the 14.6 port list:

| From | To | Port | Purpose |
|---|---|---|---|
| User networks | PVWA VIP | 443 | Portal, PVWA *Connect* |
| User networks | PSM VIP | 3389 (or 443 if HTML5) | Session to PSM, launched by PVWA |
| User networks | PSMP VIP | 22 | Native SSH through PSMP |
| CND networks | CND PSM / PSMP VIPs | 3389 / 22 | CND sessions |
| PSM, PSMP, PTA, HTML5 GW | Vault, DR Vault | 1858 | Vault protocol |
| PVWA | ServiceNow | 443 | Ticket validation |
| PSMP | PVWA | 443 | Ticket validation for SSH sessions (PSMP passes the ticket to PVWA) [CA] |
| PSM, PSMP | Domain controllers | DNS, Kerberos, LDAP(S), SMB as required | Domain membership, AD Bridge |
| PSM, PSMP, Vault, PTA | Cribl workers | syslog (TLS preferred) / forwarder ports | Logging |
| AD domain controllers / SIEM | PTA | per PTA design | Events for analytics |
| Monitoring | All new nodes | per tool | Health |
| Admin networks (CyberArk team) | PSM/PSMP management | RDP/SSH management ports | Server administration |

- **Target flows** (per onboarding wave, Phase 4): from the PSM/PSMP pools to each target network:
  3389, 22, database ports, HTTPS admin ports, as each wave needs.
- **Bypass blocks** (Phase 5): remove or deny direct administrative access from user networks and jump
  hosts to onboarded targets (3389, 22, database ports, admin web ports), allowing only PSM/PSMP pools,
  CPM and approved management systems.

**Acceptance:** flow tests per phase; bypass tests fail as intended (section 5.3).

#### 3.6.3 Network: load balancing (HA)

| Design item | Requirement |
|---|---|
| Pools | Consumer PSM (4), consumer PSMP (4), CND PSM (2), CND PSMP (2), HTML5 GW (2, if approved), per classification |
| Mode | TCP pass-through (no TLS/RDP termination on the LB for RDP); SSH TCP pass-through |
| Persistence | Source-IP affinity for RDP, so RDP reconnects land on the same node; none needed for SSH |
| Idle timeouts | Longer than the longest allowed session (agree, e.g. 8–12 h) so the LB doesn't drop quiet sessions |
| Health checks | TCP 3389 / 22 **plus** a monitoring-driven drain: if the PSM or PSMP service fails while the port stays open, monitoring disables the node in the LB (R9). Design with M&C (3.6.11) |
| Site distribution | Pools split across both sites; site failure leaves half capacity. Active-active across sites unless the network team requires otherwise |
| Failover behaviour | Sessions on a failed node end; users reconnect and land on a healthy node. Recordings of interrupted sessions are kept up to the failure point (test case) |
| PSMP host keys | All PSMP nodes in a pool present the **same SSH host key**, so users don't get host-key warnings when the LB picks a different node |
| Certificates | PSM RDP certificate on each node includes the VIP FQDN; HTML5 Gateway certificate on the VIP name |
| Versions | All nodes in a pool on the same CyberArk version (upgrade procedure, section 5.6) |
| CyberArk configuration | Per CyberArk's *Install PSM in a Load-Balancing Environment*: an external load balancer presents the PSM servers as one address; CyberArk recommends **DNS load balancing and SSL pass-through** between LB and nodes [CA]. Each PSM server keeps its own server ID (`PSMServer`, then `PSM-<computer name>`), and platforms reference the PSM server ID [CA]. **Live monitoring** uses the PSMAdminConnect user of the node where the session runs, so monitoring must reach that specific node, not the VIP [CA] |

**Acceptance:** failover, drain and site-loss tests passed (section 5.3).

#### 3.6.4 Windows Platform team

- Confirm the Windows Server version (section 2.1.2) and provide the hardened SOE for the PSM role in both
  classifications.
- Allow the RD Session Host role and PSM hardening (CyberArk hardening script/GPO, AppLocker) on top of
  the SOE; document deviations from the SOE baseline.
- **Acceptance:** SOE build passes PSM 14.6 installation and hardening in Phase 1.

#### 3.6.5 Linux Platform team

- RHEL SOE for PSMP, PTA and HTML5 Gateway at a version supported by each 14.6 component.
- Allow PSMP's changes to `sshd` (PSMP takes over port 22; server administration on a separate port or
  path, agreed in design) and AD Bridge packages.
- **Acceptance:** PSMP, PTA (and HTML5) install cleanly on the SOE.

#### 3.6.6 Identity / Active Directory

- OU for PSM servers per classification; link the CyberArk PSM hardening GPO; block or filter
  conflicting domain GPOs (document each).
- PSM connection users (PSMConnect, PSMAdminConnect): domain accounts recommended for load-balanced
  pools (verify 14.6), with password rotation by CPM.
- RD Licensing: licence server per classification, mode (Per User), GPO pointing PSM to it.
- Service accounts: LDAP bind, CPM reconcile accounts, ServiceNow integration (if AD-backed), PTA AD
  access as required.
- **CPM delegations:** *Reset password* (and unlock if needed) on the OUs holding onboarded domain
  accounts.
- **Break-glass accounts:** review existing emergency domain accounts; create or adjust per standard;
  onboard with check-out/check-in.
- **Bypass prevention on targets (Phase 5):** GPOs restricting *Allow log on through Remote Desktop
  Services* and Windows Firewall RDP scope to PSM pools, CPM and approved management systems.
- **Fix at source:** the GPO that places an internal sub-CA in Trusted Root (seen on PVWA; R17).
- **Acceptance:** AD change list implemented and tested per phase.

#### 3.6.7 PKI

- Certificates (internal CA): PSM RDP (node + VIP names), HTML5 Gateway, PTA, syslog TLS to Cribl, any
  web connector trust needs.
- Certificate lifecycle: expiry monitoring and renewal procedure.
- **Acceptance:** certificates issued and installed; chains validate on clients; no non-root
  certificates in Trusted Root on new servers.

#### 3.6.8 Procurement and licensing

See section 4 for quantities. Raise orders in Phase 0–1 so licences are installed before go-live.

#### 3.6.9 ServiceNow team

| Item | Requirement |
|---|---|
| Integration | CyberArk ServiceNow ticketing integration configured on PVWA, per CyberArk's ServiceNow ticketing guide (verify 14.6 install location and prerequisites) |
| Connectivity | PVWA and, if needed for PSMP sessions, the PSMP pools (each classification) → that classification's ServiceNow instance over 443 (Q23, Q33) |
| Integration account | Dedicated ServiceNow user, least-privilege read access to Incident and Change tables; credential vaulted and rotated |
| Validation rules | Ticket exists; type **Incident or Change**; **allowed states** (proposal: Incident *In Progress*, Change *Implement*); Change within its planned window; requester or their group is assigned (*to agree*); configuration item matches the target (*to agree; depends on CMDB quality*) |
| Ticket capture | PVWA *Connect* prompt; PSMP prompt at SSH connection (2.1.4a) |
| Validation logic | In ServiceNow: computed eligibility, ACLs, optional Scripted REST API (2.1.5a) |
| Failure scenarios | ServiceNow unreachable / slow / returns an error / ticket invalid: **deny by default** |
| Bypass controls | Emergency access path: a reason and an emergency code or approver (dual control), limited to named emergency roles, time-boxed, **always alerted to DSOC** and reviewed the next business day |
| Audit | Ticket number stored with the session and in the Vault audit; visible in Splunk |
| **Acceptance** | Every ticketing test case passes (section 5.3) |

#### 3.6.10 SIEM: Cribl, Splunk and DSOC

| Item | Requirement |
|---|---|
| Sources | Vault audit via syslog (Vault `dbparm.ini` syslog settings with an XSL translator for the Splunk/CEF format); PSM and PSMP logs; PTA alerts (syslog); PVWA and CPM logs; ServiceNow integration logs; OS logs of new servers |
| Transport | CyberArk → **Cribl** workers (per classification) → **Splunk** indexes → **DSOC**. TLS where supported |
| Cribl | Routes and pipelines per source; parsing; filtering to control Splunk volume (R16) |
| Splunk | Indexes, sourcetypes, the CyberArk add-on (version for SECRET transferred offline), field extractions |
| Dashboards | Session activity; ticket compliance; break-glass usage; CPM success/failure; PSM/PSMP health and capacity; PTA alerts; bypass detections |
| **Use cases (minimum)** | Session without a valid ticket or emergency bypass used; break-glass check-out; credential *Retrieve* outside break-glass; direct RDP/SSH/DB logon to an onboarded target from a non-PSM source (Windows 4624 logon type 10 / Linux sshd source IP); PTA high-risk alerts; repeated failed PSM/PSMP authentication; CPM verification/change failures; recording upload failures; PSM/PSMP service down; after-hours privileged session; dormant account use; Safe permission changes |
| DSOC | Triage runbooks per use case; PTA alert handling; escalation to the CyberArk team |
| **Acceptance** | Each use case fires in test and is triaged by DSOC (section 5.3) |

#### 3.6.11 Monitoring and control

- Health: PSM service and RDS services; PSMP services (`psmpsrv`, `sshd`, AD Bridge); PTA; HTML5 GW.
- Capacity: concurrent sessions per node; CPU/RAM; **PSM temporary recording disk**; Vault disk
  (recordings).
- LB integration: node drain on service failure (section 3.6.3).
- Certificate expiry alerts.
- **Acceptance:** alerts tested; dashboards in place.

#### 3.6.12 Session recordings: storage, retention, archive, retrieval, disposal

| Stage | Design |
|---|---|
| Storage | Recordings uploaded from PSM/PSMP to recording Safes in the Vault; PSM keeps a temporary copy until the upload succeeds |
| Sizing | Vault storage = sessions per day × average duration (h) × recording size per hour × retention days. Measure the size per hour in the pilot (video for RDP/web, text for SSH). DCE expands Vault storage to the result plus 30% headroom |
| Retention | Safe-level recording retention set to the Defence period (**TBD**, A11); a single setting per Safe class |
| Archive | If the retention outgrows Vault storage: periodic export to an approved archive store at the same classification, with an index (session ID, user, target, ticket, date) (design option; confirm in Phase 0) |
| Retrieval | Auditors and investigators: a dedicated *Auditor* role with recording access; every retrieval audited and visible in Splunk |
| Disposal | Automatic purge at the end of retention; disposal recorded per records management; legal hold procedure to suspend purge for investigations |
| Classification | Recordings are held at the classification of the environment |

#### 3.6.13 DevSecOps and automation

- **Ansible** for PSM and PSMP build and configuration where supported: CyberArk's published automation
  (for example the `cyberark.pas` collection and CyberArk's deployment playbooks; verify 14.6
  compatibility), plus local roles for OS prerequisites, hardening checks and configuration.
- SECRET: an offline Ansible execution environment and mirrored collections (A10).
- Bulk onboarding through the CyberArk REST API (playbooks or scripts) from validated inventories.
- AV/EDR exclusions and AppLocker policy for PSM and each client tool; vulnerability scanning; patch
  process that keeps PSM hardening intact.
- **Acceptance:** a node can be rebuilt from automation; scans clean or exceptions approved.

#### 3.6.14 Security, RBAC and bypass prevention (CyberArk team with Security)

| Control | Design |
|---|---|
| Authentication | PVWA with smart card (PKIPN, `docs/cyberark-pvwa-pkipn`); PSMP via AD + PVWA MFA caching |
| RBAC | Safes per team and per classification; roles: End user (*Use*, *List*; no *Retrieve*), Approver, Safe Manager, Auditor, CyberArk Admin, CND (separate); LDAP group mapping |
| Credential controls | CPM rotation on onboarding (no one keeps a known password); periodic change; reconcile on failure; one-time passwords for break-glass |
| Platform controls | *Connect through PSM* enforced; *Require ticket*; session recording on; exclusive access and dual control for high-risk and break-glass |
| Break-glass | Check-out/check-in for **all** break-glass accounts; rotation on check-in; ticket and approval; alert on every check-out; CyberArk's own emergency access (Vault-down procedure) documented and tested twice a year |
| Hardening | CyberArk PSM/PSMP hardening; SOE baseline; AppLocker; no interactive logons outside sessions |
| Bypass prevention | Network blocks (3.6.2); target GPOs and `sshd` restrictions (3.6.6); credentials unknown to users (rotation); detection in PTA and Splunk |
| Certificates | Section 3.6.7 |
| **Acceptance** | Security test cases (section 5.3); penetration test findings closed or accepted |

#### 3.6.14a Vault administration VM (CyberArk team, with DCE, Network, DevSecOps)

| Item | Requirement |
|---|---|
| Purpose | The only place the CyberArk team runs Vault administration: PrivateArk Client, PARClient (remote Vault service control), Vault/DR Vault health and backup tools, CyberArk installers and scripts. No one logs on to the Vault servers interactively |
| Count | **1 per classification** (decided). It administers both the **Vault and the DR Vault** of that classification. If it is unavailable, rebuild it from automation (WP11/WP28); Vault administration waits until then |
| Build | Windows Server 2022, hardened SOE, no internet, no email/browsing, AppLocker allow-list of admin tools only; EDR; patched monthly |
| Access | Only by named CyberArk administrators, **through PSM** (recorded) with a ticket, using vaulted credentials. No direct RDP from user networks |
| Network | To Vault and DR Vault on 1858 (Vault protocol) and the PARAgent remote-administration port (9022, verify 14.6); to PVWA 443; nothing else outbound except patching and logging |
| Logging | OS and tool logs to Cribl/Splunk; DSOC use case "Vault administration session" |
| Backup | Configuration backup; no Vault data stored on it |
| **Acceptance** | Vault administration works only from this VM; direct logon to Vault servers blocked and alerted |

#### 3.6.15 Consuming teams (and CND)

- Provide the **target and account inventory** (template supplied): systems, account types, owners,
  break-glass accounts, application local credentials, required clients/tools.
- Say which application credentials can be rotated natively (CPM plugin or API); the CyberArk team
  validates.
- Nominate account owners and UAT testers; join the onboarding wave; accept the change in working
  practice.

#### 3.6.16 Service Operations, Service Desk and Records management

- Support model (L1 Service Desk → L2 operations → L3 CyberArk team), incident categories, KB articles,
  user training, hypercare (4–6 weeks per wave).
- Records management: approve the recording retention/disposal procedure (3.6.12).

---

## 4. Costs

| Item | Detail | Quantity | Amount |
|---|---|---|---|
| Funding source | TBC (Q14) | — | TBC |
| Infrastructure | VMs (compute, storage, backup) at chargeback rates | up to 48 VMs | TBC |
| Vault storage expansion | Recordings (section 3.6.12) | per sizing | TBC |
| RDS CALs | **Per User** CALs, same or newer version than the PSM OS, installed on each classification's own RD Licensing server. Separate, isolated licence servers can't share a pack, so buy per environment (confirm with Microsoft licensing): PROTECTED 250 + 10% ≈ 275; SECRET 200 + 10% = 220; plus CND users (Q20); OFFICIAL 90 + 10% = 99 | **≈ 594** (+ CND) | TBC |
| Windows Server CALs | Users of PSM also need Windows Server CALs (often covered by an enterprise agreement) | as above | TBC |
| Windows Server licences | 18 PSM servers + 3 Vault admin VMs (core-based) | 21 | TBC |
| RHEL subscriptions | PSMP (18), PTA (3), HTML5 GW (6 if approved) | 21–27 | TBC |
| CyberArk licences | PSM, PSMP, PTA entitlement, users/targets per licence model | TBC (Q14) | TBC |
| Client tool licences on PSM | Database and management clients that are not free (e.g. commercial DB tools) | per tool (Q21) | TBC |
| Load balancer capacity | VIPs / licences / throughput | 12–15 VIPs | TBC |
| Splunk ingest | Additional GB/day from new sources (estimate from pilot) | TBC | TBC |
| Cribl capacity | Worker capacity, if needed | TBC | TBC |
| Ansible platform | Subscription or execution environment, if not already available | TBC | TBC |
| Third-party support | CyberArk Professional Services or partner (design review, PTA, ticketing), if engaged (Q14) | TBC | TBC |
| Penetration test | Independent test of new components | 3 environments | TBC |
| GFX | Meaning to confirm (Q13) | — | TBC |
| Contingency | Up to **4 extra PSM nodes** (+2 PROTECTED, +2 SECRET: VMs and Windows Server licences; VIPs unchanged) for R3; 15% for onboarding volume (R18) | — | TBC |

---

## 5. Impact assessment

### 5.1 Design

**Impact: High.** New tiers in the CyberArk architecture in three classifications. The decisions to close
in Phase 0: Windows Server version; HTML5 Gateway; ServiceNow rules and failure modes; recording
archive; load-balancer persistence and health-check design; capacity model; Safe/RBAC model; bypass
enforcement approach. Each closes with a decision record.

### 5.2 Drafting workstream

**Impact: Medium–High.** About 20 artefacts (section 3.2), several per classification. The heaviest are
the LLD, the firewall matrix, the platform and connection-component catalogues, and the SIEM use case
catalogue.

### 5.3 Testing

**Impact: High.** Test types and minimum coverage:

| Type | Coverage |
|---|---|
| Functional | **Every** connection component × target type × classification: RDP, SSH (PSMP and PSM-SSH), network devices, each database client, each web application connector, virtualisation and out-of-band consoles |
| Ticketing | Valid Incident; valid Change in window; Change outside window; wrong state; closed ticket; nonexistent ticket; wrong CI (if enforced); ServiceNow unavailable; slow response/timeout; emergency bypass (allowed, alerted); bypass by a non-emergency role (denied); PSMP ticket entry |
| Security | Bypass attempts (direct RDP/SSH/DB/web from user networks, jump hosts); *Retrieve* denied; native RDP to PSM denied; hardening scan; AppLocker breakout attempts from client tools; RBAC per role; CND isolation; penetration test |
| HA / failover | Node loss; service-down with port open (drain); site loss; LB failover; Vault → DR Vault failover with sessions; recording continuity |
| Performance | Ramp to peak concurrency (section 3.6.1) with N-1 nodes; session launch time; PSM temp disk and Vault upload throughput |
| Logging / SIEM | Each use case (3.6.10) fires and is triaged; data reaches Splunk within NFR5; PTA detections |
| Break-glass | Check-out → use → check-in → rotation; dual control; alert; Vault-down emergency procedure |
| CPM / onboarding | Verify, change, reconcile per platform; native application rotation per supported application |
| Recordings | Playback; retrieval audit; retention purge; legal hold |
| DR | Component rebuild from automation; restore of configuration |
| UAT | Each consuming team and CND on their real targets |

### 5.4 Deployment

**Impact: High.** Phased:

| Phase | Content | Exit criteria |
|---|---|---|
| 0. Discovery and design | Inventory, decisions, LLD, procurement, security engagement | Decisions signed; orders raised |
| 1. Foundations | VMs, SOE, network component flows, VIPs, AD, PKI, Ansible environment | Infrastructure accepted |
| 2. PROTECTED build and integration | PSM/PSMP/PTA/(HTML5) build; ServiceNow; SIEM; monitoring; performance and HA tests | SIT passed in PROTECTED |
| 3. SECRET and OFFICIAL build and integration | As Phase 2; SECRET with media transfer and offline automation | SIT passed in SECRET and OFFICIAL |
| 4. Onboarding waves | Pilot team, then teams in waves: platforms, Safes, accounts, break-glass, application credentials, target flows, UAT | Wave UAT passed; rotation success above threshold |
| 5. Enforcement | Bypass blocks and target GPOs per wave; jump host restriction | Bypass tests fail as intended; detections live |
| 6. Service transition | Runbooks, support model, training, hypercare | Service acceptance |

Typical sequence over 12 months: Phase 0 (months 1–2), Phase 1 (2–4), Phase 2 (4–6), Phase 3 (5–8),
Phase 4 (6–11, overlapping), Phase 5 (8–12, per wave), Phase 6 (from the first wave).

### 5.5 Production

**Impact: High.**
- About 250 users change how they access systems; productivity dip during early waves (R11).
- Privileged access now depends on PVWA, PSM/PSMP, Vault, ServiceNow and the network paths; each is
  a dependency for operational access, mitigated by HA, the defined ticketing failure mode and
  break-glass.
- Additional load on the Vault (recordings, audit) and Splunk (ingest).
- Removal of direct access and jump hosts after enforcement.

### 5.6 Service operations

**Impact: Medium–High.**
- New components to monitor, patch, back up and upgrade (up to 48 servers).
- **Upgrade and lifecycle:** CyberArk upgrade order (Vault → PVWA → CPM → PSM/PSMP → PTA, verify 14.6
  guidance); load-balanced pools upgraded **as a pool** (drain and upgrade all nodes in one change, or a
  parallel pool cut-over) because nodes in a pool must run the same version; monthly OS patching with a
  hardening re-check; browser and web-driver alignment for web connectors; client tool updates; RDS CAL
  and certificate renewals; next Windows Server uplift.
- Recording retrieval and disposal; legal hold.
- Break-glass reviews and twice-yearly tests.
- New incident categories; DSOC triage of new use cases.

### 5.7 Defects debt

| Item | Status |
|---|---|
| GPO places an internal sub-CA in Trusted Root on domain servers (found on PVWA). New PSM servers will inherit it | Open; fix at source (Identity/PKI) |
| PVWA HTTPS binding: client certificate revocation check found **disabled** | Open; re-enable (03 Step 1 in `docs/cyberark-pvwa-pkipn`) |
| PVWA certificate login relies on `ClientAuthTrustMode` = 2 as a workaround for the GPO issue | Open until the GPO is fixed |

### 5.8 Concessions debt

| Item | Status |
|---|---|
| PVWA PKIPN uses UPN (weak) mapping, not Microsoft strong certificate mapping | Decision pending (`docs/cyberark-pvwa-pkipn/11-certificate-login-options.md`) |
| Windows Server 2019 for PSM, if the 2022/2025 SOE isn't feasible in time | Conditional (section 2.1.2) |
| Applications whose local credentials can't be rotated natively | Per application, raised during onboarding (R12) |
| Recording retention period not yet confirmed by Defence | Design supports it; value TBD |

### 5.9 Document debt

- CyberArk HLD/LLD and security documentation to update for every new component.
- PVWA certificate login is now documented (`docs/cyberark-pvwa-pkipn`); the PKI lessons apply to the
  PSM build.
- Network diagrams, SOE standards and the access policy to update after enforcement.

---

## 6. Resource effort and work packages

Effort is in **person-days for all three classifications together** (OFFICIAL, PROTECTED, SECRET), indicative, for each team to confirm.
Onboarding scales with the inventory (unit rates below).

| WP | Work package | Owner | Supporting | Depends on | Phase | Effort (d) |
|---|---|---|---|---|---|---|
| WP01 | Discovery: target, account, user inventory; team and wave plan | CyberArk | Consuming teams, CND | — | 0 | 15–25 + 2–3 per team |
| WP02 | HLD/LLD and decision records | CyberArk | Security, Network | WP01 | 0 | 25–35 |
| WP03 | Security assessment, accreditation, pen test coordination | Security | CyberArk | WP02 | 0–3 | 28–50 |
| WP04 | Procurement: capacity, CALs, licences, RHEL, client tools | Procurement | CyberArk, DCE | WP02 | 0–1 | 6–12 |
| WP05 | VM provisioning (up to 48) and placement | DCE | — | WP04, WP06 | 1 | 30–50 |
| WP06 | Windows Server version gate and PSM SOE; RHEL SOE | Windows / Linux Platform | CyberArk | WP02 | 0–1 | 20–40 |
| WP07 | IP, DNS, component firewall flows | Network | CyberArk | WP02 | 1 | 14–21 |
| WP08 | Load balancing: VIPs, persistence, health checks, drain integration | Network | M&C, CyberArk | WP05 | 1–2 | 14–21 |
| WP09 | AD: OUs, GPOs, service accounts, delegations, RD Licensing | Identity | CyberArk | WP02 | 1 | 14–21 |
| WP10 | PKI certificates; GPO sub-CA fix | PKI | Identity | WP02 | 1 | 7–12 |
| WP11 | Ansible environment (all classifications, offline in SECRET) and playbooks | DevSecOps | CyberArk | WP06 | 1–2 | 20–32 |
| WP12 | PSM build and configuration, 18 nodes | CyberArk | DevSecOps | WP05–WP11 | 2–3 | 28–42 |
| WP13 | PSMP build and configuration, 18 nodes (AD Bridge, MFA caching, host keys, ticket prompt) | CyberArk | Identity | WP05–WP11 | 2–3 | 22–35 |
| WP14 | HTML5 Gateway (conditional), 6 nodes | CyberArk | Network, PKI | Decision in WP02 | 2–3 | 11–21 |
| WP15 | PTA deployment and integration, 3 nodes | CyberArk | Identity, SIEM | WP05 | 2–3 | 14–28 |
| WP16 | ServiceNow ticketing integration, three instances, incl. ServiceNow-side validation logic (2.1.5a) and PSMP ticket prompt | ServiceNow team | CyberArk, Security | WP02 | 2–3 | 25–40 (+ CyberArk 12–18) |
| WP17 | Hardening, AppLocker, EDR exclusions, scanning | DevSecOps | CyberArk | WP12 | 2–3 | 14–21 |
| WP18 | SIEM: Cribl, Splunk, dashboards | SIEM | CyberArk | WP12–WP15 | 2–3 | 28–50 |
| WP19 | DSOC use cases and runbooks | DSOC | SIEM, CyberArk | WP18 | 2–3 | 14–28 |
| WP20 | Monitoring and alerting | M&C | CyberArk | WP12–WP15 | 2 | 11–21 |
| WP21 | Connection components and client tools | CyberArk | DevSecOps | WP12 | 2–4 | 1–3 per component (est. 15–25 components → 25–50) |
| WP22 | Platforms, Safes, RBAC, CPM/reconcile policies | CyberArk | Identity, owners | WP02 | 2–4 | 1–2 per platform type (est. 20–30 → 30–50) + 10 for Safes/RBAC |
| WP23 | Account onboarding waves, incl. break-glass and native application credentials | CyberArk | Owners, Identity, Network | WP21, WP22 | 4 | **0.05–0.15 per account (bulk) + 0.5–1 per non-standard application**; total from WP01 inventory |
| WP24 | Target firewall flows per wave | Network | CyberArk | WP23 | 4 | 22–42 |
| WP25 | Enforcement: bypass blocks, target GPOs, `sshd` restrictions, jump host restriction | Network / Identity / Platform | CyberArk | WP23 | 5 | 28–50 |
| WP26 | Testing: SIT, security, HA/DR, performance, ticketing, logging, UAT | Test lead / CyberArk | All | WP12–WP20 | 2–5 | 70–110 |
| WP28 | Vault administration VM: build, hardening, admin tools, PSM access, firewall, logging (3 VMs) | CyberArk | DCE, Network, DevSecOps | WP05, WP12 | 2–3 | 6–10 |
| WP27 | Service transition, runbooks, training, hypercare; upgrade procedure; records procedure | Service Ops / CyberArk | Records | WP26 | 5–6 | 25–38 |
| — | Project management and coordination | PM | — | — | All | 0.5 FTE × 12 months |

**Onboarding example** (to replace with the WP01 inventory): 2,000 accounts × 0.1 d = 200 d, plus 20
non-standard applications × 0.75 d = 15 d, plus target owner verification of 1–2 d per team.

**Critical path:** WP01 → WP02 → WP06 (OS gate) → WP05 (VMs) → WP12/WP13 (build) → WP26 (testing in
PROTECTED) → SECRET and OFFICIAL builds → WP23 (onboarding waves) → WP25 (enforcement).

---

## 7. Attachments and references

**To be produced:** A. Firewall and flow matrix · B. Server inventory and sizing sheet · C. Capacity
model · D. ServiceNow integration specification · E. SIEM use case catalogue · F. Platform and
connection component catalogue · G. Test strategy · H. Onboarding inventory template · I. Decision
records.

**References:**
- CyberArk: [PSM system requirements](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20sysreq/system%20requirements%20-%20psm.htm)
- CyberArk: [Installing PSM in a load-balancing environment](https://docs.cyberark.com/pam-self-hosted-legacy/latest/en/content/pas%20inst/installing-psm-in-a-load-balancing-environment.htm)
- CyberArk: [ServiceNow ticketing integration](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/ticketingintegrationservicenow.htm)
- CyberArk: [PSM for SSH system requirements](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20sysreq/system%20requirements%20-%20psmp.htm); [Recommended server specifications](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20sysreq/recommended%20server%20specifications.htm); [PSM compatibility](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20sysreq/psm-compatibility.htm); [AWS](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20cloud/aws-system-requirements.htm) and [Azure](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20cloud/azure-system-requirements.htm) system requirements (session tiers, 60-session ceiling); [Version 14.6 what's new](https://docs.cyberark.com/pam-self-hosted/latest/en/content/release%20notes/rn-whatsnew14-6.htm); [Known issues](https://docs.cyberark.com/pam-self-hosted/latest/en/content/release%20notes/rn-knownissues-general.htm)
- CyberArk: [Integrate PSM for SSH with enterprise ticketing systems](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/psmp-configureticketing.htm); [Connect through PSM for SSH](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/psso-pmsp.htm); [Configure dual control with ticketing](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/configuring-dual-control-together-with-ticketing-integration.htm); [Version 10.6 what's new](https://docs.cyberark.com/pam-self-hosted/latest/en/content/release%20notes/rn-whatsnew10-6.htm) (requester match)
- CyberArk: [Install PSM HTML5 Gateway](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/install_psm_html5.htm); [Install multiple PSM servers](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pas%20inst/optional-installing-multiple-psm-servers.htm)
- Microsoft: [Windows Server 2019](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2019), [2022](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2022), [2025](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2025) lifecycle pages
- CyberArk: [Integrating with SIEM applications](https://docs.cyberark.com/pam-self-hosted/latest/en/content/pasimp/integrating-with-siem-applications.htm)
- Security Services PSD project kick-off notes, 9 November 2026 (internal; SIEM path CyberArk → Cribl → Splunk/DSOC)
- `docs/cyberark-pvwa-pkipn/` in this repository

---

## 8. Clarifications

### 8.1 Answered (20 November 2026)

| # | Answer |
|---|---|
| Q1/Q2 | 12 per classification, 24 total: 4 PSM + 4 PSMP for consumers, 2 PSM + 2 PSMP for **CND**. Production |
| Q3 | Design to 14.6; include upgrade/lifecycle; same version in each load-balanced pool |
| Q4 | All target types in scope; onboarding of all accounts, platforms, Safes, CPM/reconcile, connection components, AD changes; break-glass accounts; native application credential rotation where possible |
| Q5 | PVWA *Connect* (launches the native RDP client after the ticket check) and native PSMP SSH; direct connection-string RDP to PSM excluded unless N2/N3 proven (2.1.4); HTML5 Gateway assessed; full LB design |
| Q6 | Windows Server uplift from 2019 to be recommended (2022 if available today and feasible in 12 months) |
| Q7 | Include the RDS CAL model and quantities |
| Q8 | Full recording lifecycle; retention TBD pending Defence |
| Q11 | CyberArk → Cribl → Splunk → DSOC, with monitoring, dashboards, alerts, use cases |
| Q12 (part) | Ansible automation where supported |
| — | ITSM ticketing fully in scope (ServiceNow and/or SM9, Q30); PTA in scope; check-out/check-in for all break-glass; ~250 users, 2–4 sessions each; match specs to other environments |

### 8.2 Still open

| # | Question |
|---|---|
| Q9 | SECRET constraints: media transfer process, approved product list, lead times |
| Q12 | Change framework definition of "major" (for section 1.3) |
| Q13 | Meaning of "GFX" in the cost section |
| Q14 | Funding source; CyberArk licence entitlement (PSM, PSMP, PTA); third-party support |
| Q15 | Baseline documents to reference |
| Q19 | ~~Users per classification~~ Answered: 250 PROTECTED, 200 SECRET, 90 OFFICIAL |
| Q20 | CND: number of users; reached only from CND networks? |
| Q21 | Database and management client tools needed on PSM (and their licensing) |
| Q22 | Which existing environment's specs to match, and what they are |
| Q23 | ServiceNow in SECRET: separate instance? How does PVWA reach it? CMDB quality for CI matching |
| Q24 | PTA: single node per classification acceptable, or HA/DR required? |
| Q25 | Number of sites (data centres) per classification |
| Q26 | Existing jump hosts: keep, restrict or retire after enforcement? |
| Q27 | Number of consuming teams, and approximate account counts per team (drives WP23) |
| Q28 | Load balancer platform per classification (affects health-check and drain design) |
| Q29 | ~~OFFICIAL in scope?~~ Answered: **yes** (90 users) |
| Q30 | ~~ITSM~~ Answered: **ServiceNow in each classification** (I1) |
| Q31 | ~~Native RDP option~~ Answered: **N1** |
| Q32 | OFFICIAL: does CND need its own 2 + 2 pools there too (assumed yes)? Sites per classification for OFFICIAL? |
| Q34 | ~~Vault admin VM count~~ Answered: **1 per classification**, administers the Vault and DR Vault |
| Q33 | Partly answered: PSMP passes tickets to PVWA for validation; requester match supported. Still open: which ServiceNow fields/query conditions the 14.6 integration can check, and whether it can check the target CI |
