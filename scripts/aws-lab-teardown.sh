#!/usr/bin/env bash
# Destroi tudo na ordem reversa para liberar créditos do AWS Lab.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh"

echo ""
echo -e "${RED}══════════════════════════════════════════════════════${NC}"
echo -e "${RED}  TEARDOWN — vai destruir TUDO no AWS Lab${NC}"
echo -e "${RED}══════════════════════════════════════════════════════${NC}"
echo ""
read -r -p "Confirma? (digite 'destroy' para prosseguir) " resp
[ "$resp" = "destroy" ] || { echo "abortado"; exit 0; }

# kubectl pode falhar se cluster já foi destruído — tudo ok
echo ""
echo -e "${YELLOW}→ 1/3 Apagando workloads K8s (best-effort)${NC}"
if aws eks describe-cluster --name "autoflow-eks" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "autoflow-eks" >/dev/null 2>&1 || true
  kubectl delete namespace autoflow --timeout=120s --ignore-not-found 2>/dev/null || true
  kubectl delete namespace kong --timeout=120s --ignore-not-found 2>/dev/null || true
  echo "   ✓ namespaces apagados"
else
  echo "   (cluster já não existe)"
fi

echo ""
echo -e "${YELLOW}→ 2/3 terraform destroy 02-database-rds${NC}"
cd "$INFRA_DIR/02-database-rds"
terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null
terraform destroy -auto-approve -var-file=environments/dev.tfvars

echo ""
echo -e "${YELLOW}→ 3/3 terraform destroy 01-network-eks${NC}"
cd "$INFRA_DIR/01-network-eks"
terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null
terraform destroy -auto-approve -var-file=environments/dev.tfvars

echo ""
echo -e "${GREEN}✓ Teardown completo. Bucket S3 ($TFSTATE_BUCKET) NÃO foi removido para preservar o tfstate.${NC}"
echo "   Para deletar o bucket: aws s3 rb s3://${TFSTATE_BUCKET} --force"
