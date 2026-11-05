#!/usr/bin/env bash
# verify-cert-manager.sh — prove Kubernetes -> cert-manager -> Vault -> Venafi TPP end to end
# (runbook 09, step K8 / evidence E9–E11). Run from a host with kubectl access to the cluster.
#
#   TPP_URL=https://tpp.corp.example.com TPP_CA=./tpp-chain.pem TPP_TOKEN=... \
#   TRUST_ROOT=./enterprise-root.pem EXPECT_FOLDER='Certificates\Vault\AUT\K8s' \
#     ./verify-cert-manager.sh
#
# Env: ISSUER=vault-venafi  NS=venafi-demo  CERT=demo-tls  TIMEOUT=300s  RENEW=1 (also prove renewal)
#      TPP_TOKEN (scope: certificate, read) is only needed for the TPP inventory checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../../../../tools/venafi_pki_proof.py"
ISSUER="${ISSUER:-vault-venafi}"; NS="${NS:-venafi-demo}"; CERT="${CERT:-demo-tls}"; TIMEOUT="${TIMEOUT:-300s}"
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 2; }
command -v openssl >/dev/null || { echo "openssl not found" >&2; exit 2; }

step() { printf '\n== %s\n' "$*"; }

step "1. ClusterIssuer $ISSUER is Ready (cert-manager logged in to Vault)"
kubectl get clusterissuer "$ISSUER" -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl wait clusterissuer "$ISSUER" --for=condition=Ready --timeout=60s >/dev/null

step "2. Apply the demo Certificate and wait for it"
kubectl apply -f "$HERE/02-certificate-demo.yaml" >/dev/null
if ! kubectl -n "$NS" wait certificate "$CERT" --for=condition=Ready --timeout="$TIMEOUT"; then
  echo "--- not Ready. CertificateRequest + events (look for Vault 403 / TPP policy errors):"
  kubectl -n "$NS" get certificaterequest -o wide || true
  kubectl -n "$NS" describe certificaterequest | sed -n '/Status:/,$p' | tail -30 || true
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -15 || true
  exit 1
fi
kubectl -n "$NS" get certificaterequest -o custom-columns='NAME:.metadata.name,APPROVED:.status.conditions[?(@.type=="Approved")].status,READY:.status.conditions[?(@.type=="Ready")].status,ISSUER:.spec.issuerRef.name'

step "3. Extract the issued secret (tls.crt = leaf + intermediates, ca.crt = root)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
kubectl -n "$NS" get secret "$CERT" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/tls.crt"
kubectl -n "$NS" get secret "$CERT" -o jsonpath='{.data.ca\.crt}'  | base64 -d > "$WORK/ca.crt" 2>/dev/null || true
openssl x509 -in "$WORK/tls.crt" -noout -subject -issuer -serial -enddate -ext subjectAltName -nameopt RFC2253
SERIAL1="$(openssl x509 -in "$WORK/tls.crt" -noout -serial | cut -d= -f2)"

step "4. Evidence report (chain, enterprise root, TPP inventory, Origin)"
args=(--cert-file "$WORK/tls.crt" --report-dir "${REPORT_DIR:-.tmp/venafi-proof}")
[[ -s "$WORK/ca.crt" ]]        && args+=(--chain-file "$WORK/ca.crt")
[[ -n "${TRUST_ROOT:-}" ]]     && args+=(--trust-root "$TRUST_ROOT")
[[ -n "${TPP_URL:-}" ]]        && args+=(--tpp-url "$TPP_URL")
[[ -n "${TPP_CA:-}" ]]         && args+=(--tpp-ca "$TPP_CA")
[[ -n "${EXPECT_FOLDER:-}" ]]  && args+=(--expect-folder "$EXPECT_FOLDER")
python3 "$TOOL" "${args[@]}"

if [[ "${RENEW:-0}" == "1" ]]; then
  step "5. Renewal: force a re-issue and prove a NEW serial came back (and is in TPP)"
  if command -v cmctl >/dev/null; then cmctl renew -n "$NS" "$CERT"
  else kubectl -n "$NS" patch certificate "$CERT" --subresource status --type merge \
         -p '{"status":{"conditions":[{"type":"Issuing","status":"True","reason":"ManuallyTriggered","message":"verify-cert-manager.sh","lastTransitionTime":"'"$(date -u +%FT%TZ)"'"}]}}'
  fi
  for _ in $(seq 1 60); do
    sleep 5
    kubectl -n "$NS" get secret "$CERT" -o jsonpath='{.data.tls\.crt}' | base64 -d > "$WORK/tls2.crt"
    SERIAL2="$(openssl x509 -in "$WORK/tls2.crt" -noout -serial | cut -d= -f2)"
    [[ "$SERIAL2" != "$SERIAL1" ]] && break
  done
  [[ "$SERIAL2" != "$SERIAL1" ]] || { echo "renewal did not produce a new certificate in 5 min" >&2; exit 1; }
  echo "renewed: serial $SERIAL1 -> $SERIAL2"
  args[1]="$WORK/tls2.crt"
  python3 "$TOOL" "${args[@]}"
fi
