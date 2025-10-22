#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------------------
# kubectl-reloader
# Automatically reload Deployments when referenced ConfigMaps/Secrets change.
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

# Temporary checksum storage
STATE_FILE="/tmp/last_checksums_reloader"

while true; do
  TMPFILE=$(mktemp)
  
  # Dump all ConfigMaps and Secrets with names + data
  kubectl get configmaps,secrets $NS_ARGS -o json \
    | jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name,
       (if .data then (.data | tostring) else "" end)] | @tsv' \
    | sort \
    | sha256sum > "$TMPFILE"

  # Detect changes
  if [[ -f "$STATE_FILE" ]] && ! diff -q "$TMPFILE" "$STATE_FILE" >/dev/null; then
    echo "⚙️ Change detected — finding affected Deployments..."

    # Get list of all ConfigMaps/Secrets
    MAPS=$(kubectl get configmaps,secrets $NS_ARGS -o json | jq -r '.items[] | [.kind, .metadata.namespace, .metadata.name] | @tsv')

    while IFS=$'\t' read -r KIND NS NAME; do
      # Skip empty lines
      [[ -z "$NAME" ]] && continue

      # Check if this item changed by comparing its checksum
      NEW_HASH=$(kubectl get "$KIND" "$NAME" -n "$NS" -o json | jq -r '.data | tostring' | sha256sum | cut -d' ' -f1)
      OLD_HASH=$(grep -F "$KIND" "$STATE_FILE" 2>/dev/null || true)

      # If not found, it’s new
      if [[ -z "$OLD_HASH" ]]; then
        echo "🆕 Detected new $KIND $NS/$NAME"
        CHANGED="$KIND/$NAME"
      elif [[ "$NEW_HASH" != *"$OLD_HASH"* ]]; then
        echo "🔄 Detected change in $KIND $NS/$NAME"
        CHANGED="$KIND/$NAME"
      fi
    done <<< "$MAPS"

    if [[ -n "${CHANGED:-}" ]]; then
      for ITEM in $CHANGED; do
        IFS='/' read -r KIND NAME <<< "$ITEM"
        echo "🔎 Searching for Deployments referencing $KIND $NAME..."

        # Find Deployments that reference the changed item
        for DEPLOY in $(kubectl get deployments $NS_ARGS -o name); do
          DEPLOY_JSON=$(kubectl get "$DEPLOY" -o json)
          if echo "$DEPLOY_JSON" | grep -q "\"name\": \"$NAME\""; then
            kubectl patch "$DEPLOY" -p \
              "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"reloader.timestamp\":\"$(date +%s)\"}}}}}" \
              >/dev/null
            echo "  🔁 Reloaded: $DEPLOY (triggered by $KIND $NAME)"
          fi
        done
      done
    fi
  fi

  mv "$TMPFILE" "$STATE_FILE"
  sleep 10
done
