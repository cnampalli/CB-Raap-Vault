# 04 — CloudBees CI Pipeline: Build → Scan → Push → Sign → Verify

> **Prereqs:** `01`, `02`, `03` complete. Job lives under a folder matching the Vault role's
> `bound_claims` (e.g. `AUT/platform/container-signing/`) and runs on the `container-signer` label.
>
> **Ownership:** **CI engineering** owns the shared library; **application teams** consume it.

---

## 1. Stage order is a security control

```
build → scan → (gate) → push → sign → verify → promote
```

Two ordering rules are non-negotiable:

1. **Scan gates signing.** twistcli must exit non-zero on threshold breach and fail the build *before*
   any signing occurs. A signature is an assertion that the image passed our controls — signing a
   vulnerable image makes the signature a lie.
2. **Push precedes signing.** cosign signs a digest that must already exist in the registry. The signature
   is stored as a separate OCI artifact alongside it.

> **Why not sign locally then push?** cosign's signature references the image by digest in a specific
> repository. Signing before push means signing something the registry has not yet accepted (it may
> transform or reject it). Push, capture the returned digest, sign that.

---

## 2. Job configuration

- **Agent label:** `container-signer`
- **Folder:** matches `bound_claims` in `03 §4`
- **`Job/Configure`:** restricted — a user who can edit this job can change what gets signed
- **Console log retention:** per policy; assume readable by a wide audience, hence the masking discipline in §7

---

## 3. The Jenkinsfile

```groovy
pipeline {
  agent { label 'container-signer' }

  options {
    timeout(time: 45, unit: 'MINUTES')
    disableConcurrentBuilds(abortPrevious: false)   // see §5 before removing this
    timestamps()
  }

  parameters {
    string(name: 'IMAGE_NAME',  defaultValue: 'payments-api',       description: 'Image repository name')
    string(name: 'IMAGE_TAG',   defaultValue: '',                    description: 'Tag; defaults to build number')
    string(name: 'HARBOR_HOST', defaultValue: 'harbor.corp.example.com', description: 'Harbor registry host')
    string(name: 'HARBOR_PROJ', defaultValue: 'container-build',     description: 'Harbor BUILD project (unenforced — see 05)')
    booleanParam(name: 'SKIP_SIGN', defaultValue: false,             description: 'Emergency break-glass: build without signing (requires approval)')
  }

  environment {
    VAULT_ADDR      = "${env.VAULT_ADDR ?: 'https://vault.corp.example.com:8200'}"
    VAULT_NAMESPACE = 'AUT'
    VAULT_JWT_MOUNT = 'jwt-ci-ctrlA'
    VAULT_JWT_ROLE  = 'container-signing'

    // Two ID tokens, two audiences — see 03 §5
    CI_OIDC_TOKEN     = credentials('vault-oidc')     // audience: vault-AUT
    VENAFI_OIDC_TOKEN = credentials('venafi-oidc')    // audience: venafi-codesign

    // Venafi client
    PKCS11_MODULE  = '/usr/local/lib/venafipkcs11.so'
    VENAFI_OBJECT  = 'container-prod'
    LIBHSMINSTANCE = "ci-${env.BUILD_TAG}"            // per-build grant isolation — see 02 §6

    // Isolate HOME and registry auth per build — see §6
    HOME               = "${env.WORKSPACE}/.agenthome"
    DOCKER_CONFIG      = "${env.WORKSPACE}/.docker"
    REGISTRY_AUTH_FILE = "${env.WORKSPACE}/.docker/config.json"

    TAG = "${params.IMAGE_TAG ?: env.BUILD_NUMBER}"
    IMAGE_REF = "${params.HARBOR_HOST}/${params.HARBOR_PROJ}/${params.IMAGE_NAME}:${TAG}"
  }

  stages {

    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Preflight') {
      steps {
        sh '''
          set -euo pipefail
          mkdir -p "${HOME}" "${DOCKER_CONFIG}"

          : "${VAULT_ADDR:?VAULT_ADDR must be set}"
          : "${CI_OIDC_TOKEN:?vault-oidc credential binding is empty}"

          # Fail fast with actionable errors rather than deep in the signing stage
          command -v podman  >/dev/null || { echo "podman missing on agent"; exit 1; }
          command -v twistcli>/dev/null || { echo "twistcli missing on agent"; exit 1; }
          command -v cosign  >/dev/null || { echo "cosign missing on agent"; exit 1; }

          # The single most common misconfiguration: wrong cosign build (see 02 §3)
          cosign pkcs11-tool --help >/dev/null 2>&1 || {
            echo "ERROR: cosign lacks PKCS#11 support."
            echo "       Install the 'pivkey-pkcs11key' release asset. See docs/container-signing/02 §3."
            exit 1
          }

          pkcs11config health
        '''
      }
    }

    stage('Fetch secrets') {
      steps {
        sh '''
          set -euo pipefail
          set +x                       # secrets below — never trace

          VAULT_TOKEN="$(vault write -field=token \
              "auth/${VAULT_JWT_MOUNT}/login" \
              role="${VAULT_JWT_ROLE}" \
              jwt="${CI_OIDC_TOKEN}")"
          export VAULT_TOKEN

          HARBOR_USER="$(vault kv get -field=username secret/ci/container-signing/harbor-robot)"
          HARBOR_TOKEN="$(vault kv get -field=token    secret/ci/container-signing/harbor-robot)"
          PRISMA_USER="$(vault kv get -field=username  secret/ci/container-signing/prisma)"
          PRISMA_PASS="$(vault kv get -field=password  secret/ci/container-signing/prisma)"

          # Single auth file consumed by BOTH podman and cosign — see §6
          install -m 0700 -d "${DOCKER_CONFIG}"
          podman login "${HARBOR_HOST}" \
              --username "${HARBOR_USER}" \
              --password-stdin \
              --authfile "${REGISTRY_AUTH_FILE}" <<< "${HARBOR_TOKEN}"

          # Stash Prisma creds for the scan stage, mode 0600, removed in post{}
          umask 077
          printf '%s\\n%s\\n' "${PRISMA_USER}" "${PRISMA_PASS}" > "${WORKSPACE}/.prisma.creds"
        '''
      }
    }

    stage('Build') {
      steps {
        sh '''
          set -euo pipefail
          podman build --authfile "${REGISTRY_AUTH_FILE}" -t "${IMAGE_REF}" .
        '''
      }
    }

    stage('Scan (Prisma / twistcli)') {
      steps {
        sh '''
          set -euo pipefail
          set +x
          PRISMA_USER="$(sed -n 1p "${WORKSPACE}/.prisma.creds")"
          PRISMA_PASS="$(sed -n 2p "${WORKSPACE}/.prisma.creds")"

          # Non-zero exit on threshold breach fails the build BEFORE signing.
          twistcli images scan \
              --address "https://prisma-console.corp.example.com" \
              --user "${PRISMA_USER}" \
              --password "${PRISMA_PASS}" \
              --details \
              --vulnerability-threshold critical \
              --compliance-threshold high \
              --output-file "${WORKSPACE}/scan-result.json" \
              "${IMAGE_REF}"
        '''
      }
      post {
        always { archiveArtifacts artifacts: 'scan-result.json', allowEmptyArchive: true }
      }
    }

    stage('Push') {
      steps {
        sh '''
          set -euo pipefail
          # --digestfile gives the authoritative digest; do not parse stdout
          podman push \
              --authfile "${REGISTRY_AUTH_FILE}" \
              --digestfile "${WORKSPACE}/image.digest" \
              "${IMAGE_REF}"

          echo "Pushed digest: $(cat "${WORKSPACE}/image.digest")"
        '''
      }
    }

    stage('Sign (Venafi CodeSign Protect)') {
      when { expression { !params.SKIP_SIGN } }
      steps {
        sh '''
          set -euo pipefail

          DIGEST="$(cat "${WORKSPACE}/image.digest")"
          IMAGE_DIGEST_REF="${HARBOR_HOST}/${HARBOR_PROJ}/${IMAGE_NAME}@${DIGEST}"
          echo "Signing ${IMAGE_DIGEST_REF}"

          # --- Grant acquisition (see 02 §5) --------------------------------
          set +x
          umask 077
          printf '%s' "${VENAFI_OIDC_TOKEN}" > "${WORKSPACE}/.venafi.jwt"

          if ! pkcs11config checkgrant --days:1 >/dev/null 2>&1; then
              pkcs11config getgrant --force --jwtfile:"${WORKSPACE}/.venafi.jwt"
          fi
          rm -f "${WORKSPACE}/.venafi.jwt"
          set -x

          pkcs11config checkgrant     # RC 0 required; fails the stage otherwise

          # --- Sign the DIGEST, never the tag (see §8) ----------------------
          set +x
          KEY_URI="pkcs11:token=Remote%20Token;object=${VENAFI_OBJECT}?module-path=${PKCS11_MODULE}&pin-value=${PKCS11_PIN:-0000}"

          cosign sign \
              --key "${KEY_URI}" \
              --tlog-upload=false \
              --yes \
              "${IMAGE_DIGEST_REF}"
          set -x

          echo "Signed ${IMAGE_DIGEST_REF}"
        '''
      }
    }

    stage('Verify (gate)') {
      when { expression { !params.SKIP_SIGN } }
      steps {
        sh '''
          set -euo pipefail
          DIGEST="$(cat "${WORKSPACE}/image.digest")"
          IMAGE_DIGEST_REF="${HARBOR_HOST}/${HARBOR_PROJ}/${IMAGE_NAME}@${DIGEST}"

          set +x
          KEY_URI="pkcs11:token=Remote%20Token;object=${VENAFI_OBJECT}?module-path=${PKCS11_MODULE}&pin-value=${PKCS11_PIN:-0000}"

          cosign verify \
              --key "${KEY_URI}" \
              --insecure-ignore-tlog=true \
              "${IMAGE_DIGEST_REF}"
          set -x

          echo "Verification PASSED for ${IMAGE_DIGEST_REF}"
        '''
      }
    }
  }

  post {
    always {
      sh '''
        set +e
        # Revoke the grant ALWAYS — success, failure, or abort (see §9)
        pkcs11config revokegrant --force --clear >/dev/null 2>&1

        # Scrub transient secrets
        rm -f "${WORKSPACE}/.prisma.creds" "${WORKSPACE}/.venafi.jwt"
        rm -rf "${DOCKER_CONFIG}"
        podman logout --all >/dev/null 2>&1
        true
      '''
    }
    success {
      script {
        def digest = readFile("${env.WORKSPACE}/image.digest").trim()
        echo "SIGNED-ARTIFACT ${env.IMAGE_REF} digest=${digest} build=${env.BUILD_URL}"
      }
    }
  }
}
```

---

## 4. Per-build grant isolation

`LIBHSMINSTANCE = "ci-${BUILD_TAG}"` is set in `environment{}` and therefore exported to every `sh` step.
Each build gets an independent grant; one build's `revokegrant` cannot kill another's session. `HOME` is
likewise redirected into the workspace so `~/.venafipkcs11config` cannot collide. Rationale and the
vendor's example are in `02 §6`.

---

## 5. On `disableConcurrentBuilds`

The template disables concurrency as a safety default. With `LIBHSMINSTANCE` and per-workspace `HOME`
correctly configured, concurrent builds are safe and you can remove it. **Validate concurrency explicitly
before you do** (`08` validation, two simultaneous builds on one agent) — the failure mode is
intermittent and hard to diagnose in production.

---

## 6. podman ↔ cosign registry auth

> **This trips up nearly every first implementation.** podman writes credentials to
> `${XDG_RUNTIME_DIR}/containers/auth.json`. cosign reads Docker's `config.json` from the directory named
> by `DOCKER_CONFIG`. A successful `podman login` therefore leaves cosign completely unauthenticated, and
> `cosign sign` fails with a 401 that looks like a permissions problem in Harbor.

The pipeline resolves this by writing **one file** that both tools read:

```
DOCKER_CONFIG      = ${WORKSPACE}/.docker           # directory  → cosign reads ${DOCKER_CONFIG}/config.json
REGISTRY_AUTH_FILE = ${WORKSPACE}/.docker/config.json  # file     → podman reads this exact path
```

`podman login --authfile "${REGISTRY_AUTH_FILE}"` populates it; cosign picks it up via `DOCKER_CONFIG`.
Both formats use the same `{"auths": {...}}` structure. The directory is removed in `post{}`.

If you prefer explicit auth, `cosign login "${HARBOR_HOST}" -u "${USER}" -p "${TOKEN}"` also works — but
it writes to the same config file, so `DOCKER_CONFIG` must still be set to keep it inside the workspace.

**The robot account needs push on the signature artifact too**, not just the image — see `05 §3`.

---

## 7. Keeping secrets out of the console log

Discipline applied throughout the template:

- `set +x` around every block that touches a secret; `set -x` after.
- Secrets are shell variables, never Groovy string interpolation (`"${...}"` in Groovy is expanded by
  Jenkins *before* the shell sees it and can land in the log).
- `--password-stdin` for `podman login` rather than `--password`.
- Credential files written with `umask 077`, deleted in `post{}`.
- The JWT is written to a file for `--jwtfile` and deleted immediately after use.

> **Verify masking during validation.** Run a build, then read the console log end to end and grep for
> fragments of each secret. Do not assume the plugin masked everything.

---

## 8. Sign the digest, never the tag

```groovy
IMAGE_DIGEST_REF = "${HARBOR_HOST}/${HARBOR_PROJ}/${IMAGE_NAME}@${DIGEST}"
```

Tags are mutable. Signing `app:1.2.3` and later re-pushing a different image to that tag leaves a valid
signature pointing at content nobody signed — a straightforward time-of-check/time-of-use attack. The
digest is content-addressed and immutable.

`podman push --digestfile` writes the authoritative digest the registry accepted. Use that value; do not
compute a local digest or scrape stdout.

---

## 9. Always revoke the grant

The `post { always { ... } }` block runs on success, failure, and abort. An abandoned grant is a live
signing credential on a build agent.

`revokegrant --force --clear` revokes and then removes stored configuration, so nothing reusable remains.
Errors are swallowed (`set +e`) so cleanup cannot mask the real failure — but `07 §6` covers alerting on
grants that outlive their build, which is how you detect cleanup silently failing.

---

## 10. `--tlog-upload=false` and `--insecure-ignore-tlog=true`

These are **correct here and must not be "fixed"**. Sigstore's public transparency log (Rekor) is for
public artifacts signed via the public Fulcio CA. Our images are private, signed with an internal
enterprise key, on an internal registry. There is no public log to write to and nothing meaningful to
read back.

- `cosign sign --tlog-upload=false` — do not attempt to upload to a public log.
- `cosign verify --insecure-ignore-tlog=true` — do not require a transparency-log entry.

The `insecure-` prefix is unfortunate naming for this context. It means "not using transparency logs",
not "not verifying the signature" — signature verification against the Venafi key is fully enforced. The
equivalent setting for admission is in `06 §4`.

> Add this paragraph to your control narrative. It is the flag most likely to be raised as a finding by a
> reviewer pattern-matching on the word `insecure`.

---

## 11. Break-glass (`SKIP_SIGN`)

`SKIP_SIGN` exists because a signing outage must not block an emergency security patch. Guard rails:

- Require an approval step (`input` with a restricted `submitter`) before it takes effect.
- The unsigned image cannot reach production — Policy Controller (`06`) will reject it. It is only usable
  in non-enforced namespaces.
- Emit an alert whenever the parameter is true.
- Record each use in the change record and re-sign the image once signing is restored (`07 §4`).

---

## 12. Acceptance checklist

- [ ] Job in the folder matching `bound_claims`, on the `container-signer` label
- [ ] Preflight catches a wrong-cosign-build agent with a clear error
- [ ] A failing scan blocks the build with **no** signature produced (negative test)
- [ ] Digest comes from `--digestfile`; signature references `@sha256:...`
- [ ] `cosign verify` gate passes; signature visible in Harbor (`05 §4`)
- [ ] Console log contains no secret fragments (manual grep)
- [ ] Grant revoked in `post{}` on success **and** on forced failure (test both)
- [ ] Two concurrent builds on one agent both sign successfully (if concurrency is enabled)
