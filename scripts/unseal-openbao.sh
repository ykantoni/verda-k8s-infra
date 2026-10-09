#!/bin/bash
# Lab-only convenience: auto-unseals OpenBao using keys stored in a local
# plaintext file. This deliberately trades away Shamir secret sharing's
# whole point (no single place holds enough keys to unseal alone) for
# operational convenience. Fine for a personal lab; don't do this if this
# OpenBao instance ever holds secrets you actually care about protecting
# from whoever has access to this machine — use a real auto-unseal (e.g.
# a Transit seal) instead.
#
# Usage: ./scripts/unseal-openbao.sh
# Env overrides: KEYS_FILE, NAMESPACE, POD
set -euo pipefail

KEYS_FILE="${KEYS_FILE:-$HOME/.openbao-unseal-keys}"
NAMESPACE="${NAMESPACE:-openbao}"
POD="${POD:-openbao-0}"

# Never trust a pre-existing ~/verda_kubeconfig.yaml — it could be stale
# (pointing at a since-destroyed/recreated cluster with a different IP).
# Regenerate it fresh from whatever verda-vm-infra currently has applied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDA_CLOUD_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
echo "Exporting a fresh kubeconfig from the currently built cluster..."
(cd "$VERDA_CLOUD_DIR" && just generate)

KUBECONFIG_PATH="$HOME/verda_kubeconfig.yaml"
kubectl() { command kubectl --kubeconfig "$KUBECONFIG_PATH" "$@"; }

if [ ! -f "$KEYS_FILE" ]; then
  echo "Keys file not found: $KEYS_FILE" >&2
  echo "Create it with one unseal key per line (lines starting with # are ignored)." >&2
  exit 1
fi

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

if echo "$STATUS" | grep -qi "Sealed.*false"; then
  echo "$POD is already unsealed — nothing to do."
  exit 0
fi

# A fresh PVC (new volume, e.g. after the cluster was rebuilt) means this
# is a brand-new OpenBao that was never `bao operator init`'d — unsealing
# one of those errors out ("Vault is not initialized") after the very
# first key, which looks like a partial/confusing failure rather than
# what it actually is. Keys from a PREVIOUS instance's init are useless
# here regardless — each init generates an entirely new master key.
if echo "$STATUS" | grep -qi "Initialized.*false"; then
  echo "$POD has never been initialized (this looks like a fresh volume, not a resealed one)." >&2
  echo "Run the one-time manual init step first, then re-run this script:" >&2
  echo "  kubectl --kubeconfig $HOME/verda_kubeconfig.yaml -n $NAMESPACE exec -it $POD -- bao operator init" >&2
  echo "Save the NEW keys it prints to $KEYS_FILE (overwriting the old ones — they're for a different instance now)." >&2
  exit 1
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
