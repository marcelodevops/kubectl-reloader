#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# kubectl-reloader
# Automatically detect ConfigMap/Secret changes and patch Deployments with
# checksum annotations to trigger a rolling restart.
# ------------------------------------------------------------------------------
# Usage:
#   kubectl reloader run --namespace my-apps
#   kubectl reloader run --all-namespaces
# ------------------------------------------------------------------------------

NAMESPACE=""
ALL_NAMESPACES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    --all-namespaces|-A)
      ALL_NAMESPACES=true
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if $ALL_NAMESPACES; then
  NS_ARGS="--all-namespaces"
else
  NS_ARGS="--namespace ${NAMESPACE:-default}"
fi

echo "🔍 Watching for ConfigMap and Secret changes in ${NAMESPACE:-all namespaces}..."

while true; do
  # Compute checksums
  TMPFILE=$(mktemp)
  kubectl get configmaps,secrets $NS_ARGS -o json \
    | jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name,
       (if .data then (.data | tostring) else "" end)] | @tsv' \
    | sha256sum > "$TMPFILE"

  # Check if state changed
  if [[ -f /tmp/last_checksums ]] && ! diff -q "$TMPFILE" /tmp/last_checksums >/dev/null; then
    echo "⚙️ Detected ConfigMap/Secret change — reloading Deployments..."
    # Patch all deployments in scope to trigger restart
    for dep in $(kubectl get deployments $NS_ARGS -o name); do
      kubectl patch "$dep" -p \
        "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"reloader.timestamp\":\"$(date +%s)\"}}}}}" \
        >/dev/null
      echo "  🔁 Rolled deployment: $dep"
    done
  fi

  mv "$TMPFILE" /tmp/last_checksums
  sleep 10
done
