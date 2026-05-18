#!/usr/bin/env bash
# Propaga secrets (DockerHub, AWS Lab, New Relic) para os 7 repos do ecossistema
# autoflow via `gh secret set`. Lê valores de um arquivo .env (default: .env na
# raiz de autoflow-infra). Use o template `.env.secrets.example` como base.
#
# Uso:
#   scripts/sync-github-secrets.sh                  # lê ./.env
#   scripts/sync-github-secrets.sh ../algum.env     # path custom
#   ENV_FILE=path ./scripts/sync-github-secrets.sh  # via env var
#
# Pré-requisitos:
#   - gh CLI autenticado (`gh auth status`)
#   - permissão de admin nos 7 repos

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_FILE="${1:-${ENV_FILE:-$INFRA_DIR/.env}}"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ ENV_FILE não encontrado: $ENV_FILE"
  echo "  Copie .env.secrets.example, preencha os valores e tente de novo."
  exit 1
fi

# Lista de secrets a propagar (chaves que serão buscadas no ENV_FILE)
SECRETS=(
  DOCKER_USERNAME
  DOCKER_PASSWORD
  AWS_ACCESS_KEY_ID
  AWS_SECRET_ACCESS_KEY
  AWS_SESSION_TOKEN
  NEW_RELIC_LICENSE_KEY
)

REPOS=(
  autoflow-identity-service
  autoflow-order-service
  autoflow-saga-orchestrator
  autoflow-catalog-service
  autoflow-payment-service
  autoflow-notification-service
  autoflow-infra
)

OWNER="${OWNER:-kaikelfalcao}"

# Carrega variáveis do ENV_FILE no shell sem expô-las no histórico
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# Valida que todas as secrets existem e não estão vazias
missing=()
for s in "${SECRETS[@]}"; do
  if [ -z "${!s:-}" ]; then
    missing+=("$s")
  fi
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "✗ Variáveis ausentes/vazias em $ENV_FILE: ${missing[*]}"
  exit 1
fi

# Confere autenticação gh
if ! gh auth status >/dev/null 2>&1; then
  echo "✗ gh CLI não autenticado. Rode: gh auth login"
  exit 1
fi

echo "═══ propagando ${#SECRETS[@]} secrets para ${#REPOS[@]} repos ═══"
echo "  origem: $ENV_FILE"
echo "  owner:  $OWNER"
echo ""

for repo in "${REPOS[@]}"; do
  echo "  ▸ $repo"
  for s in "${SECRETS[@]}"; do
    if printf '%s' "${!s}" | gh secret set "$s" --repo "$OWNER/$repo" --body - >/dev/null 2>&1; then
      printf '      ✓ %s\n' "$s"
    else
      printf '      ✗ %s (falha — repo público/private + permissão)\n' "$s"
    fi
  done
done

echo ""
echo "✓ sync concluído. Verifique em:"
for repo in "${REPOS[@]}"; do
  echo "  https://github.com/$OWNER/$repo/settings/secrets/actions"
done
