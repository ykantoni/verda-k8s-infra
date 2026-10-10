#!/bin/bash
# Lab-only convenience: auto-initializes (if needed) and auto-unseals
# OpenBao using keys stored in a local plaintext file. This deliberately
# trades away Shamir secret sharing's whole point (no single place holds
# enough keys to unseal alone) for operational convenience. Fine for a
# personal lab; don't do this if this OpenBao instance ever holds secrets
# you actually care about protecting from whoever has access to this
# machine — use a real auto-unseal (e.g. a Transit seal) instead.
#
# Usage: ./scripts/unseal-openbao.sh
# Env overrides: KEYS_FILE, NAMESPACE, POD
set -euo pipefail

KEYS_FILE="${KEYS_FILE:-$HOME/.openbao-unseal-keys}"
NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required (to parse 'bao operator init' output) but isn't installed." >&2
  exit 1
fi

# Never trust a pre-existing ~/verda_kubeconfig.yaml — it could be stale
# (pointing at a since-destroyed/recreated cluster with a different IP).
# Regenerate it fresh from whatever verda-vm-infra currently has applied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDA_CLOUD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
echo "Exporting a fresh kubeconfig from the currently built cluster..."
(cd "$VERDA_CLOUD_DIR" && just generate)

KUBECONFIG_PATH="$HOME/verda_kubeconfig.yaml"
kubectl() { command kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

echo "Waiting for $POD to be Running..."
# Generous budget (10 min): on a fresh cluster this isn't just "wait for a
# pod that already exists" — Argo CD still has to sync the root app,
# create the child openbao Application, sync that, Helm-install the
# chart, and schedule the pod, before this pod even exists to check.
for i in $(seq 1 120); do
  phase="$(kubectl -n "$NAMESPACE" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "$phase" = "Running" ] && break
  sleep 5
  if [ "$i" -eq 120 ]; then
    echo "Timed out waiting for $POD to be Running." >&2
    exit 1
  fi
done

STATUS="$(kubectl -n "$NAMESPACE" exec "$POD" -- bao status -tls-skip-verify 2>/dev/null || true)"

if echo "$STATUS" | grep -qi "Sealed.*false"; then
  echo "$POD is already unsealed — nothing to do."
  exit 0
fi

# A fresh PVC (new volume, e.g. after the cluster was rebuilt) means this
# is a brand-new OpenBao that was never `bao operator init`'d — unsealing
# one of those errors out ("Vault is not initialized"). Keys from a
# PREVIOUS instance's init are useless here regardless — each init
# generates an entirely new master key — so auto-init and overwrite the
# keys file with the new ones rather than trying to unseal with stale keys.
if echo "$STATUS" | grep -qi "Initialized.*false"; then
  echo "$POD has never been initialized (fresh volume) — initializing automatically..."
  INIT_JSON="$(kubectl -n "$NAMESPACE" exec "$POD" -- bao operator init -format=json)"
  NEW_KEYS="$(echo "$INIT_JSON" | jq -r '.unseal_keys_b64[]')"
  ROOT_TOKEN="$(echo "$INIT_JSON" | jq -r '.root_token')"

  {
    echo "# OpenBao unseal keys (lab convenience — see verda-k8s-infra's README)."
    echo "# One key per line. Threshold is 3; only the first 3 non-comment lines are used."
    echo "$NEW_KEYS"
    echo "# Root token: $ROOT_TOKEN"
  } > "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"

  echo "Initialized. New keys (saved to $KEYS_FILE, back these up somewhere more durable too):"
  echo "$NEW_KEYS" | sed 's/^/  Unseal key: /'
  echo "  Root token: $ROOT_TOKEN"
fi

mapfile -t KEYS < <(grep -vE '^\s*(#|$)' "$KEYS_FILE" | head -n 3)
if [ "${#KEYS[@]}" -lt 3 ]; then
  echo "Need at least 3 unseal keys in $KEYS_FILE, found ${#KEYS[@]}." >&2
  exit 1
fi

for key in "${KEYS[@]}"; do
  kubectl -n "$NAMESPACE" exec "$POD" -- bao operator unseal "$key" >/dev/null
done

echo "Unseal complete:"
kubectl -n "$NAMESPACE" get pod "$POD"
