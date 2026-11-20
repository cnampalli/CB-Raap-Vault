# Impact Assessment — CyberArk Privileged Session Manager (PSM and PSM for SSH)

| | |
|---|---|
| **Document status** | DRAFT v0.1, for review |
| **Date** | 2026-11-20 |
| **Author** | CyberArk team (TBC) |
| **Classification scope** | PROTECTED and SECRET environments |
| **Change type** | Major technical change (see 1.2) |

> **How to read this draft.** Items marked **TBC (Qn)** wait for an answer to clarification question
> *n* (list in section 8). Items marked *Assumed* are working assumptions; correct them if wrong.
> Effort and cost figures are indicative until confirmed.

---

## 1. Overview

### 1.1 Summary

CyberArk Privileged Access Management (Vault, PVWA, CPM) is already in production in the PROTECTED
and SECRET environments. It stores and rotates privileged credentials, but users still connect to
target systems **directly** with the retrieved credential.

This change adds **CyberArk Privileged Session Manager**:

- **PSM** (Windows, RDP-based) for Windows targets and other RDP-launched clients.
- **PSM for SSH (PSMP)** (Linux) for SSH targets: Linux/Unix servers and network devices.

Privileged sessions then run **through** the PSM servers: users never see the target password, sessions
are isolated from the user's workstation, and every session is recorded and auditable.

### 1.2 Change type: Major technical change

| Criterion | Assessment |
|---|---|
| New infrastructure | Yes: 24 new servers across two classifications (section 2.1) |
| Changes how users work | Yes: privileged users of in-scope systems change how they reach their VMs and servers (through PVWA / PSM / PSMP instead of directly) |
| Network changes | Yes: new flows user → PSM/PSMP → targets; direct admin paths later restricted |
| Security / accreditation | Yes: new components in PROTECTED and SECRET; system security documentation must be updated |
| Multiple workstreams | Yes: Data Centre, Network, Identity, Monitoring & Control, DevSecOps, Security, Operations, consuming teams |
| Licensing / procurement | Yes: Microsoft RDS CALs; PSM licences TBC (Q14) |

**Classification: Major.** TBC against the organisation's change framework (Q12).

---

## 2. Scope

### 2.1 Description

Deploy and integrate PSM and PSMP in **each** of the PROTECTED and SECRET environments.

| Server group | PSM (Windows) | PSMP (Linux) | Purpose |
|---|---|---|---|
| Consumer (shared service for teams) | 4 | 4 | Sessions for consuming teams |
| CyberArk team (administration of CyberArk itself) | 2 | 2 | CyberArk team's own access to CyberArk components |
| **Per classification** | **6** | **6** | **12 servers** |
| **Total (PROTECTED + SECRET)** | **12** | **12** | **24 servers** |

*Assumed:* the CyberArk team servers are separate in each classification (TBC Q2), production only (no
non-production PSM; TBC Q1).

Included:
- Server provisioning (Data Centre Engineering) and build to the hardened standard.
- PSM / PSMP installation, hardening and registration with the existing Vault.
- Network and firewall changes for the new session paths.
- RDS licensing for the PSM servers.
- Session recording storage and retention.
- Integration with monitoring, SIEM, backup and patching.
- Connection components and platform configuration for in-scope target types (Q4).
- Testing with consuming teams; user guides; operational handover.

### 2.2 Assumptions

| # | Assumption | Confirm |
|---|---|---|
| A1 | Existing Vault, DR Vault, PVWA and CPM per classification are healthy and on CyberArk Self-Hosted 14.6 | Q3 |
| A2 | PSM/PSM for SSH licences are covered by the current CyberArk entitlement | Q14 |
| A3 | Windows Server and RHEL hardened standard builds exist and are approved in both classifications | Q6 |
| A4 | PSM servers are joined to the environment's AD domain | Q6 |
| A5 | Session recordings are stored in the Vault with a retention of **TBC** days | Q8 |
| A6 | SECRET has no internet access; installation media are brought in through the approved transfer process | Q9 |
| A7 | Data Centre Engineering provisions the VMs; the CyberArk team installs and configures CyberArk software | Q10 |
| A8 | Onboarding of target accounts is phased by team and is not all in this change | Q4 |
| A9 | Users connect with native RDP/SSH clients through PVWA "Connect" and PSMP; HTML5 gateway TBC | Q5 |

### 2.3 Risks

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Server provisioning or procurement delays (24 VMs, two classifications) | Medium | High | Raise the procurement / provisioning request early; build in waves |
| R2 | Firewall changes across many target networks take longer than planned | High | High | Consolidated firewall request per classification; target network inventory up front |
| R3 | RDS CAL shortfall or no RD Licensing server, so PSM sessions are refused after the grace period | Medium | High | Confirm licensing model and counts (Q7) before go-live |
| R4 | User resistance / productivity loss from the new access method | Medium | Medium | Early-adopter teams, guides, drop-in sessions, phased enforcement |
| R5 | Vault storage exhausted by recordings | Medium | High | Size from retention and session volume (Q8); monitor Vault disk |
| R6 | Hardened builds (AppLocker, GPOs, AV/EDR) block PSM components | Medium | Medium | PSM hardening and AV exclusions agreed with DevSecOps before build |
| R7 | Accreditation of new components in SECRET delays go-live | Medium | High | Engage Security & Accreditation at design stage |
| R8 | Break-glass access lost if PSM is unavailable | Low | High | Keep and document a controlled direct-access path; HA across 4 servers |
| R9 | Known PKI issues on PVWA (section 5, defects debt) recur on new servers | Medium | Medium | Apply the lessons in `docs/cyberark-pvwa-pkipn` to the PSM build |

### 2.4 Dependencies

| # | Dependency | Owner |
|---|---|---|
| D1 | 24 VMs provisioned to spec (section 3.5.1) | Data Centre Engineering |
| D2 | IP addressing, DNS records, load balancer VIPs (if used) | Network / Data Centre |
| D3 | Firewall rules (section 3.5.2) | Network / Firewall |
| D4 | AD: computer accounts, OUs, GPO exclusions, service accounts | Identity / AD |
| D5 | RDS CALs and RD Licensing server | Procurement / Microsoft licensing |
| D6 | CyberArk PSM / PSMP licences and installation media for 14.6 | Procurement / CyberArk team |
| D7 | Monitoring, SIEM, backup and patching onboarding | Monitoring & Control, DevSecOps, Operations |
| D8 | Security assessment and accreditation updates | Security & Accreditation |
| D9 | Test participants from each consuming team | Consuming teams |

### 2.5 Exclusions

- Onboarding of **all** privileged accounts and targets (phased separately, A8). TBC Q4.
- Changes to the Vault, PVWA or CPM architecture beyond what PSM needs.
- Non-production PSM environments (TBC Q1).
- PSM for web applications / databases via custom connection components, unless listed in Q4.
- Remote access from outside the classification networks.
- Replacement of existing jump hosts (to be planned after PSM is adopted).

---

## 3. Requirements

### 3.1 Key deliverables

| # | Deliverable |
|---|---|
| KD1 | 12 PSM + 12 PSMP servers built, hardened and registered to the Vault (6 + 6 per classification) |
| KD2 | Firewall and network changes implemented and verified |
| KD3 | RDS licensing in place |
| KD4 | Connection components and platforms configured for in-scope target types |
| KD5 | Session recording, retention and review working; auditors' access agreed |
| KD6 | Monitoring, SIEM, backup and patching integrated |
| KD7 | Test evidence: functional, failover, security and user acceptance |
| KD8 | Operational handover: runbooks, support model, user guides |

### 3.2 Other artifacts

- Low-level design (LLD) for PSM / PSMP per classification.
- Network flow / firewall matrix.
- Build and hardening guide (PSM, PSMP); as-built records.
- Test plan and test report.
- User guide (RDP through PSM; SSH through PSMP); FAQ.
- Runbooks: start/stop, patching, recording review, troubleshooting, break-glass.
- Updated system security documentation and risk register.

### 3.3 Baseline documentation

TBC (Q15). Expected: CyberArk HLD/LLD, current system security plan, CyberArk build guides, network
diagrams for both classifications, `docs/cyberark-pvwa-pkipn` (PVWA certificate login).

### 3.4 Specification impact

| Specification | Impact |
|---|---|
| CyberArk HLD / LLD | Add PSM and PSMP tiers, session flows, recording storage |
| Server build standards | New PSM role (RDS Session Host + PSM hardening) and PSMP role (SSH proxy) |
| Network architecture | New management zone flows; future restriction of direct admin access |
| Access policy / standards | Privileged sessions must go through PSM / PSMP for in-scope systems |
| Security documentation | New components, data (recordings), controls |

### 3.5 Requirements by workstream

#### 3.5.1 Data Centre Engineering

- Provision **24 VMs** (12 per classification), placement across hosts/clusters for availability.
- *Indicative* sizing, to confirm against CyberArk 14.6 requirements and expected concurrency:

  | Role | vCPU | RAM | Disk | OS |
  |---|---|---|---|---|
  | PSM (Windows) | 8 | 16–32 GB | 100 GB OS + 100 GB temporary recordings | Windows Server TBC (Q6) |
  | PSMP (Linux) | 4 | 8 GB | 80 GB | RHEL TBC (Q6) |

- Backup and snapshot policy (configuration only; recordings live in the Vault).
- Procurement / capacity request for the 24 VMs, including the **2 PSM + 2 PSMP per classification
  for the CyberArk team**.

#### 3.5.2 Network and firewall

Typical flows (to confirm with the CyberArk 14.6 port list):

| From | To | Port | Purpose |
|---|---|---|---|
| User workstations | PSM | TCP 3389 (or 443 with the HTML5 gateway) | Start a PSM session |
| User workstations | PSMP | TCP 22 | Start an SSH session |
| User workstations | PVWA | TCP 443 | Request / launch connections |
| PSM, PSMP | Vault (and DR Vault) | TCP 1858 | Credentials, recordings, configuration |
| PSM | Windows targets | TCP 3389 (and others per connection component) | Session to target |
| PSMP | Linux / network targets | TCP 22 | Session to target |
| PSM | Domain controllers | DNS, Kerberos, LDAP(S) | Domain membership |
| Monitoring / SIEM | PSM, PSMP | per tool | Health, logs |

- Load balancer VIPs for PSM / PSMP, if used (Q5).
- Later phase: restrict direct RDP/SSH from user networks to targets, so PSM can't be bypassed.

#### 3.5.3 Identity / Active Directory

- OU and computer accounts for the PSM servers; GPO exclusions where domain policy conflicts with
  PSM hardening.
- PSMP integration with AD for user logon (PSMP AD Bridge), if required (Q6).
- RD Licensing configuration (GPO or local).

#### 3.5.4 Monitoring and control

- Health monitoring of PSM / PSMP services and the RDS role (tool TBC, Q11).
- Forward PSM / PSMP and Vault session events to the SIEM; alerting for failed and suspicious sessions.
- Capacity monitoring: concurrent sessions, PSM temporary disk, Vault storage for recordings.

#### 3.5.5 DevSecOps

- Hardened images and build automation (if used, Q12).
- AV / EDR exclusions and AppLocker policy for PSM; vulnerability scanning of the new servers.
- Patching process that keeps PSM hardening and versions supported.

#### 3.5.6 Security and accreditation

- Update system security documentation and risk register for both classifications.
- Recording retention, access to recordings, and privacy notice to users.
- Security testing of the new components.

#### 3.5.7 CyberArk team

- Install, harden and register PSM / PSMP; connection components; platforms; recording settings.
- PSM / PSMP for the CyberArk team's own administration (2 + 2 per classification).
- Lessons from the PVWA certificate-login work: correct certificate stores, WinHTTP proxy for CRLs,
  no non-root certificates in Trusted Root (`docs/cyberark-pvwa-pkipn`).

#### 3.5.8 Service operations / service desk

- Support model, incident categories, knowledge articles, escalation to the CyberArk team.

#### 3.5.9 Consuming teams

- Nominate test users; take part in UAT; provide target inventories for onboarding.

#### 3.5.10 Procurement

- RDS CALs (Q7); CyberArk licences if not already held (Q14); any third-party services (Q14).

---

## 4. Costs

| Item | Detail | Amount |
|---|---|---|
| Funding source | TBC (Q14) | TBC |
| Infrastructure | 24 VMs (compute, storage, backup), chargeback rate TBC | TBC |
| Licences: Microsoft | Windows Server; RDS CALs (count TBC, Q7) | TBC |
| Licences: CyberArk | PSM / PSMP entitlement TBC (Q14) | TBC |
| Licences: Linux | RHEL subscriptions for 12 PSMP servers | TBC |
| Third-party support | CyberArk Professional Services / partner, if engaged (Q14) | TBC |
| GFX | TBC: meaning to confirm (Q13) | TBC |
| Additional funds | Vault storage expansion for recordings (Q8); contingency | TBC |

---

## 5. Impact assessment

| Area | Impact | Rating |
|---|---|---|
| **Design** | New PSM / PSMP tiers in the CyberArk architecture; HA and load-balancing design; recording storage design; network flow design per classification | High |
| **Drafting workstream** | LLD, firewall matrix, build guides, runbooks, user guides, security documentation (section 3.2) | Medium |
| **Testing** | Functional (each connection type), HA / failover, performance (concurrent sessions), security (bypass, hardening), UAT with each consuming team, recording playback | High |
| **Deployment** | 24 servers across two classifications; SECRET media transfer; phased onboarding of teams; firewall changes in both environments | High |
| **Production** | Privileged users change access method; sessions depend on PSM availability (HA mitigates); added load on the Vault (recordings) | High |
| **Service operations** | New components to monitor, patch and support; recording review process; new incident categories; break-glass procedure | Medium |
| **Defects debt** | Known items to record (TBC Q16): GPO places an internal sub-CA in Trusted Root on CyberArk servers; PVWA binding revocation check found disabled; PVWA certificate login depends on `ClientAuthTrustMode` = 2 as a workaround | Medium |
| **Concessions debt** | TBC (Q16). Candidate: PVWA PKIPN uses UPN (weak) mapping, not strong certificate mapping, pending decision (`docs/cyberark-pvwa-pkipn/11-certificate-login-options.md`) | TBC |
| **Document debt** | CyberArk HLD/LLD and security documentation to update; PVWA certificate login now documented in this repository | Medium |

---

## 6. Resource effort impact

*Indicative person-days for both classifications together. To validate with each team (Q17).*

| Workstream | Activities | Indicative effort (days) |
|---|---|---|
| CyberArk team | Design, install, configure, test, handover | 40–60 |
| Data Centre Engineering | Provision and build 24 VMs | 15–25 |
| Network / Firewall | Flow design, rules in both classifications, verification | 10–20 |
| Identity / AD | OUs, GPOs, service accounts, RD Licensing | 5–10 |
| Monitoring & Control | Monitoring and SIEM onboarding, alerts | 5–10 |
| DevSecOps | Images, exclusions, scanning, patching | 5–10 |
| Security & Accreditation | Assessment and documentation | 10–15 |
| Service Operations | Runbooks, knowledge articles, support readiness | 5–8 |
| Consuming teams | UAT (per team) | 1–2 per team |
| Procurement | Licences, capacity requests | 2–5 |

---

## 7. Attachments

- A. Network flow / firewall matrix (to be produced)
- B. Server inventory and sizing (to be produced)
- C. Test plan (to be produced)
- D. `docs/cyberark-pvwa-pkipn/` (PVWA certificate login guide, in this repository)

## 8. Clarifications

Record answers here as they arrive.

| # | Question | Answer |
|---|---|---|
| Q1 | Counts: 4 PSM + 4 PSMP (consumers) + 2 + 2 (CyberArk team) = 12 per classification, 24 total? Production only? | |
| Q2 | CyberArk team servers per classification, or shared? | |
| Q3 | Existing CyberArk version and components per classification | |
| Q4 | Target types, approximate target and user counts, onboarding in scope or phased | |
| Q5 | HTML5 gateway? Native clients vs PVWA Connect? Load balancers for PSM / PSMP? | |
| Q6 | Windows Server / RHEL versions; hardened builds; domain join; PSMP AD integration | |
| Q7 | RDS licensing: existing licence server, per-user or per-device, concurrent users | |
| Q8 | Recording retention and storage location | |
| Q9 | SECRET constraints (air gap, media transfer, approved products) | |
| Q10 | Workstream list confirmation | |
| Q11 | Monitoring tool and SIEM | |
| Q12 | Build automation; change framework definition of "major" | |
| Q13 | Meaning of "GFX" in the cost section | |
| Q14 | Funding source; licences owned; third-party support | |
| Q15 | Baseline documents to reference | |
| Q16 | Known defects / concessions to record as debt | |
| Q17 | Effort estimates: keep indicative ranges or leave blank? | |
| Q18 | Output format (Word / shared doc / Markdown) and naming (generic vs real) | |
