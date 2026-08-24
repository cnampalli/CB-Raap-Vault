# 12 — Hands-On Lab: Zero to Signed Container Image

> **Purpose:** build real intuition for how CodeSign Protect works by doing it manually, one layer at a
> time, before automating any of it in `04`.
>
> **Prereqs:** read `10-venafi-concepts-primer.md` first. You need: a **sandbox** TPP project and
> environment (`01`, sandbox values), a Linux VM with the Code Signing Client and cosign installed (`02`),
> a sandbox Harbor project, and credentials for a test identity.
>
> **Time:** 2–3 hours. **Do not run this against production.**

---

## How to use this lab

Each exercise has three parts:

- **Do** — the commands.
- **Observe** — what to look at.
- **What just happened** — the concept it demonstrates.

Several exercises are designed to **fail**. Those teach more than the successes — do not skip them.

Set up your shell once:

```bash
export TPP_HOST="tpp-sandbox.corp.example.com"
export PKCS11_MODULE="/opt/venafi/codesign/lib/venafipkcs11.so"   # confirm your install path
export VENAFI_OBJECT="container-dev"                     # your sandbox environment label
export HARBOR_HOST="harbor-sandbox.corp.example.com"
export HARBOR_PROJ="signing-lab"
export LIBHSMINSTANCE="lab-$(id -un)"                    # isolate your lab session
```

---

## Exercise 1 — Meet the client

**Do:**

```bash
pkcs11config version
pkcs11config health
pkcs11config --help
```

**Observe:** the command list. Note the three groups — configuration (`getgrant`, `checkgrant`,
`revokegrant`, `trust`, `seturls`), signing/verification (`list`, `sign`, `verify`), and common
(`getcertificate`, `getpublickey`, `health`).

**What just happened:** you have a *client*, not a key store. Everything it does is a conversation with
TPP. `health` checked that it knows where the server is and can reach it.

> **Try this:** run `pkcs11config list` now, before authenticating. It fails or returns nothing — you have
> no grant yet. Nothing is available until you have an authenticated session.

---

## Exercise 2 — Understand the two endpoints

**Do:**

```bash
pkcs11config seturls \
    --authurl:https://${TPP_HOST}/vedauth \
    --hsmurl:https://${TPP_HOST}/vedhsm

curl -sSI "https://${TPP_HOST}/vedauth" | head -1
curl -sSI "https://${TPP_HOST}/vedhsm"  | head -1
```

**Observe:** two distinct endpoints on the same host.

**What just happened:** `/vedauth` handles *who you are*; `/vedhsm` handles *what you sign*. Separating
them lets you firewall, monitor and reason about authentication independently from signing volume — which
is exactly what the alerting in `07 §6` relies on.

---

## Exercise 3 — Acquire a grant

**Do:**

```bash
pkcs11config getgrant --force \
    --hostname:${TPP_HOST} \
    --username:<your-sandbox-user> \
    --password:<password>

pkcs11config checkgrant
echo "exit code: $?"
```

**Observe:** `checkgrant` prints grant information and exits **0**.

**What just happened:** you exchanged a credential for a **grant** — a token-based session stored in your
client configuration, not the key. Inspect where it lives:

```bash
ls -la ~/.venafipkcs11config
```

> **Try this:** run `pkcs11config getgrant` **without** `--force`. The docs note that a stored refresh
> token will be used to renew, *"ignoring any other provided credentials"*. Deliberately pass a **wrong**
> password without `--force` — it still succeeds, because it never used your password. This is exactly why
> `04` uses `--force`: without it, a rotated or revoked credential can appear to keep working.

---

## Exercise 4 — Discover the key (without ever holding it)

**Do:**

```bash
pkcs11config list

cosign pkcs11-tool list-tokens    --module-path "${PKCS11_MODULE}"
cosign pkcs11-tool list-keys-uris --module-path "${PKCS11_MODULE}"
```

**Observe:** the token is named **`Remote Token`**. Record the URI for your object.

**What just happened:** two different tools — Venafi's own utility and cosign — see the same objects
through the same PKCS#11 interface. cosign has no Venafi-specific code; it is talking to a standard API.

> **`Remote Token` is the whole design in two words.** A local token would be named for the device. This
> one announces that the key is somewhere else.

**Do:**

```bash
pkcs11config getpublickey --label:${VENAFI_OBJECT} \
    --filename:/tmp/lab.pub --format:PEM --force
cat /tmp/lab.pub
openssl pkey -pubin -in /tmp/lab.pub -text -noout | head -5
```

**Observe:** a public key, and its algorithm/curve.

**What just happened:** you extracted the **public** key. Now try the private one:

> **Try this (it must fail):** there is no `getprivatekey`. No command, no API, no flag. This is not an
> access-control setting you could misconfigure — the capability does not exist. That is the difference
> between "the key is protected" and "the key is unavailable".

---

## Exercise 5 — Sign something trivial

Before containers, sign a text file. Fewest moving parts.

**Do:**

```bash
echo "hello codesign protect" > /tmp/lab.txt

pkcs11config sign \
    --label:${VENAFI_OBJECT} \
    --file:/tmp/lab.txt \
    --output:/tmp/lab.txt.sig \
    --mechanism:<per your key type>      # run: pkcs11config sign -h

pkcs11config verify \
    --label:${VENAFI_OBJECT} \
    --file:/tmp/lab.txt \
    --signature:/tmp/lab.txt.sig
```

**Observe:** a signature file is produced and verifies.

**What just happened:** a complete round trip — your machine sent a hash to `/vedhsm`, TPP signed it with a
key you have never seen, and returned the signature. **No cosign, no containers, no registry.** This is the
primitive everything else is built on.

> **Try this:** `ls -l /tmp/lab.txt.sig` — a few dozen bytes. Now change one character in `lab.txt` and
> re-run `verify`. It fails. You have just demonstrated why signing a *digest* is sufficient to protect a
> multi-gigabyte image.

---

## Exercise 6 — Watch yourself in the audit log

**Do:** open Aperture → your sandbox project → the audit/log view for the environment. Find the signing
event from Exercise 5.

**Observe:** your identity, the timestamp, the key used.

**What just happened:** every use of the key is attributable. This is the control that makes the residual
risk in `00 §5` acceptable and makes incident response (`07 §5`) possible — an attacker with a live grant
can sign, but cannot sign *invisibly*.

> **Try this:** sign the file three more times, then refresh the log. Three new events. Now imagine this
> view during an incident: signing events that do not correspond to a CI build are the incident. That
> reconciliation is test `V-44`.

---

## Exercise 7 — Build and push a test image

**Do:**

```bash
mkdir -p /tmp/lab-image && cd /tmp/lab-image
cat > Containerfile <<'EOF'
FROM scratch
COPY hello.txt /hello.txt
EOF
echo "lab image v1" > hello.txt

export DOCKER_CONFIG="/tmp/lab-image/.docker"
export REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"
mkdir -p "${DOCKER_CONFIG}"

podman login "${HARBOR_HOST}" --authfile "${REGISTRY_AUTH_FILE}"

podman build -t "${HARBOR_HOST}/${HARBOR_PROJ}/lab:v1" .
podman push --authfile "${REGISTRY_AUTH_FILE}" \
    --digestfile /tmp/lab-image/image.digest \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab:v1"

DIGEST=$(cat /tmp/lab-image/image.digest)
echo "digest: ${DIGEST}"
```

**Observe:** the digest.

**What just happened:** you set `DOCKER_CONFIG` and `REGISTRY_AUTH_FILE` to the same location so podman and
cosign share credentials — the mismatch described in `04 §6`.

> **Try this (worth the two minutes):** unset `DOCKER_CONFIG`, run `podman login` normally, then attempt
> Exercise 8. cosign fails with a 401 even though podman is authenticated. Now you will recognise that
> error instantly instead of blaming Harbor permissions.

---

## Exercise 8 — Sign the image

**Do:**

```bash
KEY_URI="pkcs11:token=Remote%20Token;object=${VENAFI_OBJECT}?module-path=${PKCS11_MODULE}&pin-value=0000"

cosign sign --key "${KEY_URI}" --tlog-upload=false --yes \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
```

**Observe:** cosign reports the signature was pushed.

**What just happened:** the full chain. cosign hashed a payload referencing the digest, handed the hash to
the PKCS#11 module, which sent it to `/vedhsm`; TPP signed and returned it; cosign wrapped it in an OCI
artifact and pushed it to Harbor.

> **Try this:** note how long that took, then build a 1GB image and sign it. **Signing takes the same
> time.** Only a hash crosses the network — the image never goes near TPP. If anyone asks whether build
> artefacts leave the network for signing, this experiment is your answer.

---

## Exercise 9 — Look at what cosign created

**Do:**

```bash
SIG_TAG="${DIGEST/:/-}.sig"
podman pull "${HARBOR_HOST}/${HARBOR_PROJ}/lab:${SIG_TAG}" 2>/dev/null || true

cosign tree "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
cosign triangulate "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
```

Then open Harbor and find the artifact.

**Observe:** the signature is a **separate artifact** tagged `sha256-<digest>.sig`, shown by Harbor as an
*accessory*.

**What just happened:** signatures are ordinary OCI artifacts stored beside the image. Two consequences you
will meet again:

1. Pushing a signature requires **push** permission (`05 §3`).
2. A retention or GC policy that deletes accessories silently breaks verification later (`05 §6`, test
   `V-29`).

---

## Exercise 10 — Verify, then break it

**Do (should pass):**

```bash
cosign verify --key "${KEY_URI}" --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
```

**Do (verify with only the public key — no Venafi at all):**

```bash
cosign verify --key /tmp/lab.pub --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
```

**What just happened:** verification needs only the **public** key. No grant, no TPP, no network path to
Venafi. This is why Policy Controller (`06`) can verify inside a cluster with no Venafi connectivity — and
why the public key's *integrity* matters even though it is not secret (`01 §8`).

**Now break it — three ways:**

```bash
# 1. Tamper: push different content to the SAME tag
echo "lab image v1 TAMPERED" > hello.txt
podman build -t "${HARBOR_HOST}/${HARBOR_PROJ}/lab:v1" .
podman push --authfile "${REGISTRY_AUTH_FILE}" "${HARBOR_HOST}/${HARBOR_PROJ}/lab:v1"

cosign verify --key /tmp/lab.pub --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab:v1"          # by TAG  → FAILS
cosign verify --key /tmp/lab.pub --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"   # by DIGEST → still passes
```

**What just happened — the most important lesson in this lab.** The tag now points at content nobody
signed. The digest still points at the original, still-valid image. **Tags are mutable; digests are not.**
This is precisely why `04 §8` signs the digest and why Policy Controller rewrites tags to digests at
admission (`06 §6`).

```bash
# 2. Wrong key
cosign generate-key-pair                                   # creates cosign.key / cosign.pub
cosign verify --key cosign.pub --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"          # FAILS — signature not from this key

# 3. Delete the signature
cosign clean "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"
cosign verify --key /tmp/lab.pub --insecure-ignore-tlog=true \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"          # FAILS — no signature found
```

Re-sign before continuing (Exercise 8).

---

## Exercise 11 — Lose the grant

**Do:**

```bash
pkcs11config revokegrant --force
pkcs11config checkgrant; echo "exit code: $?"          # expect 1

cosign sign --key "${KEY_URI}" --tlog-upload=false --yes \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"      # FAILS
```

**Observe:** the exact error text. **Write it down** — you will see it in a build log one day.

**What just happened:** the grant *is* the signing capability. Revoking it ends the ability to sign
immediately, without touching the key, the certificate, or any credential.

> **This is the security property that makes remote signing worth the complexity.** In a key-file world,
> "revoking" access means rotating a key and re-signing everything. Here it is one command, instantly,
> with no effect on already-valid signatures. It is also why `04` revokes in `post { always { } }` — an
> abandoned grant is a live signing credential sitting on a build agent.

Re-acquire your grant (Exercise 3) before continuing.

---

## Exercise 12 — Concurrency and `LIBHSMINSTANCE`

**Do:** two terminals on the same host.

```bash
# Terminal A
export LIBHSMINSTANCE=lab-a
pkcs11config getgrant --force --hostname:${TPP_HOST} --username:<user-a> --password:<pw>
pkcs11config checkgrant

# Terminal B
export LIBHSMINSTANCE=lab-b
pkcs11config getgrant --force --hostname:${TPP_HOST} --username:<user-b> --password:<pw>
pkcs11config checkgrant

# Terminal B: revoke
pkcs11config revokegrant --force

# Terminal A: still valid?
pkcs11config checkgrant; echo "exit code: $?"     # expect 0 — A survived B's revoke
```

**Now repeat with `LIBHSMINSTANCE` unset in both.** Terminal B's revoke kills Terminal A's grant.

**What just happened:** you reproduced the intermittent CI failure described in `02 §6` — and its fix. Two
concurrent builds sharing one configuration fight over one grant; one build's cleanup breaks the other's
signing. It passes under light load and fails randomly under parallelism, which is the worst kind of bug to
diagnose in production.

---

## Exercise 13 — Prove the key never moved

**Do:**

```bash
sudo tcpdump -i any -w /tmp/sign.pcap "host ${TPP_HOST} and port 443" &
TCPDUMP_PID=$!
sleep 2

cosign sign --key "${KEY_URI}" --tlog-upload=false --yes \
    "${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"

sleep 2; sudo kill ${TCPDUMP_PID}
ls -lh /tmp/sign.pcap
```

**Observe:** the capture is tiny — a TLS handshake and a few small exchanges, regardless of image size.

**What just happened:** the traffic volume itself demonstrates that only a hash and a signature crossed the
wire. The contents are TLS-encrypted, but the *size* is the evidence. Pair this with Exercise 4's
"there is no `getprivatekey`" and you have a two-part demonstration of key custody suitable for an audit
conversation.

---

## Exercise 14 (optional) — Admission

If you have a sandbox cluster with Policy Controller (`06`):

```bash
kubectl create namespace lab-signed
kubectl label namespace lab-signed policy.sigstore.dev/include=true

# Apply a ClusterImagePolicy with /tmp/lab.pub as the key (see 06 §4)

kubectl -n lab-signed run signed   --image="${HARBOR_HOST}/${HARBOR_PROJ}/lab@${DIGEST}"   # admitted
kubectl -n lab-signed run unsigned --image=docker.io/library/busybox:latest                # rejected
```

Then the test that matters most:

```bash
# Block egress to public Rekor, then redeploy the signed image (test V-35 in 08 §6)
```

**What just happened:** the same public key from Exercise 4, in a cluster with no Venafi connectivity,
deciding what may run. The chain is complete: Venafi holds the key → cosign signs a digest → Harbor stores
the signature → Kubernetes enforces it.

---

## Tear down

```bash
pkcs11config revokegrant --force --clear
podman logout --all
rm -rf /tmp/lab-image /tmp/lab.txt /tmp/lab.txt.sig /tmp/lab.pub /tmp/sign.pcap cosign.key cosign.pub
# Delete the sandbox Harbor repository
```

---

## What you should now be able to explain

Check yourself. If any of these is shaky, re-read the linked section.

- [ ] Why Venafi "does not sign code" yet is central to signing — `10 §3`
- [ ] What a grant is, and why revoking it stops signing instantly — Ex. 3, 11
- [ ] Why the token is called `Remote Token` — Ex. 4
- [ ] Why there is no way to export the private key — Ex. 4
- [ ] Why signing a 1GB image is as fast as a 1KB one — Ex. 8, 13
- [ ] Why we sign digests and never tags — Ex. 10
- [ ] Why verification needs no Venafi connectivity — Ex. 10
- [ ] Why a deleted signature accessory breaks verification weeks later — Ex. 9
- [ ] Why `LIBHSMINSTANCE` prevents an intermittent CI failure — Ex. 12
- [ ] Why podman and cosign disagree about credentials — Ex. 7
- [ ] Why `--insecure-ignore-tlog` is not insecure here — `04 §10`, `11`

---

## Next

- Build it for real: `01-venafi-codesign-setup.md`
- Validate it: `08-validation-runbook.md`
- Ship it: `09-rollout-plan.md`
