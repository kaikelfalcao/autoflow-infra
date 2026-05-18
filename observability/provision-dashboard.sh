#!/usr/bin/env bash
# Provisiona o dashboard Autoflow no NerdGraph.
# Uso: ./provision-dashboard.sh [--guid <GUID>]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ .env não encontrado em $ENV_FILE — copie .env.example e preencha" >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${NEW_RELIC_API_KEY:?NEW_RELIC_API_KEY não definido no .env}"
: "${NEW_RELIC_ACCOUNT_ID:?NEW_RELIC_ACCOUNT_ID não definido no .env}"
NEW_RELIC_REGION="${NEW_RELIC_REGION:-US}"

case "$NEW_RELIC_REGION" in
  EU|eu) ENDPOINT="https://api.eu.newrelic.com/graphql" ;;
  *)     ENDPOINT="https://api.newrelic.com/graphql" ;;
esac

UPDATE_GUID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --guid) UPDATE_GUID="$2"; shift 2 ;;
    *) echo "arg desconhecido: $1" >&2; exit 1 ;;
  esac
done

export ENDPOINT NEW_RELIC_API_KEY NEW_RELIC_ACCOUNT_ID UPDATE_GUID SCRIPT_DIR

exec python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

endpoint   = os.environ['ENDPOINT']
api_key    = os.environ['NEW_RELIC_API_KEY']
account_id = int(os.environ['NEW_RELIC_ACCOUNT_ID'])
guid       = os.environ.get('UPDATE_GUID') or None
script_dir = os.environ['SCRIPT_DIR']

with open(os.path.join(script_dir, 'dashboard.json'), 'r') as f:
    raw = f.read()

dashboard = json.loads(raw.replace('__ACCOUNT_ID__', str(account_id)))

if guid:
    mutation = """
    mutation($guid: EntityGuid!, $dashboard: DashboardInput!) {
      dashboardUpdate(guid: $guid, dashboard: $dashboard) {
        entityResult { guid name }
        errors { description type }
      }
    }
    """
    variables = {'guid': guid, 'dashboard': dashboard}
    op_name = 'dashboardUpdate'
else:
    mutation = """
    mutation($accountId: Int!, $dashboard: DashboardInput!) {
      dashboardCreate(accountId: $accountId, dashboard: $dashboard) {
        entityResult { guid name }
        errors { description type }
      }
    }
    """
    variables = {'accountId': account_id, 'dashboard': dashboard}
    op_name = 'dashboardCreate'

payload = json.dumps({'query': mutation, 'variables': variables}).encode()

print(f"→ POST {endpoint} ({op_name})")
req = urllib.request.Request(
    endpoint,
    data=payload,
    method='POST',
    headers={'Content-Type': 'application/json', 'API-Key': api_key},
)
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.loads(r.read().decode())
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"HTTP {e.code}: {body}", file=sys.stderr)
    sys.exit(2)

print(json.dumps(resp, indent=2, ensure_ascii=False))

result = (resp.get('data') or {}).get(op_name) or {}
errors = result.get('errors') or []
entity = result.get('entityResult') or {}
top_errors = resp.get('errors') or []

if top_errors:
    print(f"\n✗ GraphQL retornou erros de topo:", file=sys.stderr)
    for e in top_errors:
        print(f"  - {e.get('message')}", file=sys.stderr)
    sys.exit(3)
if errors:
    print(f"\n✗ Dashboard mutation reportou erros:", file=sys.stderr)
    for e in errors:
        print(f"  - [{e.get('type')}] {e.get('description')}", file=sys.stderr)
    sys.exit(4)
if not entity.get('guid'):
    print(f"\n✗ Dashboard mutation não retornou guid", file=sys.stderr)
    sys.exit(5)

print(f"\n✓ Dashboard pronto")
print(f"  Nome:  {entity.get('name')}")
print(f"  GUID:  {entity.get('guid')}")
region = os.environ.get('NEW_RELIC_REGION', 'US').lower()
host = 'one.eu.newrelic.com' if region == 'eu' else 'one.newrelic.com'
print(f"  URL:   https://{host}/dashboards?account={account_id}")
print(f"\nPara atualizar este dashboard depois sem criar novo:")
print(f"  $0 --guid {entity.get('guid')}")
PY
