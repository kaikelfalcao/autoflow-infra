#!/usr/bin/env bash
# bootstrap.sh — sobe o ecossistema autoflow completo num cluster kind local.
#
# Idempotente: pode ser rodado várias vezes. Se o cluster já existe, reusa.
# Se as imagens já foram construídas, reusa (--no-build pula).
#
# Uso:
#   ./bootstrap.sh                  # full setup
#   ./bootstrap.sh --no-build       # pula docker build (usa imagens existentes)
#   ./bootstrap.sh --rebuild <svc>  # rebuild só de um serviço (ex: identity)
#
# Pré-requisitos:
#   - docker
#   - kind   (https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
#   - kubectl
#   - helm
#
# Tempo médio: ~5 min do zero, ~30s reaplicando.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_NAME="autoflow"
NAMESPACE="autoflow"
KONG_NAMESPACE="kong"

# Imagens locais — tag :local para distinguir das de produção
declare -A SERVICES=(
  ["identity"]="identity-service"
  ["order"]="autoflow-order-service"
  ["saga"]="autoflow-saga-orchestrator"
  ["catalog"]="autoflow-catalog-service"
  ["payment"]="autoflow-payment-service"
  ["notification"]="autoflow-notification-service"
)

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*" >&2; }

# ── Parse args
NO_BUILD=false
REBUILD_SERVICE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-build) NO_BUILD=true; shift ;;
    --rebuild) REBUILD_SERVICE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^set/p' "$0" | head -n 20; exit 0 ;;
    *) err "unknown arg: $1"; exit 1 ;;
  esac
done

# ── 1. Pré-requisitos
log "1/9  Verificando pré-requisitos…"
for cmd in docker kind kubectl helm envsubst; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    err "$cmd não encontrado. Instale antes de continuar."
    case $cmd in
      kind)     echo "       brew install kind  OR  go install sigs.k8s.io/kind@latest" ;;
      helm)     echo "       brew install helm  OR  https://helm.sh/docs/intro/install/" ;;
      envsubst) echo "       apt install gettext-base  OR  brew install gettext" ;;
    esac
    exit 1
  fi
done
docker info >/dev/null 2>&1 || { err "Docker não está rodando"; exit 1; }
ok "docker, kind, kubectl, helm, envsubst OK"

ENV_FILE="$ROOT_DIR/autoflow-infra/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  : "${NEW_RELIC_ENABLED:=true}"
  ok ".env carregado (NEW_RELIC_ENABLED=$NEW_RELIC_ENABLED)"
else
  warn ".env não encontrado em $ENV_FILE — observability desligada"
  warn "Para ativar: cp $ROOT_DIR/autoflow-infra/.env.example $ENV_FILE e preencha"
  export NEW_RELIC_ENABLED="false"
  export NEW_RELIC_LICENSE_KEY=""
fi
export NEW_RELIC_ENABLED NEW_RELIC_LICENSE_KEY

# ── 2. Cluster kind
log "2/9  Garantindo cluster kind '$CLUSTER_NAME'…"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  ok "Cluster já existe (reusando)"
else
  kind create cluster --config "$SCRIPT_DIR/kind-config.yaml"
  ok "Cluster criado"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null

# ── 3. Namespace
log "3/9  Criando namespace '$NAMESPACE'…"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "namespace pronto"

# ── 4. Kong via Helm
log "4/9  Instalando Kong (DB-less + Ingress Controller)…"
helm repo add kong https://charts.konghq.com >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace "$KONG_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm upgrade --install kong kong/kong \
  --namespace "$KONG_NAMESPACE" \
  --version 2.38.0 \
  --set proxy.type=NodePort \
  --set proxy.http.nodePort=30080 \
  --set admin.enabled=true \
  --set env.database=off \
  --set ingressController.enabled=true \
  --set ingressController.installCRDs=false \
  --wait --timeout 5m >/dev/null
ok "Kong instalado e rodando"

# ── 5. Infra dependencies (Postgres, MongoDB×2, RabbitMQ)
log "5/9  Subindo infra (Postgres + MongoDB×2 + RabbitMQ)…"
kubectl apply -f "$SCRIPT_DIR/manifests/00-postgres.yaml" >/dev/null
kubectl apply -f "$ROOT_DIR/autoflow-infra/03-k8s-shared/01-mongodb-catalog.yaml" >/dev/null
kubectl apply -f "$ROOT_DIR/autoflow-infra/03-k8s-shared/02-mongodb-notification.yaml" >/dev/null
kubectl apply -f "$ROOT_DIR/autoflow-infra/03-k8s-shared/03-rabbitmq.yaml" >/dev/null
# 10-secrets.yaml aplica DEPOIS dos shared manifests para sobrescrever os
# placeholders REPLACE_ME_VIA_KUBECTL com as credenciais de dev.
envsubst '${NEW_RELIC_LICENSE_KEY} ${NEW_RELIC_ENABLED}' \
  < "$SCRIPT_DIR/manifests/10-secrets.yaml" | kubectl apply -f - >/dev/null
kubectl apply -f "$SCRIPT_DIR/manifests/21-rabbitmq-nodeport.yaml" >/dev/null

log "     Aguardando StatefulSets ficarem prontos (até 3 min)…"
for ss in postgres mongodb-catalog mongodb-notification rabbitmq; do
  kubectl rollout status statefulset/$ss -n "$NAMESPACE" --timeout 180s >/dev/null
  ok "$ss ready"
done

# ── 6. Build das imagens Docker
if [ "$NO_BUILD" = false ]; then
  log "6/9  Building imagens Docker…"
  for key in "${!SERVICES[@]}"; do
    svc_dir="${SERVICES[$key]}"
    if [ -n "$REBUILD_SERVICE" ] && [ "$REBUILD_SERVICE" != "$key" ]; then
      continue
    fi
    log "     → kaikelfalcao/autoflow-${key}:local"
    docker build -q \
      -t "kaikelfalcao/autoflow-${key}:local" \
      "$ROOT_DIR/$svc_dir" >/dev/null
    ok "imagem autoflow-${key} built"
  done
else
  log "6/9  Pulando build (--no-build)"
fi

# ── 7. Load das imagens no kind
log "7/9  Carregando imagens no cluster kind…"
for key in "${!SERVICES[@]}"; do
  if [ -n "$REBUILD_SERVICE" ] && [ "$REBUILD_SERVICE" != "$key" ]; then
    continue
  fi
  kind load docker-image "kaikelfalcao/autoflow-${key}:local" --name "$CLUSTER_NAME" >/dev/null 2>&1
  ok "autoflow-${key}:local loaded"
done

# ── 8. Deploy dos microsserviços
log "8/9  Aplicando manifests dos microsserviços…"

apply_service() {
  local key=$1
  local dir=$2
  # Substitui :latest por :local nos manifests temporariamente via sed.
  # Idempotente: aplica e deixa Kubernetes resolver diff.
  for f in deployment.yaml service.yaml hpa.yaml; do
    [ -f "$ROOT_DIR/$dir/k8s/$f" ] || continue
    local extra_sed=""
    # Mock MP guarda state em Map in-memory — force 1 replica para dev.
    if [ "$key" = "payment" ]; then
      if [ "$f" = "deployment.yaml" ]; then
        extra_sed="s|^  replicas:.*$|  replicas: 1|"
      elif [ "$f" = "hpa.yaml" ]; then
        extra_sed="s|^  minReplicas:.*$|  minReplicas: 1|; s|^  maxReplicas:.*$|  maxReplicas: 1|"
      fi
    fi
    sed "s|kaikelfalcao/autoflow-${key}:latest|kaikelfalcao/autoflow-${key}:local|g; s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g; ${extra_sed}" \
      "$ROOT_DIR/$dir/k8s/$f" | kubectl apply -f - >/dev/null
  done
}

for key in "${!SERVICES[@]}"; do
  apply_service "$key" "${SERVICES[$key]}"
  ok "$key deployed"
done

# Ingress routes
kubectl apply -f "$ROOT_DIR/autoflow-infra/03-k8s-shared/04-kong-routes.yaml" >/dev/null
ok "Kong routes aplicadas"

# ── 9. Migrations + seed
log "9/9  Rodando migration jobs…"
for key in identity order saga payment; do
  dir="${SERVICES[$key]}"
  job_file="$ROOT_DIR/$dir/k8s/migration-job.yaml"
  [ -f "$job_file" ] || continue
  # delete + apply para garantir job novo
  kubectl delete job "${key}-migration" -n "$NAMESPACE" --ignore-not-found >/dev/null
  sed "s|kaikelfalcao/autoflow-${key}:latest|kaikelfalcao/autoflow-${key}:local|g; s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" \
    "$job_file" | kubectl apply -f - >/dev/null
done
# Aguarda migrations
for key in identity order saga payment; do
  if kubectl wait --for=condition=complete --timeout 120s job/${key}-migration -n "$NAMESPACE" >/dev/null 2>&1; then
    ok "migration $key OK"
  else
    warn "migration $key falhou — ver: kubectl logs job/${key}-migration -n $NAMESPACE"
  fi
done

# Seed admin
log "     Rodando seed admin…"
kubectl delete job identity-seed-admin -n "$NAMESPACE" --ignore-not-found >/dev/null
sed "s|kaikelfalcao/autoflow-identity:latest|kaikelfalcao/autoflow-identity:local|g; s|imagePullPolicy: Always|imagePullPolicy: IfNotPresent|g" \
  "$ROOT_DIR/identity-service/k8s/seed-job.yaml" | kubectl apply -f - >/dev/null
if kubectl wait --for=condition=complete --timeout 60s job/identity-seed-admin -n "$NAMESPACE" >/dev/null 2>&1; then
  ok "admin seed OK"
else
  warn "seed admin falhou — ver: kubectl logs job/identity-seed-admin -n $NAMESPACE"
fi

# Aguarda deployments
log "Aguardando todos os deployments ficarem prontos…"
for dep in identity-service order-service saga-orchestrator catalog-service payment-service notification-service; do
  kubectl rollout status deployment/$dep -n "$NAMESPACE" --timeout 120s >/dev/null && ok "$dep ready" || warn "$dep ainda subindo"
done

# ── Resultado final
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   ✅ autoflow rodando no kind${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
echo ""
echo "Endpoints (via Kong em http://localhost:8080):"
echo "  POST   /auth/login/admin                  → identity"
echo "  POST   /auth/login/customer               → identity"
echo "  GET    /auth/verify                       → identity"
echo "  GET    /orders                            → order"
echo "  POST   /customers                         → order"
echo "  POST   /vehicles                          → order"
echo "  POST   /parts                             → catalog"
echo "  GET    /billing/charges/order/:id         → payment"
echo "  POST   /billing/webhook/mercadopago       → payment"
echo ""
echo "RabbitMQ Management:  http://localhost:15672  (admin/admin)"
echo ""
echo "Comandos úteis:"
echo "  kubectl get pods -n autoflow"
echo "  kubectl logs -f deploy/order-service -n autoflow"
echo "  ./smoke-test.sh                # roda happy path E2E"
echo "  ./teardown.sh                  # destroi cluster"
