#!/usr/bin/env bash
# smoke-test.sh — Happy path E2E rodando contra o cluster kind local.
# Bate em http://localhost:8080 (Kong) e exercita todos os 6 microsserviços.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verifica que o Kong está respondendo
if ! curl -s --max-time 3 -o /dev/null http://localhost:8080/health; then
  echo "❌ Kong não responde em http://localhost:8080. Rode ./bootstrap.sh primeiro." >&2
  exit 1
fi

exec python3 "$SCRIPT_DIR/smoke-test.py"
