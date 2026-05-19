#!/usr/bin/env bash
# Bootstrap do ambiente (plataforma) no AWS Lab — SEM deploy de apps.
#
# Sobe: VPC + EKS + Kong, RDS Postgres (4 DBs + 4 users), MongoDB×2,
#       RabbitMQ, Kong routes, e cria os 6 <svc>-secrets no namespace
#       autoflow apontando para os endpoints reais.
#
# NÃO faz: build/push das imagens, migrations, deploy/rollout dos serviços.
# Quem faz isso é o CD de cada repo (workflow_run após CI em main).
#
# Uso:
#   ./aws-lab-bootstrap.sh             # sobe tudo do zero
#   ./aws-lab-bootstrap.sh --skip-tf   # reaproveita VPC/EKS/RDS existentes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SKIP_TF=false
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-tf) SKIP_TF=true; shift ;;
    -h|--help) sed -n '1,16p' "$0"; exit 0 ;;
    *) echo "arg desconhecido: $1" >&2; exit 1 ;;
  esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
banner() { echo; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }
ok() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

# ── pré-checks
for cmd in aws terraform kubectl helm jq python3 openssl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd não encontrado"
done

# ── 1. login AWS + bucket tfstate
banner "1/7  AWS login + S3 tfstate bucket"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh"

# Como o usuário optou por MP real (sem mock), exigimos o token agora.
[ -n "${MP_ACCESS_TOKEN:-}" ] || fail "MP_ACCESS_TOKEN ausente no .env — bootstrap configurado para MP real (sem mock)."

# ── 2. terraform 01-network-eks
if [ "$SKIP_TF" = false ]; then
  banner "2/7  Terraform 01-network-eks (~15 min)"
  cd "$INFRA_DIR/01-network-eks"
  terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null
  terraform apply -auto-approve -var-file=environments/dev.tfvars
  CLUSTER_NAME=$(terraform output -raw cluster_name)
  ok "EKS pronto: $CLUSTER_NAME"
else
  cd "$INFRA_DIR/01-network-eks"
  terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null
  CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null || echo "")
  [ -n "$CLUSTER_NAME" ] || fail "cluster ainda não existe — rode sem --skip-tf primeiro"
fi
export CLUSTER_NAME

# ── 3. terraform 02-database-rds
if [ "$SKIP_TF" = false ]; then
  banner "3/7  Terraform 02-database-rds (~10 min)"
  cd "$INFRA_DIR/02-database-rds"
  terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null

  terraform apply -auto-approve -var-file=environments/dev.tfvars

  RDS_ID=$(terraform output -raw db_address | cut -d. -f1)
  echo "→ reboot RDS para aplicar pending-reboot params (~1 min)"
  aws rds reboot-db-instance --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
  for _ in $(seq 1 60); do
    st=$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" --region "$AWS_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text)
    [ "$st" = "available" ] && break
    sleep 10
  done
  ok "RDS pronto"
fi

# ── 4. kubeconfig
banner "4/7  kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
kubectl cluster-info >/dev/null
ok "kubectl conectado a $CLUSTER_NAME"

echo "→ aguardando EBS CSI controller pronto"
for _ in $(seq 1 30); do
  ready=$(kubectl get pods -n kube-system -l app=ebs-csi-controller -o jsonpath='{.items[?(@.status.phase=="Running")].status.containerStatuses[?(@.ready==true)].name}' 2>/dev/null | wc -w)
  [ "$ready" -ge 6 ] && break
  sleep 5
done
ok "EBS CSI controller pronto"

# ── 5. init databases (4 users + 4 dbs)
banner "5/7  Criando databases + users por service"
cd "$INFRA_DIR/02-database-rds"
DB_HOST=$(terraform output -raw db_address)
DB_PORT=$(terraform output -raw db_port)
DB_MASTER_USER=$(terraform output -raw db_master_username)
DB_MASTER_PASS=$(terraform output -raw db_master_password)
SVC_CREDS=$(terraform output -json service_credentials)

sql_via_pod() {
  local sql_file="$1"
  kubectl run pg-$RANDOM-$RANDOM --rm -i --restart=Never --image=postgres:16-alpine \
    --env="PGPASSWORD=$DB_MASTER_PASS" --quiet --command -- \
    sh -c "psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_MASTER_USER' -d postgres -v ON_ERROR_STOP=1" < "$sql_file" 2>&1 | tail -3
}

USERS_SQL=$(mktemp)
for db_name in identity order saga payment; do
  user="${db_name}_user"
  pw=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['$db_name']['password'])")
  cat >> "$USERS_SQL" <<EOF_SQL
DO \$body\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='$user') THEN
    CREATE ROLE "$user" LOGIN PASSWORD '$pw';
  ELSE
    ALTER ROLE "$user" WITH LOGIN PASSWORD '$pw';
  END IF;
END \$body\$;
EOF_SQL
done
sql_via_pod "$USERS_SQL"
ok "users (4) criados/atualizados"

for db_name in identity order saga payment; do
  user="${db_name}_user"
  exists=$(kubectl run pg-c-$RANDOM --rm -i --restart=Never --image=postgres:16-alpine \
    --env="PGPASSWORD=$DB_MASTER_PASS" --quiet --command -- \
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres -tA -c "SELECT 1 FROM pg_database WHERE datname='$db_name';" 2>&1 | tr -d '[:space:]')
  ONE_SQL=$(mktemp)
  if [ "$exists" != "1" ]; then
    echo "CREATE DATABASE \"$db_name\" OWNER \"$user\";" > "$ONE_SQL"
  else
    echo "ALTER DATABASE \"$db_name\" OWNER TO \"$user\";" > "$ONE_SQL"
  fi
  sql_via_pod "$ONE_SQL" >/dev/null
  rm -f "$ONE_SQL"
  ok "$db_name pronto (owner=$user)"
done

GRANTS_SQL=$(mktemp)
for db_name in identity order saga payment; do
  echo "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"${db_name}_user\";" >> "$GRANTS_SQL"
done
sql_via_pod "$GRANTS_SQL" >/dev/null
rm -f "$USERS_SQL" "$GRANTS_SQL"
ok "grants aplicados"

# ── 6. shared infra (mongo, rabbitmq, kong routes)
banner "6/7  Mongo×2 + RabbitMQ + Kong routes"

MONGO_CAT_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')
MONGO_NOT_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')
RMQ_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')

apply_secret() {
  local name="$1"; shift
  kubectl create secret generic "$name" -n autoflow "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

kubectl apply -f "$INFRA_DIR/03-k8s-shared/01-mongodb-catalog.yaml" >/dev/null
kubectl apply -f "$INFRA_DIR/03-k8s-shared/02-mongodb-notification.yaml" >/dev/null
kubectl apply -f "$INFRA_DIR/03-k8s-shared/03-rabbitmq.yaml" >/dev/null

apply_secret mongodb-catalog-auth \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=catalog_admin \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGO_CAT_PASS_NEW" \
  --from-literal=MONGO_INITDB_DATABASE=catalog
apply_secret mongodb-notification-auth \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=notification_admin \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD="$MONGO_NOT_PASS_NEW" \
  --from-literal=MONGO_INITDB_DATABASE=notification
apply_secret rabbitmq-auth \
  --from-literal=RABBITMQ_DEFAULT_USER=admin \
  --from-literal=RABBITMQ_DEFAULT_PASS="$RMQ_PASS_NEW"

for ss in mongodb-catalog mongodb-notification rabbitmq; do
  kubectl rollout status statefulset/$ss -n autoflow --timeout=300s >/dev/null && ok "$ss ready"
done

kubectl apply -f "$INFRA_DIR/03-k8s-shared/04-kong-routes.yaml" >/dev/null
ok "Kong routes aplicadas (vão ficar 503 até CD subir os Services)"

# ── 7. secrets dos 6 services (com endpoints reais do RDS/Mongo/RMQ)
banner "7/7  Secrets dos 6 services"
MONGO_CAT_PASS=$(kubectl get secret mongodb-catalog-auth -n autoflow -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)
MONGO_NOT_PASS=$(kubectl get secret mongodb-notification-auth -n autoflow -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)
RMQ_PASS=$(kubectl get secret rabbitmq-auth -n autoflow -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
RMQ_URL="amqp://admin:${RMQ_PASS}@rabbitmq.autoflow.svc.cluster.local:5672"

# identity (Postgres + JWT + seed admin)
JWT_SECRET=$(openssl rand -hex 32)
ID_PASS=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['identity']['password'])")
kubectl create secret generic identity-secrets -n autoflow \
  --from-literal=NODE_ENV=production \
  --from-literal=PORT=3000 \
  --from-literal=DATABASE_URL="postgresql://identity_user:${ID_PASS}@${DB_HOST}:${DB_PORT}/identity" \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --from-literal=JWT_CUSTOMER_EXPIRES_IN=1h \
  --from-literal=JWT_ADMIN_EXPIRES_IN=8h \
  --from-literal=ORDER_SERVICE_URL=http://order-service.autoflow.svc.cluster.local:3001 \
  --from-literal=ORDER_SERVICE_TIMEOUT_MS=2000 \
  --from-literal=SEED_ADMIN_EMAIL=admin@autoflow.com \
  --from-literal=SEED_ADMIN_PASSWORD=Admin@123 \
  --from-literal=SEED_ADMIN_NAME=Administrador \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-identity \
  --from-literal=LOG_LEVEL=info \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "identity-secrets aplicado"

# order
ORD_PASS=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['order']['password'])")
kubectl create secret generic order-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=APP_PORT=3001 \
  --from-literal=DATABASE_HOST="$DB_HOST" --from-literal=DATABASE_PORT="$DB_PORT" \
  --from-literal=DATABASE_USER=order_user --from-literal=DATABASE_PASSWORD="$ORD_PASS" \
  --from-literal=DATABASE_NAME=order --from-literal=RABBITMQ_URL="$RMQ_URL" \
  --from-literal=ENABLE_PAYMENT_CONSUMER=true \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-order \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "order-secrets aplicado"

# saga
SAG_PASS=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['saga']['password'])")
kubectl create secret generic saga-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=APP_PORT=3002 \
  --from-literal=DATABASE_HOST="$DB_HOST" --from-literal=DATABASE_PORT="$DB_PORT" \
  --from-literal=DATABASE_USER=saga_user --from-literal=DATABASE_PASSWORD="$SAG_PASS" \
  --from-literal=DATABASE_NAME=saga --from-literal=RABBITMQ_URL="$RMQ_URL" \
  --from-literal=ORDER_SERVICE_URL=http://order-service.autoflow.svc.cluster.local:3001 \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-saga \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "saga-secrets aplicado"

# catalog (Mongo)
kubectl create secret generic catalog-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=PORT=3003 \
  --from-literal=MONGODB_URI="mongodb://catalog_admin:${MONGO_CAT_PASS}@mongodb-catalog.autoflow.svc.cluster.local:27017/catalog?authSource=admin" \
  --from-literal=RABBITMQ_URL="$RMQ_URL" --from-literal=RABBITMQ_PREFETCH=10 \
  --from-literal=CORRELATION_ID_HEADER=x-correlation-id \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-catalog \
  --from-literal=LOG_LEVEL=info \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "catalog-secrets aplicado"

# payment (Postgres + MP real)
PAY_PASS=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['payment']['password'])")
# MP_NOTIFICATION_URL aponta para o Kong NLB. mercado-pago.adapter.ts faz
# getOrThrow nesse env var, então é obrigatório quando MP_MOCK=false.
NLB_HOST_FOR_MP=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
[ -n "$NLB_HOST_FOR_MP" ] || warn "Kong NLB sem hostname ainda — MP_NOTIFICATION_URL ficará vazio (pod vai crashar até reaplicar o secret)"
MP_NOTIFICATION_URL="http://${NLB_HOST_FOR_MP}/billing/webhook/mercadopago"
kubectl create secret generic payment-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=PORT=3004 \
  --from-literal=DB_HOST="$DB_HOST" --from-literal=DB_PORT="$DB_PORT" \
  --from-literal=DB_USER=payment_user --from-literal=DB_PASS="$PAY_PASS" --from-literal=DB_NAME=payment \
  --from-literal=RABBITMQ_URL="$RMQ_URL" \
  --from-literal=MP_MOCK=false \
  --from-literal=MP_ACCESS_TOKEN="$MP_ACCESS_TOKEN" \
  --from-literal=MP_NOTIFICATION_URL="$MP_NOTIFICATION_URL" \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-payment \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "payment-secrets aplicado (MP_MOCK=false, MP_NOTIFICATION_URL=$MP_NOTIFICATION_URL)"

# notification (Mongo)
kubectl create secret generic notification-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=PORT=3005 \
  --from-literal=MONGO_URI="mongodb://notification_admin:${MONGO_NOT_PASS}@mongodb-notification.autoflow.svc.cluster.local:27017/notification?authSource=admin" \
  --from-literal=RABBITMQ_URL="$RMQ_URL" \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-notification \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "notification-secrets aplicado"

NLB_HOST=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")

banner "✅ BOOTSTRAP COMPLETO — pronto para o CD"
echo "  Cluster:    $CLUSTER_NAME"
echo "  RDS:        $DB_HOST"
echo "  Kong NLB:   ${NLB_HOST:-(aguardando AWS provisionar)}"
echo ""
echo "  Próximos passos:"
echo "    1. ./scripts/sync-github-secrets.sh    # propaga AWS_*/DOCKER_* p/ os 6 repos"
echo "    2. Merge das PRs feat/tech-challenge-fase-4 → main em cada repo"
echo "    3. CD de cada repo (workflow_run após CI) faz: build → push → kubectl apply -f k8s/ → rollout"
echo "    4. kubectl get pods -n autoflow -w     # acompanhar"
