#!/usr/bin/env bash
# Carrega creds AWS do .env, valida via STS, garante bucket S3 do tfstate.
# Pode ser sourced (. ./aws-lab-login.sh) para popular o shell atual.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

[ -f "$ENV_FILE" ] || { echo "✗ .env não encontrado em $ENV_FILE" >&2; return 1 2>/dev/null || exit 1; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID não definido no .env}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY não definido no .env}"
: "${AWS_SESSION_TOKEN:?AWS_SESSION_TOKEN não definido no .env}"
: "${AWS_REGION:=us-east-1}"

echo "→ Validando credenciais AWS…"
caller=$(aws sts get-caller-identity --output json 2>&1) || {
  echo "✗ AWS rejeitou as credenciais" >&2
  echo "$caller" >&2
  return 2 2>/dev/null || exit 2
}

ACCOUNT_ID=$(echo "$caller" | python3 -c "import json,sys;print(json.load(sys.stdin)['Account'])")
USER_ARN=$(echo "$caller" | python3 -c "import json,sys;print(json.load(sys.stdin)['Arn'])")
TFSTATE_BUCKET="autoflow-tfstate-${ACCOUNT_ID}"

echo "   ✓ Account: ${ACCOUNT_ID}"
echo "   ✓ ARN:     ${USER_ARN}"
echo "   ✓ Region:  ${AWS_REGION}"

# Bucket S3 para tfstate (criado uma vez por account)
if aws s3api head-bucket --bucket "$TFSTATE_BUCKET" 2>/dev/null; then
  echo "   ✓ S3 tfstate bucket existe: ${TFSTATE_BUCKET}"
else
  echo "→ Criando S3 bucket ${TFSTATE_BUCKET}…"
  aws s3api create-bucket --bucket "$TFSTATE_BUCKET" --region "$AWS_REGION" >/dev/null
  aws s3api put-bucket-versioning --bucket "$TFSTATE_BUCKET" \
    --versioning-configuration Status=Enabled >/dev/null
  aws s3api put-bucket-encryption --bucket "$TFSTATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' >/dev/null
  echo "   ✓ Bucket criado com versioning + SSE-AES256"
fi

export TFSTATE_BUCKET ACCOUNT_ID
echo "   exportado: TFSTATE_BUCKET=$TFSTATE_BUCKET ACCOUNT_ID=$ACCOUNT_ID"
