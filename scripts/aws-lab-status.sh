#!/usr/bin/env bash
# Mostra estado atual do deploy AWS Lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh" >/dev/null

CYAN='\033[0;36m'; NC='\033[0m'
banner() { echo; echo -e "${CYAN}══ $* ══${NC}"; }

banner "EKS Cluster"
cluster=$(aws eks describe-cluster --name autoflow-dev-eks --region "$AWS_REGION" --query 'cluster.[name,status,version]' --output text 2>/dev/null || echo "ausente")
echo "  $cluster"

banner "RDS"
rds=$(aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[?DBInstanceIdentifier==`autoflow-dev-rds`].[DBInstanceIdentifier,DBInstanceStatus,Endpoint.Address]' \
  --output text 2>/dev/null || echo "ausente")
echo "  ${rds:-ausente}"

banner "K8s — pods autoflow"
if aws eks describe-cluster --name autoflow-dev-eks --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name autoflow-dev-eks >/dev/null 2>&1 || true
  kubectl get pods -n autoflow 2>/dev/null || echo "  (sem namespace autoflow ou kubectl não consegue conectar)"
else
  echo "  (cluster não existe)"
fi

banner "Kong NLB"
nlb=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
if [ -n "$nlb" ]; then
  echo "  http://$nlb"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$nlb/health" 2>/dev/null || echo "000")
  echo "  /health → HTTP $code"
else
  echo "  (sem NLB)"
fi

banner "S3 tfstate"
aws s3 ls "s3://$TFSTATE_BUCKET/" --recursive 2>/dev/null | awk '{print "  " $0}' || echo "  (bucket vazio ou ausente)"
