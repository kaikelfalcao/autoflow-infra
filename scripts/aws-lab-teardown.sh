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

CLUSTER_NAME="autoflow-dev-eks"

# kubectl pode falhar se cluster já foi destruído — tudo ok
echo ""
echo -e "${YELLOW}→ 1/3 Apagando workloads K8s (best-effort)${NC}"
KUBECTL_OK=false
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  if kubectl get ns >/dev/null 2>&1; then
    KUBECTL_OK=true
    kubectl delete namespace autoflow --timeout=120s --ignore-not-found 2>/dev/null || true
    kubectl delete namespace kong --timeout=120s --ignore-not-found 2>/dev/null || true
    echo "   ✓ namespaces apagados"
  else
    echo "   ⚠ kubectl não autenticou no cluster (IAM do AWS Lab pode ter rotacionado)"
  fi
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

# Se kubectl não autenticou, remove os recursos K8s/Helm do state para o destroy
# não falhar com "Unauthorized" — eles morrem junto com o cluster.
if [ "$KUBECTL_OK" = false ]; then
  echo "   → removendo recursos K8s/Helm do tfstate (cluster será destruído junto)"
  for addr in \
      helm_release.kong \
      kubernetes_namespace.kong \
      kubernetes_namespace.autoflow \
      kubernetes_storage_class.gp3 \
      kubernetes_annotations.gp2_not_default; do
    terraform state rm "$addr" >/dev/null 2>&1 && echo "     ✓ $addr removido do state" || true
  done
fi

# Limpa LBs/ENIs/EIPs órfãos antes do destroy da VPC.
# Quando o helm_release do Kong é removido do state (Unauthorized), o NLB
# criado pelo Service do K8s não é deletado, e a VPC fica presa por
# DependencyViolation no IGW/subnets. Resolvemos pela API AWS.
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
if [ -n "$VPC_ID" ]; then
  echo "   → limpando recursos órfãos na VPC $VPC_ID"

  # NLBs / ALBs (elbv2)
  for arn in $(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null); do
    [ -z "$arn" ] && continue
    aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" >/dev/null 2>&1 \
      && echo "     ✓ NLB/ALB deletado: $arn" || true
  done

  # Classic LBs (elb)
  for name in $(aws elb describe-load-balancers --region "$AWS_REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null); do
    [ -z "$name" ] && continue
    aws elb delete-load-balancer --region "$AWS_REGION" --load-balancer-name "$name" >/dev/null 2>&1 \
      && echo "     ✓ Classic LB deletado: $name" || true
  done

  # Aguarda ENIs do LB sumirem (até ~90s)
  for _ in $(seq 1 18); do
    pending=$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$VPC_ID" "Name=description,Values=ELB*" \
      --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo "0")
    [ "$pending" = "0" ] && break
    sleep 5
  done

  # ENIs órfãs (status=available) — força delete
  for eni in $(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); do
    [ -z "$eni" ] && continue
    aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" >/dev/null 2>&1 \
      && echo "     ✓ ENI deletada: $eni" || true
  done

  # EIPs sem associação criados para esta VPC (ex.: NAT Gateway, NLB)
  for alloc in $(aws ec2 describe-addresses --region "$AWS_REGION" \
        --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null); do
    [ -z "$alloc" ] && continue
    aws ec2 release-address --region "$AWS_REGION" --allocation-id "$alloc" >/dev/null 2>&1 \
      && echo "     ✓ EIP liberado: $alloc" || true
  done
else
  echo "   (sem vpc_id no state — skip cleanup AWS API)"
fi

terraform destroy -auto-approve -var-file=environments/dev.tfvars

echo ""
echo -e "${GREEN}✓ Teardown completo. Bucket S3 ($TFSTATE_BUCKET) NÃO foi removido para preservar o tfstate.${NC}"
echo "   Para deletar o bucket: aws s3 rb s3://${TFSTATE_BUCKET} --force"
