#!/usr/bin/env bash
# Destroi e recria o cluster kind. Use --no-build para reusar imagens.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  $*${NC}"
  echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
}

START=$(date +%s)

banner "RESET 1/2 — DERRUBANDO TUDO"
"$SCRIPT_DIR/teardown.sh"

banner "RESET 2/2 — SUBINDO TUDO"
"$SCRIPT_DIR/bootstrap.sh" "$@"

# Mock MP guarda estado em memória — com 2 replicas o webhook cai em pod
# diferente do que recebeu /mock/approve. HPA precisa ser pinado para
# não fazer scale-up automático.
echo ""
echo -e "${YELLOW}→ payment-service em 1 replica fixa${NC}"
kubectl patch hpa payment-service -n autoflow --type=merge \
  -p '{"spec":{"minReplicas":1,"maxReplicas":1}}' >/dev/null
kubectl scale deploy payment-service --replicas=1 -n autoflow >/dev/null
kubectl rollout status deploy/payment-service -n autoflow --timeout 60s >/dev/null
echo -e "${GREEN}   ✓ payment-service em 1 replica${NC}"

# Kong Ingress Controller demora alguns segundos para sincronizar Services
# após o cluster subir; até lá, /auth/* responde 503 ring-balancer.
echo ""
echo -e "${YELLOW}→ Aguardando Kong rotear para identity-service…${NC}"
KONG_OK=false
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -d '{}' \
    http://localhost:8080/auth/login/admin 2>/dev/null || true)
  if [ "$code" = "400" ] || [ "$code" = "401" ]; then
    KONG_OK=true
    break
  fi
  sleep 2
done
if [ "$KONG_OK" = true ]; then
  echo -e "${GREEN}   ✓ Kong roteando OK${NC}"
else
  echo -e "${YELLOW}   ⚠ Kong ainda não estabilizou; happy-path pode retentar${NC}"
fi

END=$(date +%s)
banner "✅ RESET COMPLETO em $((END-START))s"
echo ""
echo "Próximos passos:"
echo "  ./happy-path.sh"
echo "  ./bad-path-stock.sh"
echo "  ./bad-path-payment.sh"
