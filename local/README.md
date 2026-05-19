# Setup local com kind

Sobe o ecossistema autoflow inteiro (6 microsserviços + Postgres + Mongo×2 +
RabbitMQ + Kong) num **único cluster Kubernetes local** usando [kind](https://kind.sigs.k8s.io/).

Idêntico ao K8s real, sem precisar de AWS.

## Pré-requisitos

| Ferramenta | Como instalar |
|---|---|
| Docker | Docker Desktop ou Docker Engine |
| `kind` | `brew install kind` · `go install sigs.k8s.io/kind@latest` · [outros métodos](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| `kubectl` | `brew install kubectl` · `apt install kubectl` |
| `helm` | `brew install helm` · [outros métodos](https://helm.sh/docs/intro/install/) |

Validação rápida:
```bash
docker info && kind version && kubectl version --client && helm version
```

## Subir tudo (1 comando)

Do diretório `autoflow-infra/local/`:

```bash
./bootstrap.sh
```

O que ele faz (~5 min do zero):

1. Cria cluster kind `autoflow` (porta 8080 do host → Kong NodePort 30080)
2. Instala Kong via Helm
3. Sobe Postgres (1 StatefulSet, 4 databases: identity/order/saga/payment)
4. Sobe MongoDB×2 separados (catalog, notification)
5. Sobe RabbitMQ
6. `docker build` das 6 imagens
7. `kind load docker-image` carrega no cluster (sem registry)
8. `kubectl apply` dos manifests de cada serviço
9. Roda migration-jobs (4 jobs Postgres) + seed do admin
10. Aguarda todos os deployments ficarem ready

Output final:
```
═══════════════════════════════════════════════════════
   ✅ autoflow rodando no kind
═══════════════════════════════════════════════════════

Endpoints (via Kong em http://localhost:8080):
  POST /auth/login/admin                  → identity
  ...
RabbitMQ Management: http://localhost:15672 (admin/admin)
```

## Testar o fluxo completo

```bash
./smoke-test.sh
```

Executa happy path E2E (12 etapas): cadastro de cliente/veículo, login customer,
abertura de ordem, aprovação de budget (dispara saga reserve), conclusão
(consume + payment.requested), pagamento (webhook MP mock), confirmação,
verificação de notificações no Mongo. Assertions em cada passo.

## Atalhos do dia a dia

```bash
# Ver tudo
kubectl get pods -n autoflow

# Logs de um serviço
kubectl logs -f deploy/order-service -n autoflow
kubectl logs -f deploy/saga-orchestrator -n autoflow

# Logs dos jobs
kubectl logs job/identity-migration -n autoflow
kubectl logs job/identity-seed-admin -n autoflow

# Shell no Postgres
kubectl exec -it postgres-0 -n autoflow -- psql -U postgres

# Shell no Mongo catalog
kubectl exec -it mongodb-catalog-0 -n autoflow -- mongosh -u catalog_admin -p catalog_pass --authenticationDatabase admin

# RabbitMQ Management UI
open http://localhost:15672  # user: admin, pass: admin

# Restart de 1 serviço
kubectl rollout restart deploy/payment-service -n autoflow

# Rebuild + redeploy de 1 serviço (após mudança no código)
./bootstrap.sh --rebuild payment

# Pular build (reusa imagens existentes)
./bootstrap.sh --no-build
```

## Mapeamento de portas

| Host | Cluster (NodePort) | Serviço |
|---|---|---|
| `localhost:8080` | `30080` | Kong proxy (todas as APIs) |
| `localhost:15672` | `30672` | RabbitMQ Management UI |

Tudo o mais é interno ao cluster (DNS `*.autoflow.svc.cluster.local`).

## Estrutura

```
local/
├── kind-config.yaml         # cluster config (port mappings)
├── bootstrap.sh             # main: cria tudo
├── teardown.sh              # destrói cluster
├── smoke-test.sh            # wrapper bash
├── smoke-test.py            # happy path E2E
└── manifests/
    ├── 00-postgres.yaml     # Postgres local (substitui RDS)
    ├── 10-secrets.yaml      # secrets dos 6 serviços + Mongo/RMQ
    ├── 20-kong-nodeport.yaml
    └── 21-rabbitmq-nodeport.yaml
```

Os manifests dos 6 microsserviços vêm de cada repo (`<service>/k8s/`) — não
duplicados aqui. O `bootstrap.sh` apenas substitui `:latest` por `:local` e
`Always` por `IfNotPresent` ao aplicar.

Os manifests compartilhados (Mongo×2, RabbitMQ, Kong ingress) vêm de
`autoflow-infra/03-k8s-shared/` — mesmos do ambiente AWS.

## Limpar tudo

```bash
./teardown.sh
```

Apaga o cluster inteiro. Volume dos PVCs também é descartado (kind usa
`hostPath` efêmero).

## Troubleshooting

**Pod fica em `ImagePullBackOff`:**
```bash
# Verifica se a imagem foi carregada
docker exec autoflow-control-plane crictl images | grep autoflow
# Se não, recarrega:
./bootstrap.sh --rebuild <service>
```

**Migration job falha:**
```bash
kubectl logs job/order-migration -n autoflow
# Geralmente é DB ainda não pronto. Re-roda:
kubectl delete job order-migration -n autoflow
kubectl apply -f ../../autoflow-order-service/k8s/migration-job.yaml
```

**Kong não responde em `localhost:8080`:**
```bash
# Confirma NodePort e port mapping do kind
kubectl get svc -n kong kong-kong-proxy
docker port autoflow-control-plane
```

**RabbitMQ consumer não conecta:**
```bash
# Verifica se exchanges foram criados pelos serviços
kubectl port-forward -n autoflow svc/rabbitmq 15672:15672 &
# Acessa http://localhost:15672 — deve ver order.events, oficina.commands, etc.
```

## Diferenças do ambiente AWS

| Item | Local (kind) | AWS (EKS) |
|---|---|---|
| Cluster | 1 node kind | 2 nodes EKS managed |
| Postgres | StatefulSet no cluster | RDS db.t3.micro |
| Storage | hostPath efêmero | gp3 EBS persistente |
| Kong LB | NodePort 30080 | NLB público |
| Imagens | `:local` (kind load) | `:latest` (DockerHub) |
| Senhas | hardcoded (dev) | random_password do Terraform |
| Migrations | Job rodando no apply | Job rodando no CI/CD pipeline |
