#!/usr/bin/env bash
# Roda happy-path E2E contra o NLB Kong do EKS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh" >/dev/null

aws eks update-kubeconfig --region "$AWS_REGION" --name autoflow-dev-eks >/dev/null 2>&1
NLB=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[ -n "$NLB" ] || { echo "✗ NLB Kong não encontrado"; exit 1; }

echo "→ NLB: http://$NLB"
export AUTOFLOW_BASE_URL="http://$NLB"
exec python3 "$SCRIPT_DIR/../local/_paths.py" happy
