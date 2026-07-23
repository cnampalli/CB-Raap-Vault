# Changelog

Human-readable record of work on the zero-trust Vault integration for CloudBees CI,
CloudBees CD/RO, and Ansible Automation Platform (AAP). Newest first.

> This file is a durable, version-controlled trail. It is **not** auto-loaded into an AI
> session — to have the next session pick it up, point it here ("read `docs/CHANGELOG.md`").

---

## 2026-07-14

Added the **module-uplift runbook** that makes CDRO's static-key JWT auth expressible in Prescient
Solutions' `vault-enterprise-terraform` (v2.0) repo. That repo's reusable `vault-auth-jwt` module only
supported OIDC/JWKS **discovery**, so a discovery-less issuer like the CDRO **ZeroTrust** plugin
(`iss=ZeroTrust`, locally-signed) could not be configured — and `configs/towers/cnd.yaml` even pointed
the `cdro` provider at a non-existent `/.well-known/openid-configuration`.

### Added
- **New reference guide** `docs/vault-integrations/06-static-key-jwt-module-uplift.md`: root-cause table,
  a **backward-compatible** rewrite of the `vault-auth-jwt` module (adds `jwt_validation_pubkeys` /
  `jwks_url` / `jwks_ca_pem` / `jwt_supported_algs` to the backend behind a one-trust-root `precondition`,
  and `role_type` / `bound_subject` / `bound_claims_type` / `token_max_ttl` to the role), the `try(...)`
  pass-throughs for both callers (`tower-namespaces` + `root-namespace`), the schema `anyOf` trust-root
  change, the `validate-yaml.py` one-of-trust-roots change, and the corrected static-key `cnd.yaml`
  `jwt.cdro` block. Includes static-check / plan / apply / end-to-end-login / rollback / rotation steps.
- Linked from `00-architecture-overview.md` §9 guide index.

### Changed / Decisions
- **Static-key JWT is now a first-class, schema-validated config** alongside OIDC/JWKS. The existing OIDC
  providers (Jenkins CI, GitLab) are unaffected — they still supply `oidc_discovery_url`.
- Confirmed **no Vault provider bump** needed: `hashicorp/vault 3.23.0` already supports all the new
  attributes.

### Open follow-ups
- Confirm the CDRO token's exact `aud` + `alg`/PEM from a real decoded token (still placeholders:
  `aud=https://vault.prescient-solutions.internal:8200` per Prescient convention, `RS256`).
- Flag the unrelated pre-existing `tests/validate-yaml.py` namespace-regex bug (`re.match(r'^[a-z0-9-]+, namespace)`
  is missing its closing `$'`) to the CND team.

---

## 2026-07-09 — CD/RO visual user guides (infographics)

Added an **infographic-first, multi-skill-level** end-user guide series for the CD/RO use cases:
configuring the ZeroTrust plugin and running one release across **every** CD/RO ⇄ Vault use case
(Pattern A in-CD/RO read, Pattern B hand-off to AAP for dynamic secrets + signed SSH, key rotation,
CI-broker fallback). Built on the existing reference/beginner content — no technical decisions changed.

### Added
- **New series** `docs/cdro-user-guides/`:
  - `README.md` — landing page with a **three-track model** (👀 Explorer / 🔧 Operator / ⚙️ Engineer),
    the big-picture infographic, prerequisites, and an index.
  - `01-configure-zerotrust-plugin.md` — the signing/validation "crux," the plugin config fields, token
    capture, and the Vault mount/role/policy, with per-track callouts.
  - `02-release-all-use-cases.md` — one release wired across all use cases: Pattern A (three tiers),
    Pattern B (AAP hand-off), zero-downtime key rotation, fallback, end-to-end verification, and a
    symptom→cause→fix troubleshooting map.
- **Eight self-contained SVG infographics** under `docs/cdro-user-guides/assets/` (theme-safe, no
  external assets, rendered/inspected for layout): `big-picture`, `skill-tracks`, `signing-validation`,
  `plugin-config`, `release-pipeline`, `pattern-a-b`, `key-rotation`, `troubleshooting`.
- **Discoverability cross-links** from `getting-started/03-cloudbees-cdro.md` and
  `vault-integrations/03-cdro-zerotrust-jwt.md` into the new visual series.

### Notes
- Content only — reuses the confirmed environment/versions and the already-documented plugin behavior;
  the same open items apply (confirm real `aud`/algorithm/PEM from a captured token; automate rotation).

---

## 2026-07-09

Documented the **CloudBees CD/RO → Vault** integration via the custom, CloudBees-built **ZeroTrust**
JWT plugin (`v1.0`), and reconciled it against the former CI-broker docs. CD/RO now proves its **own**
identity to Vault (direct JWT); the CI broker is retained only as a fallback.

### Added
- **How the ZeroTrust plugin works** (primary deliverable) — new reference guide
  `docs/vault-integrations/03-cdro-zerotrust-jwt.md` (**renamed** from `03-cdro-ci-broker.md`): plugin
  behavior from KNOWN FACTS, the `jwt-cdro` mount (static `jwt_validation_pubkeys` + `bound_issuer=ZeroTrust`,
  **no discovery**), release-scoped `cdro-zerotrust` role + KV-v2-read-only templated policy for
  `cdr/<release>/*` (bash + Terraform 1.13.1 + self-service YAML), **Pattern A** (in-CDRO read:
  `UpdateCdroCredentialThroughJwtRequest` / `getCdroCredentialAndRunStep` / `getAuthorizedTokenAndRunStep`)
  and **Pattern B** (mint-and-hand-off via `IssueJwtAndStoreInProperty` → AAP for dynamic secrets), a
  manual key-rotation runbook, and a Limitations / Risks / Non-functional section.
- **Beginner guide rewritten** — `docs/getting-started/03-cloudbees-cdro.md` now leads with the direct-JWT
  flow: plugin configuration (Step 1), token capture + `inspect_jwt_claims.py` decode (Step 2), Vault mount
  (Step 3), role + policy (Step 4), **three code tiers** (curl / native plugin / vault CLI), Pattern B
  hand-off (Step 6), key-rotation runbook (Step 7), CI-broker **fallback** (Step 8). Concurrency-clobber and
  `debugLevel` cautions added as callouts.
- **Tiered example templates** under `docs/vault-integrations/examples/`: `cdro-zerotrust-curl.sh` (Tier 1),
  `cdro-zerotrust-native.dsl` (Tier 2, plugin-native, no shell binaries), `cdro-zerotrust-cli.sh` (Tier 3).
  Each: assumptions header, private-CA `--cacert`, `set +x`, JWT via stdin, self-revoke.
- **Vault foundation** (`01-vault-foundation-AUT.md`, getting-started `01`): new `jwt-cdro` auth method,
  `cdro-zerotrust-ro.hcl` templated policy, plus YAML + Terraform blocks and a Step 4b enable step.
- **Signing key-pair runbook** — new `docs/getting-started/03a-zerotrust-key-generation.md`: airgap-safe
  **`openssl`** commands (RSA/RS256 default; EC/ES; Ed25519/EdDSA), an algorithm↔key-type table, verify
  steps, and where each half goes (private → CD/RO Credential, public → Vault `jwt_validation_pubkeys`).
  Linked from guide `03` (Steps 1/3/7), the reference guide (§2/§7), the §2.1 matrix, and the README.
  Added `*.pem`/`*.key` to `.gitignore` so generated keys can't be committed.
- **Matrix/table rows**: `00-before-you-begin.md` §2.1 CD/RO ZeroTrust tier table + §3 direct-login flow #3;
  `getting-started/05` + `vault-integrations/05` troubleshooting + TTL rows (signature/issuer/audience
  mismatch, concurrency clobber, debug-leak; ZeroTrust JWT + token + signing-key TTLs).

### Changed / Decisions
- **CD/RO → own ZeroTrust JWT is now primary; CI broker is fallback.** Supersedes the prior "CD/RO has no
  OIDC issuer" premise for KV reads. Vault audit now attributes CD/RO reads to **CD/RO's own identity**
  (`user_claim=sub`), not a CI broker. Updated the `00-architecture-overview.md` §2 trust-roots row, §3
  topology, §4 firewall matrix (added direct login; marked broker flows fallback; **no Vault→CD/RO
  discovery flow**), §5 TTLs, §6 mount tree, **§8 decision record**, §9 index, §10 follow-ups.
- **Secret-path convention `cdro/<app>` → `cdr/<release>`** reconciled repo-wide (mount trees, path
  conventions, `cdro-broker.hcl` glob `secret/data/cdr/*`, example values).
- **Tooling:** reuse `inspect_jwt_claims.py` to decode a captured token; `check_oidc_discovery.py` is
  **not** used for CD/RO (no JWKS/discovery endpoint). No new Python helper added.

### Research (source-verified)
- Built on the operators' **KNOWN FACTS** for the ZeroTrust plugin (authoritative). Local signing with a
  Credential-held key, `Issuer=ZeroTrust`, asymmetric algorithm, static-pubkey validation in Vault, KV-v2
  reads scoped by `job_name`/release, two documented usage patterns, and the concurrency-clobber limitation.

### Open follow-ups
- **Confirm `aud` + algorithm/PEM from a real token** — no sample token was available this session, so the
  docs use labeled placeholders (`aud=vault-AUT`, `Algorithm=RS256`). Decode a captured token to set the
  role's `bound_audiences` and the `jwt_validation_pubkeys` PEM exactly (guide `03` §1–§2).
- **Automate ZeroTrust key rotation** — currently a manual, coordinated step (guide `03` §7).
- **Enforce credential-per-release** in CD/RO to avoid the concurrency clobber.
- **Propose (pending go-ahead):** update `workflows/build_vault_integration_guides.md` to reflect the direct
  ZeroTrust JWT path and its plugin quirks (no JWKS, manual rotation, clobber, debug-leak).

---

## 2026-07-07

Built the beginner + reference documentation set, the WAT tool/workflow layers, and worked
through a series of fixes surfaced while the customer ran the pipelines.

### Added
- **WAT scaffolding**: `workflows/`, `tools/`, `.tmp/` with READMEs; `.env.example`; `.gitignore`.
- **Beginner series** `docs/getting-started/`:
  - `README.md`, `00-before-you-begin.md` (concepts, prerequisites, **Requirements & Compatibility
    matrix §2.1**, firewall flows, glossary),
  - `01-vault-setup.md` (AUT foundation incl. hardened AppRole),
  - `02-cloudbees-ci.md` (three pipeline methods with Requirements boxes; **JWT claim inspection**;
    **project-scoped secrets §6.5**; **CloudBees CI Folders explainer**; `inspect_jwt_claims.py`
    in-pipeline usage),
  - `03-cloudbees-cdro.md` (CI broker), `04-aap-approle-ssh.md` (hardened AppRole + signed SSH),
    `05-verify-and-troubleshoot.md`.
- **Reference series** edits across `docs/vault-integrations/` (00–05) to match the above.
- **Tools** (`tools/`): `inspect_jwt_claims.py` (decode OIDC ID token → claims) and
  `check_oidc_discovery.py` (validate firewall flow #1). Standard-library only, **Python 3.6+**.
- **Workflow SOP**: `workflows/build_vault_integration_guides.md`.
- **Project-scoped secrets feature**: emit `group_name`/`job_name` claims → Vault role
  `claim_mappings` → templated policy `ci-project-ro` on
  `secret/data/project/<group_name>/<job_name>/*`.

### Changed / Decisions
- **AAP corrected to 2.4** (automation controller `4.5.25`; 2.5 ships controller 4.6.x).
- **AAP auth = hardened AppRole** (changed from mTLS cert-auth) — avoids the unsolved AD CS
  enrollment/renewal automation; cert-auth kept as a documented alternative; native OIDC is the
  2.7 end-state. Hardening: `secret_id_num_uses=1`, `secret_id_ttl=10m`, response-wrapped
  `secret_id` delivery, `secret_id_bound_cidrs`/`token_bound_cidrs` pinned to AAP hosts.
- **Confirmed versions**: CloudBees CI `2.528.3.35200-rolling`; OIDC Provider plugin
  `111.v29fd614b_3617`; CD/RO `2024.x`; Vault Enterprise `1.20.8+ent`; namespace `AUT`.
- **Example Jenkinsfiles made plugin-free**: `cleanWs()` → `deleteDir()` (core step);
  `timestamps()` removed. **Timestamper** and **Workspace Cleanup (`ws-cleanup`)** documented as
  *optional* plugins (`docs/getting-started/00-before-you-begin.md` §2.1).

### Fixed (bugs)
- **`withCredentials` binding**: `oidcIdToken(...)` → `string(...)` across all examples/docs
  (13 sites). The OIDC Provider plugin's ID token is a `StringCredentials`; there is **no**
  `oidcIdToken` step.
- **JCasC symbol**: `idTokenCredential` → **`idToken`** (both CI docs).
- **`Jenkinsfile.vault-oidc-nocli` DEBUG stage**: `Math.ceil(BigDecimal)` was rejected by the
  Jenkins script-security sandbox → now uses the file's Math-free `b64urlDecode` helper (no
  script approval).
- **SECURITY-3574 guidance corrected**: plugin `111.v29fd614b_3617` **is** the fix
  (CVE-2025-47884); no security upgrade needed. `212.v7657c4d7b_29f` is optional maintenance.
- **Python tools 3.6.8 compatibility**: `inspect_jwt_claims.py` `-> tuple[dict,dict]` (PEP 585,
  3.9+) → `typing.Tuple`; `check_oidc_discovery.py` `str | None` (PEP 604, 3.10+) → `typing.Optional`.
- **Claim-template Build-vs-Global trap documented**: a build-minted token uses `claimTemplates`
  + `buildClaimTemplates` and **ignores `globalClaimTemplates`** — so custom claims (e.g.
  `group_name`) must go in **Build claim templates**. Root cause of a "missing claim" report.

### Research (source-verified)
- **AAP 2.4 ↔ automation controller 4.5.25** (Red Hat release notes; 2.5 = controller 4.6.x).
- **SECURITY-3574 = CVE-2025-47884**, fixed in `111.v29fd614b_3617` (affected `96.vee8ed882ec4d`
  and earlier).
- **Vault AppRole hardening** parameters + response-wrapped `secret_id` (`-wrap-ttl`) flow
  (HashiCorp docs, Vault 1.20).
- **AAP Vault credential-plugin AppRole fields** (AWX `hashivault.py`): `role_id`/`secret_id`,
  Path to Auth `approle`, Namespace, API Version `v2`; Signed SSH uses "Path to Secret" as the
  sign path.
- **OIDC Provider plugin** (tag `111.v29fd614b_3617`): pipeline binding `string(...)`/`file(...)`;
  JCasC symbol `idToken`/`idTokenFile`; custom claims are global under `security: idToken:` via
  `claimTemplates` (always) / `buildClaimTemplates` (in a build) / `globalClaimTemplates` (outside
  a build); default in-build claims `iss, aud, iat, exp, sub(=${JOB_URL}), build_number`.

### Open follow-ups
- Vault **self-service YAML schema** to be shared → reshape guide 01 YAML.
- Confirm **mandated TTL / rotation SLA** (guides ship overridable zero-trust defaults).
- Decide **AAP `secret_id` rotation** mechanism (wrapped one-shot per run vs. CIDR-locked stored
  `secret_id` rotated on SLA).
- Finalize **CDRO→CI trigger-token** scope/storage.
- **AAP 2.7 upgrade** → cut over to native OIDC (drops AppRole).
