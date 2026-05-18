#!/usr/bin/env bash
# Cria os 4 databases e 4 users (um por microsserviço Postgres) no RDS shared.
# Cada user só enxerga seu próprio database (isolation lógico).
#
# Pré-requisitos:
#   - terraform apply do stack 02-database-rds completou
#   - psql instalado
#   - você está em uma máquina que tem acesso ao RDS (bastion ou kubectl port-forward)
#
# Como rodar:
#   cd autoflow-infra/02-database-rds
#   ./scripts/init-databases.sh
#
# Para acessar o RDS de fora do VPC, use kubectl port-forward via um pod:
#   kubectl run psql --rm -it --image=postgres:16-alpine --restart=Never -- psql ...

set -euo pipefail

cd "$(dirname "$0")/.."

# Lê outputs do terraform
DB_HOST=$(terraform output -raw db_address)
DB_PORT=$(terraform output -raw db_port)
DB_MASTER_USER=$(terraform output -raw db_master_username)
DB_MASTER_PASS=$(terraform output -raw db_master_password)

# Lista de databases e seus users (deve bater com var.service_databases)
declare -A SERVICES=(
  ["identity"]="identity_user"
  ["order"]="order_user"
  ["saga"]="saga_user"
  ["payment"]="payment_user"
)

# Lê credenciais geradas pelo terraform
CREDS_JSON=$(terraform output -json service_credentials)

echo "Bootstrapping databases on ${DB_HOST}:${DB_PORT}…"

for db_name in "${!SERVICES[@]}"; do
  user="${SERVICES[$db_name]}"
  password=$(echo "$CREDS_JSON" | jq -r ".${db_name}.password")

  echo ""
  echo "→ ${db_name} / ${user}"

  # 1) cria database (se ainda não existe)
  PGPASSWORD="$DB_MASTER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_MASTER_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'" \
    | grep -q 1 || PGPASSWORD="$DB_MASTER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" \
        -U "$DB_MASTER_USER" -d postgres -c "CREATE DATABASE ${db_name};"

  # 2) cria/atualiza user
  PGPASSWORD="$DB_MASTER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${user}') THEN
    CREATE ROLE ${user} LOGIN PASSWORD '${password}';
  ELSE
    ALTER ROLE ${user} WITH LOGIN PASSWORD '${password}';
  END IF;
END
\$\$;
SQL

  # 3) revoga acesso público e dá ownership ao user
  PGPASSWORD="$DB_MASTER_PASS" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_MASTER_USER" -d postgres <<SQL
REVOKE ALL ON DATABASE ${db_name} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${user};
ALTER DATABASE ${db_name} OWNER TO ${user};
SQL

  echo "   ✓ ${db_name} ready (owner=${user})"
done

echo ""
echo "Done. Each service must connect with its own user — no cross-database access allowed."
