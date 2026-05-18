# autoflow-infra

Infraestrutura completa do ecossistema **autoflow** (6 microsserviços + bancos +
broker + ingress) na AWS Academy.

## Arquitetura

```
                          Internet
                              │
                       ┌──────┴──────┐
                       │   Kong NLB  │  (LoadBalancer público)
                       └──────┬──────┘
                              │
        ┌─────────────────────┼──────────────────────────┐
        │                     │                          │
        ▼                     ▼                          ▼
   identity-svc          order-svc                 catalog-svc
   :3000  /auth/*        :3001  /orders            :3003  /parts
                                /customers                /services
                                /vehicles
        │                     │                          │
        ▼                     ▼                          ▼
   ┌────────────────────────────────┐         ┌──────────────────┐
   │  RDS PostgreSQL (db.t3.micro)  │         │  MongoDB         │
   │  databases: identity, order,   │         │  (StatefulSet)   │
   │             saga, payment      │         │  db: catalog     │
   │  cada serviço com user próprio │         └──────────────────┘
   └────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        │            RabbitMQ (StatefulSet)         │
        │  exchanges: order.events, oficina.commands│
        │  oficina.replies, oficina.alerts,         │
        │  payment.events                           │
        └─────┬───────────┬───────────┬─────────────┘
              │           │           │
              ▼           ▼           ▼
         saga-orch   payment-svc  notification-svc
         (consumer)  :3004        (consumer)
                    /billing/*    + MongoDB próprio
```

## Stacks (ordem de deploy)

| Stack | O que provisiona | Tempo |
|---|---|---|
| `01-network-eks` | VPC, EKS, Kong, SG do RDS, namespaces | ~15 min |
| `02-database-rds` | RDS Postgres com 4 databases + 4 users | ~10 min |
| `03-k8s-shared` | MongoDB×2 (StatefulSets), RabbitMQ, Kong routes | ~2 min |

Cada microsserviço tem sua própria pasta `k8s/` com `deployment`, `service`,
`secret`, `migration-job` apontando para os recursos provisionados acima.

## Pré-requisitos

```bash
# AWS CLI configurado com credenciais do Lab
aws sts get-caller-identity

# Terraform 1.7+
terraform version

# kubectl
kubectl version --client

# (Opcional) helm para inspecionar o Kong
helm version
```

## Bootstrap do S3 backend

O state remoto fica em `s3://autoflow-tfstate/<stack>/terraform.tfstate`.
Crie o bucket uma única vez antes do primeiro apply:

```bash
aws s3api create-bucket \
  --bucket autoflow-tfstate \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket autoflow-tfstate \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket autoflow-tfstate \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'
```

## Deploy

### 1. Network + EKS + Kong

```bash
cd 01-network-eks
terraform init
terraform apply -var-file=environments/dev.tfvars

# Configurar kubectl
$(terraform output -raw cluster_update_kubeconfig_command)
kubectl get nodes
```

### 2. RDS PostgreSQL + Bootstrap dos 4 databases

```bash
cd ../02-database-rds
terraform init
terraform apply -var-file=environments/dev.tfvars

# Cria os 4 databases e 4 users (rodar de dentro de um pod do EKS,
# já que o RDS está em subnet privada)
kubectl run psql-bootstrap --rm -it \
  --image=postgres:16-alpine -n autoflow \
  --env="DB_HOST=$(terraform output -raw db_address)" \
  --env="DB_PORT=$(terraform output -raw db_port)" \
  --env="DB_PASS=$(terraform output -raw db_master_password)" \
  -- sh
# Dentro do pod, executar manualmente os CREATE DATABASE / CREATE ROLE
# ou copiar o script: kubectl cp scripts/init-databases.sh psql-bootstrap:/init.sh
```

Alternativa (com bastion local + port-forward):
```bash
kubectl run psql-tunnel --image=alpine/socat -n autoflow \
  -- tcp-listen:5432,fork,reuseaddr tcp:$(terraform output -raw db_address):5432
kubectl port-forward -n autoflow psql-tunnel 5432:5432 &
./scripts/init-databases.sh   # roda do seu laptop
```

### 3. MongoDB + RabbitMQ + Kong routes

```bash
cd ../03-k8s-shared

# Gerar senhas reais para os secrets (em vez de REPLACE_ME)
kubectl create secret generic mongodb-catalog-auth -n autoflow \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=catalog_admin \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD=$(openssl rand -base64 24) \
  --from-literal=MONGO_INITDB_DATABASE=catalog \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic mongodb-notification-auth -n autoflow \
  --from-literal=MONGO_INITDB_ROOT_USERNAME=notification_admin \
  --from-literal=MONGO_INITDB_ROOT_PASSWORD=$(openssl rand -base64 24) \
  --from-literal=MONGO_INITDB_DATABASE=notification \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic rabbitmq-auth -n autoflow \
  --from-literal=RABBITMQ_DEFAULT_USER=admin \
  --from-literal=RABBITMQ_DEFAULT_PASS=$(openssl rand -base64 24) \
  --dry-run=client -o yaml | kubectl apply -f -

# Aplicar os StatefulSets (sem a parte de Secret no YAML — já criamos acima)
kubectl apply -f 01-mongodb-catalog.yaml
kubectl apply -f 02-mongodb-notification.yaml
kubectl apply -f 03-rabbitmq.yaml

# Aplicar Kong routes (já depois dos Services dos microsserviços existirem)
kubectl apply -f 04-kong-routes.yaml
```

### 4. Microsserviços

Cada microsserviço tem seu próprio `k8s/`. Order recomendada de deploy:

```bash
# A ordem importa por causa de dependências:
# saga-orchestrator pode subir antes (não tem HTTP exposto, só consome RMQ)
kubectl apply -f autoflow-saga-orchestrator/k8s/

# Os outros podem subir em paralelo
kubectl apply -f identity-service/k8s/
kubectl apply -f autoflow-order-service/k8s/
kubectl apply -f autoflow-catalog-service/k8s/
kubectl apply -f autoflow-payment-service/k8s/
kubectl apply -f autoflow-notification-service/k8s/
```

## Endpoints internos (DNS do K8s)

Cada microsserviço acessa as dependências via DNS interno do cluster:

| Recurso | URL interna |
|---|---|
| RabbitMQ AMQP | `amqp://admin:***@rabbitmq.autoflow.svc.cluster.local:5672` |
| RabbitMQ Management | `http://rabbitmq.autoflow.svc.cluster.local:15672` |
| MongoDB catalog | `mongodb://catalog_admin:***@mongodb-catalog.autoflow.svc.cluster.local:27017/catalog` |
| MongoDB notification | `mongodb://notification_admin:***@mongodb-notification.autoflow.svc.cluster.local:27017/notification` |
| RDS Postgres | `<output db_address>:5432` (cada serviço com seu user+db) |

## Endpoint público

```bash
kubectl get svc -n kong kong-kong-proxy \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Exemplo: `aXXXXX.us-east-1.elb.amazonaws.com`. Roteamento:
- `POST /auth/login/admin` → identity-service
- `GET /orders` → order-service
- `POST /parts` → catalog-service
- `POST /billing/webhook/mercadopago` → payment-service

## Destroy

```bash
cd 03-k8s-shared && kubectl delete -f .
cd ../02-database-rds && terraform destroy -var-file=environments/dev.tfvars
cd ../01-network-eks && terraform destroy -var-file=environments/dev.tfvars
```
