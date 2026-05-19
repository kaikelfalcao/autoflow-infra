#!/usr/bin/env bash
# Sobe cada KEY=VALUE do .env como SecureString em /autoflow/<env>/<KEY>
# no AWS SSM Parameter Store. Use --list / --delete / --dry-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

ENV_NAME="dev"
DRY_RUN=false
LIST_ONLY=false
DELETE_ONLY=false

while [ $# -gt 0 ]; do
  case "$1" in
    --env)      ENV_NAME="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=true; shift ;;
    --list)     LIST_ONLY=true; shift ;;
    --delete)   DELETE_ONLY=true; shift ;;
    -h|--help)
      sed -n '1,4p' "$0"; echo "Flags: --env <name> | --dry-run | --list | --delete"; exit 0 ;;
    *) echo "arg desconhecido: $1" >&2; exit 1 ;;
  esac
done

PREFIX="/autoflow/$ENV_NAME"

command -v aws >/dev/null 2>&1 || { echo "✗ aws cli não encontrado" >&2; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || {
  echo "✗ aws cli não autenticado (rode 'aws configure' ou 'aws sso login')" >&2
  exit 1
}

if [ "$LIST_ONLY" = true ]; then
  echo "→ Listando parâmetros em $PREFIX/*"
  aws ssm get-parameters-by-path \
    --path "$PREFIX/" --recursive --with-decryption \
    --query 'Parameters[].[Name,Type,LastModifiedDate]' --output table
  exit 0
fi

if [ "$DELETE_ONLY" = true ]; then
  echo "→ Apagando TODOS os parâmetros em $PREFIX/*"
  names=$(aws ssm get-parameters-by-path \
    --path "$PREFIX/" --recursive \
    --query 'Parameters[].Name' --output text)
  if [ -z "$names" ]; then
    echo "  (nenhum parâmetro encontrado)"; exit 0
  fi
  for n in $names; do
    if [ "$DRY_RUN" = true ]; then
      echo "  [dry-run] aws ssm delete-parameter --name $n"
    else
      aws ssm delete-parameter --name "$n" >/dev/null && echo "  ✓ deletado $n"
    fi
  done
  exit 0
fi

[ -f "$ENV_FILE" ] || { echo "✗ .env não encontrado em $ENV_FILE" >&2; exit 1; }

echo "→ Sincronizando $ENV_FILE → SSM $PREFIX/*"
[ "$DRY_RUN" = true ] && echo "  (dry-run — nada será aplicado)"
echo ""

CREATED=0
UPDATED=0
SKIPPED=0

# Lê o .env linha a linha (ignora comentários e linhas vazias)
while IFS= read -r line || [ -n "$line" ]; do
  # Trim, ignora comentários e linhas vazias
  line="${line%$'\r'}"
  case "$line" in ''|\#*) continue ;; esac
  # Espera KEY=VALUE
  key="${line%%=*}"
  value="${line#*=}"
  # Remove aspas simples ou duplas envolventes do valor
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  if [ -z "$value" ]; then
    echo "  · pulando $key (valor vazio)"
    SKIPPED=$((SKIPPED+1))
    continue
  fi

  param_name="$PREFIX/$key"

  if [ "$DRY_RUN" = true ]; then
    echo "  [dry-run] put $param_name (SecureString)"
    continue
  fi

  # Verifica se já existe
  existing=$(aws ssm get-parameter --name "$param_name" --with-decryption \
    --query 'Parameter.Value' --output text 2>/dev/null || true)

  if [ -n "$existing" ]; then
    if [ "$existing" = "$value" ]; then
      echo "  · $key (sem mudança)"
      SKIPPED=$((SKIPPED+1))
      continue
    fi
    aws ssm put-parameter \
      --name "$param_name" --value "$value" --type SecureString \
      --overwrite >/dev/null
    echo "  ↻ $key (atualizado)"
    UPDATED=$((UPDATED+1))
  else
    aws ssm put-parameter \
      --name "$param_name" --value "$value" --type SecureString \
      --tier Standard >/dev/null
    echo "  + $key (criado)"
    CREATED=$((CREATED+1))
  fi
done < "$ENV_FILE"

echo ""
echo "✓ Sync completo: $CREATED criados, $UPDATED atualizados, $SKIPPED pulados"
