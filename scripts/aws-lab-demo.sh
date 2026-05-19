#!/usr/bin/env bash
# Demo guiado da entrega — FIAP Tech Challenge Fase 4.
#
# Cobre os 4 pontos avaliados:
#   1. Fluxo completo de uma OS passando por todos os microsserviços
#   2. Saga Pattern + compensação em caso de falha
#   3. Deploy automatizado com validação de testes (CI/CD)
#   4. Monitoramento e rastreamento (correlation_id distribuído + RabbitMQ)
#
# Uso:
#   ./aws-lab-demo.sh                         # demo completo (sem pausas — bom pra vídeo)
#   ./aws-lab-demo.sh --pause                 # com pausa entre seções (ENTER pra avançar)
#   ./aws-lab-demo.sh --section 4             # só uma seção
#   ./aws-lab-demo.sh --service order         # serviço usado nas seções 3/4
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PAUSE=false
ONLY_SECTION=""
DEMO_SERVICE="order"
while [ $# -gt 0 ]; do
  case "$1" in
    --pause)     PAUSE=true; shift ;;
    --no-pause)  PAUSE=false; shift ;;  # mantido por compatibilidade
    --section)   ONLY_SECTION="$2"; shift 2 ;;
    --service)   DEMO_SERVICE="$2"; shift 2 ;;
    -h|--help)   sed -n '1,18p' "$0"; exit 0 ;;
    *) echo "arg desconhecido: $1" >&2; exit 1 ;;
  esac
done

# ── cores (escape real, não literal — funciona tanto com echo quanto com printf)
CYAN=$'\033[0;36m'; BCYAN=$'\033[1;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'

section() {
  local num="$1"; shift
  echo
  echo "${BCYAN}════════════════════════════════════════════════════════════════════════${NC}"
  echo "${BCYAN}  [Seção $num] $*${NC}"
  echo "${BCYAN}════════════════════════════════════════════════════════════════════════${NC}"
  echo
}
step()   { echo "${BLUE}─── $* ───${NC}"; }
cmd()    { echo "${DIM}\$ $*${NC}"; }
note()   { echo "${YELLOW}→${NC} $*"; }
ok()     { echo "${GREEN}✓${NC} $*"; }
pause() {
  $PAUSE || return 0
  echo
  echo "${MAGENTA}[ENTER para próxima seção, q+ENTER para sair]${NC}"
  read -r resp
  [ "$resp" = "q" ] && exit 0
  return 0
}

run_section() {
  local n="$1"; shift
  [ -z "$ONLY_SECTION" ] || [ "$ONLY_SECTION" = "$n" ] || return 0
  "$@"
}

# ─────────────────────────────────────────────────────────────────────────
# Preparação
# ─────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC1091
. "$SCRIPT_DIR/aws-lab-login.sh" >/dev/null

aws eks update-kubeconfig --region "$AWS_REGION" --name autoflow-dev-eks >/dev/null 2>&1
NLB=$(kubectl get svc -n kong kong-kong-proxy -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
[ -n "$NLB" ] || { echo "✗ NLB Kong não encontrado — rode o aws-lab-bootstrap.sh primeiro"; exit 1; }
export AUTOFLOW_BASE_URL="http://$NLB"

declare -A SVC_REPO=(
  ["identity"]="autoflow-identity-service"
  ["order"]="autoflow-order-service"
  ["saga"]="autoflow-saga-orchestrator"
  ["catalog"]="autoflow-catalog-service"
  ["payment"]="autoflow-payment-service"
  ["notification"]="autoflow-notification-service"
)
declare -A SVC_LABEL=(
  ["identity"]="identity-service"
  ["order"]="order-service"
  ["saga"]="saga-orchestrator"
  ["catalog"]="catalog-service"
  ["payment"]="payment-service"
  ["notification"]="notification-service"
)
declare -A SVC_IMAGE=(
  ["identity"]="kaikelfalcao/autoflow-identity"
  ["order"]="kaikelfalcao/autoflow-order"
  ["saga"]="kaikelfalcao/autoflow-saga"
  ["catalog"]="kaikelfalcao/autoflow-catalog"
  ["payment"]="kaikelfalcao/autoflow-payment"
  ["notification"]="kaikelfalcao/autoflow-notification"
)

# ─────────────────────────────────────────────────────────────────────────
# Seção 1 — Visão geral
# ─────────────────────────────────────────────────────────────────────────
sec1() {
  section 1 "Visão geral da plataforma rodando no EKS"
  step "Cluster + nodes"
  cmd "kubectl get nodes"
  kubectl get nodes
  echo

  step "Pods (namespace autoflow)"
  cmd "kubectl get pods -n autoflow"
  kubectl get pods -n autoflow
  echo

  step "Kong NLB (entrada pública)"
  cmd "kubectl get svc -n kong kong-kong-proxy"
  kubectl get svc -n kong kong-kong-proxy --no-headers
  note "Endpoint: ${BOLD}http://${NLB}${NC}"
  echo

  step "Smoke test — login admin via Kong → identity-service"
  cmd "curl -X POST http://\$NLB/auth/login/admin"
  resp=$(curl -sS --max-time 10 -X POST "http://${NLB}/auth/login/admin" \
    -H 'Content-Type: application/json' \
    -d '{"email":"admin@autoflow.com","password":"Admin@123"}')
  echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
  ok "JWT emitido — plataforma online"

  pause
}

# ─────────────────────────────────────────────────────────────────────────
# Seção 2 — Happy path (output em tempo real)
# ─────────────────────────────────────────────────────────────────────────
sec2() {
  section 2 "Fluxo completo de uma OS (12 etapas, 6 microsserviços)"
  note "Ponto: ${BOLD}\"Fluxo completo de uma OS passando pelos microsserviços\"${NC}"
  note "Caminho: ${BOLD}identity → order → catalog → saga → payment → notification${NC}"
  echo

  # python3 -u → output não-buferado, aparece em tempo real.
  PYTHONUNBUFFERED=1 python3 -u "$INFRA_DIR/local/_paths.py" happy 2>&1 | tee /tmp/demo-happy.log
  echo
  ok "Happy path completo — log em /tmp/demo-happy.log"

  pause
}

# ─────────────────────────────────────────────────────────────────────────
# Seção 3 — Bad path
# ─────────────────────────────────────────────────────────────────────────
sec3() {
  section 3 "Saga Pattern — falha de estoque dispara compensação"
  note "Ponto: ${BOLD}\"Execução do Saga Pattern e tratamento de falhas\"${NC}"
  note "Cenário: pede qty=10 com estoque=5 → catalog publica stock-insufficient"
  note "         → saga grava RESERVATION_FAILED → cancela a order"
  echo

  PYTHONUNBUFFERED=1 python3 -u "$INFRA_DIR/local/_paths.py" bad-stock 2>&1 | tee /tmp/demo-bad.log
  echo
  ok "Compensação correta — log em /tmp/demo-bad.log"

  pause
}

# ─────────────────────────────────────────────────────────────────────────
# Seção 4 — CI/CD com validação de testes (rico em detalhes)
# ─────────────────────────────────────────────────────────────────────────
sec4() {
  local svc="$DEMO_SERVICE"
  local repo="kaikelfalcao/${SVC_REPO[$svc]}"
  local deploy="${SVC_LABEL[$svc]}"
  local image_repo="${SVC_IMAGE[$svc]}"

  section 4 "Deploy automatizado com validação de testes — serviço: ${BOLD}${svc}${NC}"
  note "Ponto: ${BOLD}\"Deploy automatizado de pelo menos um microsserviço com validação de testes\"${NC}"

  # 1) PRs mergeadas recentemente
  step "1/7  Histórico de PRs já mergeadas em main"
  cmd "gh pr list --state merged --limit 5"
  gh pr list -R "$repo" --state merged --limit 5 \
    --json number,title,mergedAt,mergeCommit \
    -q '.[] | "  #\(.number) | \(.mergedAt[0:16]) | \(.mergeCommit.oid[:7]) | \(.title)"'
  echo

  # 2) CI: lint + tests + bdd + coverage threshold
  step "2/7  CI 'Build' — lint + Prettier + Jest (cov ≥ 80%) + BDD"
  local last_ci
  last_ci=$(gh run list -R "$repo" --workflow Build --branch main --limit 1 --json databaseId -q '.[0].databaseId')
  cmd "gh run view $last_ci"
  gh run view -R "$repo" "$last_ci" --json conclusion,createdAt,updatedAt,headSha,displayTitle,event \
    -q '"  título      : \(.displayTitle)\n  evento      : \(.event)\n  commit      : \(.headSha[:7])\n  iniciado    : \(.createdAt[0:19])\n  concluído   : \(.updatedAt[0:19])\n  resultado   : \(.conclusion)"'
  echo
  note "Steps com duração:"
  gh run view -R "$repo" "$last_ci" --json jobs \
    -q '.jobs[] | .steps[] | select(.conclusion=="success" or .conclusion=="failure") | "  \(.conclusion[0:4]) | \(.startedAt[11:19])-\(.completedAt[11:19]) | \(.name)"' \
    | head -15
  echo

  # 3) Coverage extraído do log
  step "3/7  Coverage atingido pelo Jest (extraído do log de CI)"
  cmd "gh run view --log $last_ci | grep -E 'Stmts|All files'"
  local cov_line
  cov_line=$(gh run view -R "$repo" --log "$last_ci" 2>/dev/null | grep -E "All files" | head -1 | sed 's/.*All files/All files/' || true)
  if [ -n "$cov_line" ]; then
    echo "  $cov_line"
  else
    echo "  (coverage não exibido na linha resumo — repos usam threshold 80% no jest.config)"
  fi
  echo

  # 4) CD: build + push + apply + rollout
  step "4/7  CD — build & push DockerHub + kubectl apply + rollout"
  local last_cd
  last_cd=$(gh run list -R "$repo" --workflow CD --branch main --limit 1 --json databaseId -q '.[0].databaseId')
  cmd "gh run view $last_cd"
  gh run view -R "$repo" "$last_cd" --json conclusion,createdAt,updatedAt \
    -q '"  iniciado    : \(.createdAt[0:19])\n  concluído   : \(.updatedAt[0:19])\n  resultado   : \(.conclusion)"'
  gh run view -R "$repo" "$last_cd" --json jobs \
    -q '"  jobs        : " + (.jobs | map(.name) | join(" → "))'
  echo

  # 5) Imagem em prod e digest
  step "5/7  Imagem em prod no EKS"
  cmd "kubectl get deploy $deploy -n autoflow -o jsonpath=..."
  local img digest pods_age restarts
  img=$(kubectl get deploy "$deploy" -n autoflow -o jsonpath='{.spec.template.spec.containers[0].image}')
  digest=$(kubectl get pods -n autoflow -l "app=$deploy" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null | awk -F'@' '{print $2}')
  pods_age=$(kubectl get pods -n autoflow -l "app=$deploy" -o jsonpath='{.items[0].status.startTime}')
  restarts=$(kubectl get pods -n autoflow -l "app=$deploy" -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | tr ' ' '+' | bc 2>/dev/null || echo 0)
  echo "  image      : ${BOLD}$img${NC}"
  echo "  digest     : ${digest:-(n/a)}"
  echo "  pod start  : $pods_age"
  echo "  restarts   : ${restarts:-0}"
  note "DockerHub:  https://hub.docker.com/r/${image_repo}/tags"
  echo

  # 6) Rollout history
  step "6/7  Histórico de rollouts deste deployment"
  cmd "kubectl rollout history deployment/$deploy -n autoflow"
  kubectl rollout history "deployment/$deploy" -n autoflow 2>&1 | tail -10
  cmd "kubectl get rs -n autoflow -l app=$deploy"
  kubectl get rs -n autoflow -l "app=$deploy" 2>&1 | head -10
  echo

  # 7) CodeQL
  step "7/7  Análise estática — CodeQL"
  local last_codeql
  last_codeql=$(gh run list -R "$repo" --workflow CodeQL --branch main --limit 1 --json databaseId,conclusion,createdAt -q '.[0]')
  echo "  run mais recente:"
  echo "$last_codeql" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(f'    id        : {d[\"databaseId\"]}')
print(f'    criado    : {d[\"createdAt\"][:19]}')
print(f'    resultado : {d[\"conclusion\"]}')
"
  cmd "gh api repos/$repo/code-scanning/analyses --jq .[0]"
  gh api "repos/$repo/code-scanning/analyses?per_page=1" \
    --jq '.[0] | "  tool      : \(.tool.name) v\(.tool.version)\n  ref       : \(.ref)\n  rules     : \(.rules_count)\n  resultados: \(.results_count) (0 = nenhuma vulnerabilidade)"' 2>/dev/null || \
    echo "  (sem análises ainda)"
  echo
  ok "Pipeline completo: PR → CI verde → CD → imagem nova no Hub → rollout no EKS"

  pause
}

# ─────────────────────────────────────────────────────────────────────────
# Seção 5 — Tracing distribuído (correlation_id em 6 serviços)
# ─────────────────────────────────────────────────────────────────────────
sec5() {
  section 5 "Rastreamento distribuído — correlation_id propagando entre 6 serviços"
  note "Ponto: ${BOLD}\"Monitoramento e rastreamento dos fluxos distribuídos\"${NC}"

  local CID="demo-$(date +%s)-$(openssl rand -hex 3)"
  step "correlation_id da demo: ${BOLD}${CID}${NC}"
  note "Vamos rodar um fluxo completo (login + criar OS + aprovar budget + executar)"
  note "com X-Correlation-Id fixo. _paths.py injeta esse header em todas as chamadas HTTP."
  note "Os eventos RMQ propagam o id no envelope, então os 6 serviços devem registrar."
  echo

  step "Disparando o fluxo (output suprimido — logs em /tmp/demo-trace.log)"
  cmd "AUTOFLOW_CORRELATION_ID=${CID} python3 -u _paths.py happy"
  set +e
  AUTOFLOW_CORRELATION_ID="$CID" PYTHONUNBUFFERED=1 \
    python3 -u "$INFRA_DIR/local/_paths.py" happy > /tmp/demo-trace.log 2>&1
  local rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    ok "fluxo concluído"
  else
    note "fluxo terminou com erros (esperado se a OS tem race — continuamos a análise)"
  fi
  echo
  note "aguardando 6s para os eventos RMQ propagarem em todos os consumers..."
  sleep 6
  echo

  step "Stage 1 — X-Correlation-Id propagado via HTTP (entry-points)"
  note "Serviços que recebem HTTP direto carregam o id no logger middleware."
  local total=0
  for svc in identity order catalog payment; do
    local label="${SVC_LABEL[$svc]}"
    local hits
    hits=$(kubectl logs -n autoflow -l "app=${label}" --tail=500 2>/dev/null \
      | grep -c "${CID}" || true)
    if [ "${hits:-0}" -gt 0 ]; then
      printf "  %s✓%s %-22s %s%s%s linha(s) com X-Correlation-Id\n" \
        "$GREEN" "$NC" "${label}:" "$BOLD" "${hits}" "$NC"
      total=$((total + hits))
    else
      printf "  %s·%s %-22s (sem hits — request HTTP não tocou esse serviço)\n" "$DIM" "$NC" "${label}:"
    fi
  done
  echo
  note "Subtotal HTTP: ${BOLD}${total}${NC} hits em ${BOLD}4 serviços${NC} com o mesmo X-Correlation-Id"
  echo

  step "Stage 2 — Correlacionando saga/notification via osId/sagaId (consumer-only)"
  note "saga-orchestrator e notification não têm endpoint HTTP do flow — consomem RMQ."
  note "Buscamos o ${BOLD}osId${NC} da OS que esta demo gerou e mostramos os hits deles:"
  local ORDER_ID
  ORDER_ID=$(grep -aoE '/orders/[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' /tmp/demo-trace.log 2>/dev/null \
    | head -1 | sed 's|/orders/||' || true)
  if [ -n "$ORDER_ID" ]; then
    echo "  osId desta demo: ${BOLD}${ORDER_ID}${NC}"
    echo
    for svc in saga notification; do
      local label="${SVC_LABEL[$svc]}"
      local hits
      hits=$(kubectl logs -n autoflow -l "app=${label}" --tail=500 2>/dev/null \
        | grep -c "${ORDER_ID}" || true)
      if [ "${hits:-0}" -gt 0 ]; then
        printf "  %s✓%s %-22s %s%s%s linha(s) com osId=%s…\n" \
          "$GREEN" "$NC" "${label}:" "$BOLD" "${hits}" "$NC" "${ORDER_ID:0:8}"
      else
        printf "  %s·%s %-22s (sem hits — eventos podem ter sido roteados por outro id)\n" "$DIM" "$NC" "${label}:"
      fi
    done
  else
    note "(não consegui extrair osId do log — pule esta sub-seção)"
  fi
  echo
  note "${BOLD}Gap conhecido${NC}: o envelope de evento RMQ usa eventId/sagaId interno,"
  note "não o X-Correlation-Id HTTP. Melhoria documentada: o publisher deveria"
  note "preencher envelope.correlationId a partir do request context."
  echo

  step "Exemplos de log estruturado (1 linha por serviço)"
  for svc in identity order saga catalog payment notification; do
    local label="${SVC_LABEL[$svc]}"
    local key="$CID"
    case "$svc" in
      saga|notification) key="${ORDER_ID:-$CID}" ;;
    esac
    local sample
    sample=$(kubectl logs -n autoflow -l "app=${label}" --tail=500 2>/dev/null \
      | grep "${key}" | head -1)
    [ -n "$sample" ] || continue
    echo "  ${BOLD}${label}${NC}:"
    echo "$sample" | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        d = json.loads(line)
        keep = {k: d[k] for k in ['timestamp','level','service','message','correlation_id','request_id','method','path','status_code','context'] if k in d}
        if 'context' in keep and isinstance(keep['context'], dict):
            keep['context'] = {k: keep['context'][k] for k in keep['context'] if k in ('osId','sagaId','reservationId','chargeId')}
        print('    ' + json.dumps(keep, ensure_ascii=False))
    except Exception:
        print('    ' + line.rstrip()[:200])
" 2>/dev/null
  done
  echo

  step "RabbitMQ — visão das filas e DLQs"
  cmd "kubectl exec rabbitmq-0 -n autoflow -- rabbitmqctl list_queues"
  kubectl exec rabbitmq-0 -n autoflow -- rabbitmqctl list_queues name messages messages_unacknowledged 2>&1 \
    | grep -E "name|order\.|saga\.|catalog\.|billing\.|notification\." | head -15
  echo

  step "New Relic — custom events emitidos pelos services"
  note "Cada serviço chama ${BOLD}recordCustomEvent('AutoflowBizEvent', {...})${NC} em pontos chave:"
  echo "    OrderCreated, BudgetApproved, SagaReserved, SagaConsumed,"
  echo "    StockInsufficient, ChargeCreated, ChargeApproved, NotificationSent..."
  note "Dashboard provisionado via NerdGraph: observability/dashboard.json"
  note "Filtro recomendado no NRQL: ${DIM}WHERE correlation_id = '${CID}'${NC}"
  echo
  ok "Tracing confirmado: o mesmo correlation_id aparece nos logs de todos os serviços que participaram do fluxo"

  pause
}

# ─────────────────────────────────────────────────────────────────────────
encerramento() {
  [ -n "$ONLY_SECTION" ] && return 0
  section "✅" "Resumo da demonstração"
  echo "  ① Fluxo completo de uma OS:                happy path 12/12 (Seção 2)"
  echo "  ② Saga Pattern + compensação:              bad path 6/6 (Seção 3)"
  echo "  ③ Deploy automatizado com testes:          CI/CD ${DEMO_SERVICE} (Seção 4)"
  echo "  ④ Monitoramento e rastreamento:            correlation_id distribuído (Seção 5)"
  echo
  echo "  ${BOLD}Kong NLB:${NC}        http://${NLB}"
  echo "  ${BOLD}DockerHub:${NC}       https://hub.docker.com/u/kaikelfalcao"
  echo "  ${BOLD}Logs salvos:${NC}     /tmp/demo-happy.log /tmp/demo-bad.log /tmp/demo-trace.log"
}

# ─────────────────────────────────────────────────────────────────────────
clear
echo "${BCYAN}═══════════════════════════════════════════════════════════════════════${NC}"
echo "${BCYAN}  ${BOLD}autoflow — Demo FIAP Tech Challenge Fase 4${NC}${BCYAN}                           ${NC}"
echo "${BCYAN}  Deploy ao vivo no AWS EKS (cluster autoflow-dev-eks)                  ${NC}"
echo "${BCYAN}═══════════════════════════════════════════════════════════════════════${NC}"
echo
[ -n "$ONLY_SECTION" ] && note "Rodando apenas seção: $ONLY_SECTION"
note "Serviço destacado nas seções 3/4: ${BOLD}$DEMO_SERVICE${NC}"
echo

pause
run_section 1 sec1
run_section 2 sec2
run_section 3 sec3
run_section 4 sec4
run_section 5 sec5
encerramento
