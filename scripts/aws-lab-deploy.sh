#!/usr/bin/env bash
# Deploy completo do autoflow no AWS Lab.
# Etapas: tf 01-network-eks → tf 02-database-rds → init dbs → kubeconfig
#         → namespace + 03-k8s-shared → secrets dos services (com env vars do RDS)
#         → migrations → deployments → smoke-test pelo NLB.
#
# Uso: ./aws-lab-deploy.sh [--skip-build] [--skip-tf] [--only-apps]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$INFRA_DIR/.." && pwd)"

SKIP_BUILD=false
SKIP_TF=false
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-tf)    SKIP_TF=true; shift ;;
    --only-apps)  SKIP_TF=true; SKIP_BUILD=true; shift ;;
    -h|--help) sed -n '1,8p' "$0"; exit 0 ;;
    *) echo "arg desconhecido: $1" >&2; exit 1 ;;
  esac
done

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
banner() { echo; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $*${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"; }
ok() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
fail() { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

# ── pré-checks
for cmd in aws terraform kubectl helm docker psql jq python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "$cmd não encontrado"
done

# ── 1. login AWS + bucket tfstate
banner "1/10  AWS login + S3 tfstate bucket"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh"

# ── 1b. garante que as 6 imagens estão no DockerHub
banner "1b/10  DockerHub — garante 6 imagens publicadas"
[ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKER_PASSWORD:-}" ] && \
  echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin >/dev/null 2>&1 \
  && ok "logged in DockerHub" || warn "DOCKER_USERNAME/PASSWORD ausentes no .env (push pode falhar)"

declare -A IMAGE_DIRS=(
  ["identity"]="identity-service"
  ["order"]="autoflow-order-service"
  ["saga"]="autoflow-saga-orchestrator"
  ["catalog"]="autoflow-catalog-service"
  ["payment"]="autoflow-payment-service"
  ["notification"]="autoflow-notification-service"
)
for key in "${!IMAGE_DIRS[@]}"; do
  repo="kaikelfalcao/autoflow-${key}"
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://hub.docker.com/v2/repositories/${repo}/tags/latest" 2>/dev/null || echo "000")
  if [ "$code" = "200" ] && [ "$SKIP_BUILD" = true ]; then
    ok "${repo}:latest já existe no Hub"
    continue
  fi
  dir="${IMAGE_DIRS[$key]}"
  echo "  → build + push ${repo}:latest (de $ROOT_DIR/$dir)"
  docker build -q -t "${repo}:latest" "$ROOT_DIR/$dir" >/dev/null && \
    docker push "${repo}:latest" 2>&1 | tail -1 && ok "${repo} pushed"
done

# ── 2. terraform 01-network-eks
if [ "$SKIP_TF" = false ]; then
  banner "2/10  Terraform 01-network-eks (~15 min)"
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
  banner "3/10  Terraform 02-database-rds (~10 min)"
  cd "$INFRA_DIR/02-database-rds"
  terraform init -reconfigure -backend-config="bucket=$TFSTATE_BUCKET" >/dev/null

  terraform apply -auto-approve -var-file=environments/dev.tfvars

  # Se rds.force_ssl mudou (ou é primeiro deploy), reboot para aplicar pending-reboot params
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
banner "4/10  kubeconfig"
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
kubectl cluster-info >/dev/null
ok "kubectl conectado a $CLUSTER_NAME"

# Espera EBS CSI ficar ACTIVE (Terraform aplica addon mas pods levam alguns segundos)
echo "→ aguardando EBS CSI controller pronto"
for _ in $(seq 1 30); do
  ready=$(kubectl get pods -n kube-system -l app=ebs-csi-controller -o jsonpath='{.items[?(@.status.phase=="Running")].status.containerStatuses[?(@.ready==true)].name}' 2>/dev/null | wc -w)
  [ "$ready" -ge 6 ] && break
  sleep 5
done
ok "EBS CSI controller pronto"

# ── 5. init databases (cria 4 users por service)
banner "5/10  Criando databases + users por service"
cd "$INFRA_DIR/02-database-rds"
# Precisa acesso ao RDS — via pod psql efêmero no EKS
DB_HOST=$(terraform output -raw db_address)
DB_PORT=$(terraform output -raw db_port)
DB_MASTER_USER=$(terraform output -raw db_master_username)
DB_MASTER_PASS=$(terraform output -raw db_master_password)
SVC_CREDS=$(terraform output -json service_credentials)

# Bash escape comem $$ — usa arquivo SQL servido via stdin
sql_via_pod() {
  local sql_file="$1"
  kubectl run pg-$RANDOM-$RANDOM --rm -i --restart=Never --image=postgres:16-alpine \
    --env="PGPASSWORD=$DB_MASTER_PASS" --quiet --command -- \
    sh -c "psql -h '$DB_HOST' -p '$DB_PORT' -U '$DB_MASTER_USER' -d postgres -v ON_ERROR_STOP=1" < "$sql_file" 2>&1 | tail -3
}

# 1) Cria users via DO $body$
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

# 2) Cria databases (precisa ficar fora de transação)
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

# 3) Grants
GRANTS_SQL=$(mktemp)
for db_name in identity order saga payment; do
  echo "GRANT ALL PRIVILEGES ON DATABASE \"$db_name\" TO \"${db_name}_user\";" >> "$GRANTS_SQL"
done
sql_via_pod "$GRANTS_SQL" >/dev/null
rm -f "$USERS_SQL" "$GRANTS_SQL"
ok "grants aplicados"

# ── 6. shared infra (mongo, rabbitmq, kong routes)
banner "6/10  Mongo×2 + RabbitMQ + Kong routes"

# Secrets FIRST — manifests dos statefulsets também incluem o Secret com
# REPLACE_ME_VIA_KUBECTL, então temos que reaplicar nossas senhas DEPOIS.
# Aqui setamos antes para garantir que se for um cluster novo, o initdb
# do Mongo já pega a senha certa.
MONGO_CAT_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')
MONGO_NOT_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')
RMQ_PASS_NEW=$(openssl rand -base64 24 | tr -d '/+=')

apply_secret() {
  local name="$1"; shift
  kubectl create secret generic "$name" -n autoflow "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Aplica manifests (StatefulSet + Service + Secret com placeholder)
kubectl apply -f "$INFRA_DIR/03-k8s-shared/01-mongodb-catalog.yaml" >/dev/null
kubectl apply -f "$INFRA_DIR/03-k8s-shared/02-mongodb-notification.yaml" >/dev/null
kubectl apply -f "$INFRA_DIR/03-k8s-shared/03-rabbitmq.yaml" >/dev/null

# Sobrescreve secrets com senhas geradas (só "pega" se o PVC ainda não existir
# ou se for primeiro boot do StatefulSet)
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

# Espera statefulsets ficarem prontos
for ss in mongodb-catalog mongodb-notification rabbitmq; do
  kubectl rollout status statefulset/$ss -n autoflow --timeout=300s >/dev/null && ok "$ss ready"
done

kubectl apply -f "$INFRA_DIR/03-k8s-shared/04-kong-routes.yaml" >/dev/null
ok "Kong routes aplicadas"

# ── 7. secrets dos 6 services (com endpoints reais do RDS/Mongo/RMQ)
banner "7/10  Secrets dos 6 services"
MONGO_CAT_PASS=$(kubectl get secret mongodb-catalog-auth -n autoflow -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)
MONGO_NOT_PASS=$(kubectl get secret mongodb-notification-auth -n autoflow -o jsonpath='{.data.MONGO_INITDB_ROOT_PASSWORD}' | base64 -d)
RMQ_PASS=$(kubectl get secret rabbitmq-auth -n autoflow -o jsonpath='{.data.RABBITMQ_DEFAULT_PASS}' | base64 -d)
RMQ_URL="amqp://admin:${RMQ_PASS}@rabbitmq.autoflow.svc.cluster.local:5672"

apply_pg_secret() {
  local key="$1"; local svc="$2"; local extra="${3:-}"
  local user_var="${key}_user"
  local pw
  pw=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['$key']['password'])")
  kubectl create secret generic "${svc}-secrets" -n autoflow \
    --from-literal=NODE_ENV=production \
    --from-literal=DATABASE_HOST="$DB_HOST" \
    --from-literal=DATABASE_PORT="$DB_PORT" \
    --from-literal=DATABASE_USER="$user_var" \
    --from-literal=DATABASE_PASSWORD="$pw" \
    --from-literal=DATABASE_NAME="$key" \
    --from-literal=RABBITMQ_URL="$RMQ_URL" \
    --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
    --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
    --from-literal=NEW_RELIC_APP_NAME="autoflow-${key}" \
    --from-literal=LOG_LEVEL=info \
    $extra \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "${svc}-secrets aplicado"
}

# identity (Postgres + extras)
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

# payment (Postgres + MP)
PAY_PASS=$(echo "$SVC_CREDS" | python3 -c "import json,sys;print(json.load(sys.stdin)['payment']['password'])")
MP_MOCK_FLAG="true"; [ -n "${MP_ACCESS_TOKEN:-}" ] && MP_MOCK_FLAG="false"
kubectl create secret generic payment-secrets -n autoflow \
  --from-literal=NODE_ENV=production --from-literal=PORT=3004 \
  --from-literal=DB_HOST="$DB_HOST" --from-literal=DB_PORT="$DB_PORT" \
  --from-literal=DB_USER=payment_user --from-literal=DB_PASS="$PAY_PASS" --from-literal=DB_NAME=payment \
  --from-literal=RABBITMQ_URL="$RMQ_URL" \
  --from-literal=MP_MOCK="$MP_MOCK_FLAG" \
  --from-literal=MP_ACCESS_TOKEN="${MP_ACCESS_TOKEN:-}" \
  --from-literal=NEW_RELIC_ENABLED="${NEW_RELIC_ENABLED:-false}" \
  --from-literal=NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-}" \
  --from-literal=NEW_RELIC_APP_NAME=autoflow-payment \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "payment-secrets aplicado"

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

# ── 8. migrations + deployments dos 6 services
banner "8/10  Migrations + deployments dos 6 services"
declare -A SVC_DIRS=(
  ["identity"]="identity-service"
  ["order"]="autoflow-order-service"
  ["saga"]="autoflow-saga-orchestrator"
  ["catalog"]="autoflow-catalog-service"
  ["payment"]="autoflow-payment-service"
  ["notification"]="autoflow-notification-service"
)

# migrations primeiro (delete + apply para garantir job fresh)
for key in identity order saga payment; do
  dir="${SVC_DIRS[$key]}"
  job_file="$ROOT_DIR/$dir/k8s/migration-job.yaml"
  [ -f "$job_file" ] || continue
  kubectl delete job "${key}-migration" -n autoflow --ignore-not-found >/dev/null
  kubectl apply -f "$job_file" >/dev/null
done
# wait migrations
for key in identity order saga payment; do
  kubectl wait --for=condition=complete --timeout=180s job/${key}-migration -n autoflow >/dev/null 2>&1 \
    && ok "migration $key OK" \
    || warn "migration $key falhou — ver: kubectl logs job/${key}-migration -n autoflow"
done

# seed admin (identity)
seed_file="$ROOT_DIR/identity-service/k8s/seed-job.yaml"
if [ -f "$seed_file" ]; then
  kubectl delete job identity-seed-admin -n autoflow --ignore-not-found >/dev/null
  kubectl apply -f "$seed_file" >/dev/null
  kubectl wait --for=condition=complete --timeout=60s job/identity-seed-admin -n autoflow >/dev/null 2>&1 \
    && ok "admin seed OK" \
    || warn "admin seed falhou"
fi

# deployments
for key in "${!SVC_DIRS[@]}"; do
  dir="${SVC_DIRS[$key]}"
  for f in deployment.yaml service.yaml hpa.yaml; do
    [ -f "$ROOT_DIR/$dir/k8s/$f" ] && kubectl apply -f "$ROOT_DIR/$dir/k8s/$f" >/dev/null
  done
  ok "$key deployed"
done

# Payment em prod usa MP real se MP_ACCESS_TOKEN setado; com mock (default) força 1 replica
if [ "$MP_MOCK_FLAG" = "true" ]; then
  warn "payment com MP_MOCK=true — limitando a 1 replica"
  kubectl patch hpa payment-service -n autoflow --type=merge \
    -p '{"spec":{"minReplicas":1,"maxReplicas":1}}' >/dev/null 2>&1 || true
  kubectl scale deploy payment-service --replicas=1 -n autoflow >/dev/null
fi

# wait rollouts
for dep in identity-service order-service saga-orchestrator catalog-service payment-service notification-service; do
  kubectl rollout status deployment/$dep -n autoflow --timeout=240s >/dev/null \
    && ok "$dep ready" \
    || warn "$dep não estabilizou"
done

# ── 9. smoke-test pelo NLB
banner "9/10  Smoke-test pelo Kong NLB"
NLB_HOST=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[ -n "$NLB_HOST" ] || { warn "NLB ainda não tem hostname; aguardando 60s…"; sleep 60; NLB_HOST=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'); }
ok "NLB Kong: http://${NLB_HOST}"

echo ""
echo "→ Aguardando NLB ficar accessible (até 3 min)…"
for _ in $(seq 1 36); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST \
    -H 'Content-Type: application/json' -d '{}' \
    "http://${NLB_HOST}/auth/login/admin" 2>/dev/null || echo "000")
  case "$code" in
    400|401) ok "NLB roteando OK (HTTP $code)"; break ;;
    *) printf "."; sleep 5 ;;
  esac
done

echo ""
echo "→ Login admin:"
curl -sS -X POST "http://${NLB_HOST}/auth/login/admin" \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@autoflow.com","password":"Admin@123"}' | head -c 200
echo ""

banner "✅ DEPLOY COMPLETO"
echo "  Kong NLB:        http://${NLB_HOST}"
echo "  Cluster:         $CLUSTER_NAME"
echo "  RDS:             $DB_HOST"
echo "  S3 tfstate:      $TFSTATE_BUCKET"
echo ""
echo "  kubectl get pods -n autoflow"
echo "  ./scripts/aws-lab-status.sh"
echo "  ./scripts/aws-lab-teardown.sh"
