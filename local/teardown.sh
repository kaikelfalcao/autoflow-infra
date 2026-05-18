#!/usr/bin/env bash
# teardown.sh — destroi o cluster kind autoflow.
set -euo pipefail

CLUSTER_NAME="autoflow"

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "→ Destruindo cluster '${CLUSTER_NAME}'…"
  kind delete cluster --name "${CLUSTER_NAME}"
  echo "✓ Cluster destruído"
else
  echo "Cluster '${CLUSTER_NAME}' não existe — nada a fazer"
fi
