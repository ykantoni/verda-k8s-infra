#!/bin/bash
# Wires OpenBao up as External Secrets Operator's backend for the vLLM
# Hugging Face token — the first real use of either (both have sat
# installed-but-unconfigured since they were first added). Split into two
# parts:
#
#   1. Mechanical wiring (kv engine, Kubernetes auth, policy, role, the
#      ClusterRoleBinding OpenBao needs to call the TokenReview API) —
#      always runs, fully idempotent, needs no secret input. This is what
#      lets ESO's SecretStore/ExternalSecret (argo-apps/vllm-secrets.yaml)
#      actually authenticate against OpenBao.
#   2. The Hugging Face token value itself — the one input only you can
#      supply (Gemma is gated; see verda-k8s-infra's README). Read from
#      $HF_TOKEN if set, else from ~/.hf-token (same out-of-git convention
#      as ~/.openbao-unseal-keys) if that file exists. If neither is
#      present, this step is skipped with a message — never a hard
#      failure, since this script runs automatically on every
#      `just k8s-apply` and a missing token must never block the rest of
#      the install.
#
# Usage: ./scripts/configure-vllm-secret.sh
# Env overrides: HF_TOKEN, KEYS_FILE, HF_TOKEN_FILE, NAMESPACE, POD, OPENBAO_SERVICE_ACCOUNT
set -euo pipefail

KEYS_FILE="${KEYS_FILE:-$HOME/.openbao-unseal-keys}"
HF_TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.hf-token}"
NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"
# Default ServiceAccount name the openbao-helm chart creates for a release
# named "openbao" (confirmed against the chart's server-serviceaccount.yaml
# template) — override if argo-apps/openbao.yaml's Application name ever
# changes from "openbao".
OPENBAO_SERVICE_ACCOUNT="${OPENBAO_SERVICE_ACCOUNT:-openbao}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDA_CLOUD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
echo "Exporting a fresh kubeconfig from the currently built cluster..."
(cd "$VERDA_CLOUD_DIR" && just generate >/dev/null)

KUBECONFIG_PATH="$HOME/verda_kubeconfig.yaml"
kubectl() { command kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

echo "Waiting for $POD to be Running..."
for i in $(seq 1 30); do
  phase="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Running" ] && break
  sleep 5
  if [ "$i" -eq 30 ]; then
    echo "Timed out waiting for $POD to be Running." >&2
    exit 1
  fi
done

STATUS="$(kubectl -n "$NAMESPACE" exec "$POD" -- bao status -tls-skip-verify 2>/dev/null || true)"
if ! echo "$STATUS" | grep -qi "Sealed.*false"; then
  echo "$POD isn't unsealed yet — run 'just unseal' first." >&2
  exit 1
fi

if [ ! -f "$KEYS_FILE" ]; then
  echo "No root token found at $KEYS_FILE — run 'just unseal' first (it creates this file on first init)." >&2
  exit 1
fi
ROOT_TOKEN="$(sed -n 's/^# Root token: //p' "$KEYS_FILE" | head -1)"
if [ -z "$ROOT_TOKEN" ]; then
  echo "Couldn't find a '# Root token: ...' line in $KEYS_FILE." >&2
  exit 1
fi

bao() { kubectl -n "$NAMESPACE" exec "$POD" -- env BAO_TOKEN="$ROOT_TOKEN" bao "$@"; }

echo "--- Mechanical wiring (idempotent) ---"

if bao secrets list -format=json | grep -q '"secret/"'; then
  echo "kv-v2 already enabled at secret/."
else
  bao secrets enable -path=secret kv-v2
fi

if bao auth list -format=json | grep -q '"kubernetes/"'; then
  echo "Kubernetes auth method already enabled."
else
  bao auth enable kubernetes
fi

REVIEWER_JWT="$(kubectl -n "$NAMESPACE" exec "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
CA_CERT="$(kubectl -n "$NAMESPACE" exec "$POD" -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  token_reviewer_jwt="$REVIEWER_JWT" \
  kubernetes_ca_cert="$CA_CERT" \
  >/dev/null

# OpenBao's own ServiceAccount needs this to call the TokenReview API when
# validating the tokens ESO presents — the config write above succeeds
# either way, but every login attempt fails with a permissions error
# without it.
cat <<CRB | kubectl apply -f - >/dev/null
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: openbao-auth-delegator
subjects:
  - kind: ServiceAccount
    name: ${OPENBAO_SERVICE_ACCOUNT}
    namespace: ${NAMESPACE}
roleRef:
  kind: ClusterRole
  name: system:auth-delegator
  apiGroup: rbac.authorization.k8s.io
CRB

bao policy write vllm-hf-token-read - >/dev/null <<POLICY
path "secret/data/vllm/hf-token" {
  capabilities = ["read"]
}
POLICY

bao write auth/kubernetes/role/vllm \
  bound_service_account_names=vllm \
  bound_service_account_namespaces=vllm \
  policies=vllm-hf-token-read \
  ttl=1h \
  >/dev/null

echo "Mechanical wiring done: kv-v2 engine, Kubernetes auth, policy and role all in place."

echo "--- Hugging Face token (optional) ---"

TOKEN_VALUE="${HF_TOKEN:-}"
if [ -z "$TOKEN_VALUE" ] && [ -f "$HF_TOKEN_FILE" ]; then
  TOKEN_VALUE="$(head -1 "$HF_TOKEN_FILE")"
fi

if [ -z "$TOKEN_VALUE" ]; then
  echo "No Hugging Face token found (checked \$HF_TOKEN and $HF_TOKEN_FILE)."
  echo "The ExternalSecret will stay unresolved until you provide one — once"
  echo "you have a READ-scoped token (after accepting Gemma's license on"
  echo "Hugging Face), run:"
  echo "  HF_TOKEN=hf_xxx just configure-vllm-secret"
  echo "or save it to $HF_TOKEN_FILE and rerun."
  exit 0
fi

bao kv put secret/vllm/hf-token token="$TOKEN_VALUE" >/dev/null
echo "Wrote the Hugging Face token to secret/vllm/hf-token."
