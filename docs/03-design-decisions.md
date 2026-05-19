# Justificativa — divisão dos microsserviços e tecnologias

## Divisão dos microsserviços

O autoflow tem **6 microsserviços** + 2 sidecars de infra (Kong + RabbitMQ). A divisão segue **subdomínios de negócio + limites transacionais**, não decomposição por camada técnica.

| Serviço                | Subdomínio                                       | Responsabilidade única                                                |
|------------------------|--------------------------------------------------|------------------------------------------------------------------------|
| `identity-service`     | **Autenticação**                                 | Emite/valida JWT (customer + admin). Único guardião de credenciais.    |
| `order-service`        | **Ordem de Serviço** (núcleo do negócio)         | Ciclo de vida da OS, customer, vehicle, budget e fila de execução.     |
| `catalog-service`      | **Catálogo + Estoque**                           | Peças e serviços. Reserva/consumo/liberação de estoque (saga-aware).   |
| `payment-service`      | **Cobrança**                                     | Charges + integração Mercado Pago + processamento de webhook.          |
| `saga-orchestrator`    | **Coordenação de transações distribuídas**       | State machine do sub-fluxo de estoque.                                 |
| `notification-service` | **Comunicação outbound**                         | Audit log de eventos + base para envios futuros (email / push).        |

### Por que essa granularidade?

**Não fizemos um serviço por entidade** (anti-pattern "nano-services"). Customer, Vehicle e Order vivem no mesmo serviço porque:

- **Limite transacional**: abrir uma OS exige criar/atualizar customer + vehicle + order_item + status_history numa única transação ACID. Distribuir entre serviços exigiria saga adicional sem ganho real.
- **Modelo conjunto**: a OS é a entidade central; customer e vehicle só existem em função dela.
- **Fonte de verdade do CPF**: o `identity-service` consulta `order` via HTTP para autenticar — único acoplamento síncrono direcionado, com **circuit breaker** (opossum).

**Catalog tem dois subdomínios** (parts + services) no mesmo serviço:

- Ambos são "itens precificáveis do catálogo da oficina".
- Não justifica dois serviços com bancos separados e duplicação de Auth/Logger/Config.
- Subdomínios isolados internamente (`src/domain/parts/` vs `src/domain/services/`), prontos para extração futura se cada um ganhar complexidade independente.

**Saga separado**:

- Mantém o `order-service` agnóstico ao detalhe de "como o estoque é reservado". Order publica `order.budget.approved` e segue a vida; saga é o adapter entre o domínio de negócio e o domínio operacional de estoque.
- Permite evoluir a state machine (adicionar timeouts, retries com decay, dashboards específicos) sem tocar no order.
- Detalhamento da decisão: [02-saga-pattern.md](./02-saga-pattern.md).

**Notification separado**:

- Audit log de domínio é cross-cutting — afeta todos os outros serviços. Centralizar evita lógica duplicada.
- É o ponto natural para evoluir para envio real (e-mail/SMS/push) sem mexer no fluxo principal.

---

## Stack escolhida

### Linguagem e framework — TypeScript + NestJS

| Aspecto                  | Por quê                                                                                              |
|--------------------------|------------------------------------------------------------------------------------------------------|
| **TypeScript (strict)**  | Tipagem evita classe inteira de bugs (`any` proibido por ESLint), refactors seguros entre módulos.   |
| **NestJS**               | DI nativa, módulos coesos, decorators para HTTP/RMQ/health/Swagger. Convenção pareada com o ecossistema (`@golevelup/nestjs-rabbitmq`, `@nestjs/terminus`, `@nestjs/typeorm`). |
| **Node.js 24 LTS**       | LTS atual no momento do tech-challenge. Performance e suporte a longo prazo.                          |
| **Hexagonal (ports & adapters)** | Adotado em `catalog`, `order` e `payment` por feature. Domínio puro em TS, isolado de Mongo/Postgres/RMQ. Permite testar regras de negócio sem infra. `identity` e `saga` ficaram em **MVC enxuto** porque a complexidade não justifica indireção extra. |

### Bancos

**Postgres** (identity, order, saga, payment):

- Modelo relacional forte (FK, transações ACID, índices únicos).
- TypeORM com migrations versionadas em `src/.../migrations/`.
- Mesmo cluster RDS em produção, **schemas/databases distintos** por serviço (zero cross-database queries).

**MongoDB** (catalog, notification):

- **Catalog**: peças têm atributos heterogêneos por categoria (`PartCategory.TIRE` tem `dotNumber`/`treadDepth`; `PartCategory.OIL` tem `viscosity`/`syntheticBlend`). Schema relacional forçaria nullables ou EAV. Mongo com `attributes: Mixed` resolve sem ginástica.
- **Notification**: audit log append-only + payload heterogêneo por tipo de evento. Caso clássico de Mongo.
- Mongoose com `optimisticConcurrency: true` (lock otimista via `version`) — evita necessidade de transactions (que exigiriam replica set).

### Mensageria — RabbitMQ

- Exchanges `topic` com routing keys hierárquicas (`order.budget.approved`, `stock.low-stock-alert`).
- **DLQ** habilitada por consumer (`x-dead-letter-exchange: oficina.dlx`), com 3 retries + backoff exponencial.
- **At-least-once delivery** assumida — toda lógica de consumer é idempotente (validação por `sagaId`, `orderId`, ou `mpPaymentId`).
- `@golevelup/nestjs-rabbitmq` para saga/catalog/notification (high-level, decorator-based). `amqp-connection-manager` direto para order/payment (mais controle sobre publisher).
- Kafka foi considerado e descartado:
  - Sobre-engineering para a carga esperada (~dezenas de eventos/segundo).
  - RabbitMQ tem suporte nativo a DLQ e routing topic.
  - Curva de operação menor (sem Zookeeper/KRaft, partições, retenção).

### API Gateway — Kong

- Modo **DB-less** (config declarativa em YAML). Sem dependência operacional de banco para o gateway.
- Roteamento por prefixo de path; autorização (JWT) **dentro de cada serviço**, reusando o mesmo `JWT_SECRET` emitido pelo identity. Evita duplicar lógica de auth no gateway.
- NLB AWS exposing the Ingress em produção; Service `LoadBalancer` no kind local.

### Observabilidade — New Relic + Winston

- **New Relic APM** em todos os 6 serviços: transactions, traces, errors automáticos.
- **Custom events** via `recordCustomEvent('AutoflowBizEvent', ...)` → 11 tipos de eventos de negócio (`OrderCreated`, `SagaReserved`, `StockInsufficient`, `ChargeCreated` etc).
- **Logs canônicos** via Winston: 1 entrada por request HTTP + 1 por evento RMQ processado, com `correlationId` propagado pelo header `x-correlation-id`.
- Dashboard em [`observability/dashboard.json`](../observability/dashboard.json), provisionado via [`provision-dashboard.sh`](../observability/provision-dashboard.sh) (NerdGraph).
- **TODO**: SonarQube Community Edition (self-hosted) para análise estática de qualidade — atualmente o gate é threshold de coverage do Jest (80%) + ESLint.

### Container e deploy

- **Docker multi-stage** (`node:24-alpine`) padronizado em todos os repos. `USER node` (sem root), `HEALTHCHECK` via `/health`, `npm ci --omit=dev` (sem dependências de dev na imagem final).
- **Kubernetes** no EKS:
  - `Deployment` + `Service` + `HPA` por serviço (HPA ausente em `saga` e `notification` por escolha — saga tem estado, notification baixa carga).
  - `Job` de migração rodado antes do rollout (sequência garantida no `bootstrap.sh` / pipeline).
  - `Secret` populado via `scripts/sync-github-secrets.sh` (DockerHub, AWS Lab, New Relic).
- **kind** local replicando a topologia EKS — bootstrap em ~5 min do zero, validado pelos scripts `local/happy-path.sh`, `local/bad-path-stock.sh`, `local/bad-path-payment.sh`.

### CI/CD — GitHub Actions

- **`ci.yml`** em cada repo: dispara em push/PR de **qualquer branch** → lint + format:check + test:cov (80% threshold global) + bdd.
- **`cd.yml`** via `workflow_run`: dispara após CI verde na `main` → build & push imagem `kaikelfalcao/autoflow-<svc>:<sha>` no DockerHub → `kubectl rollout` no EKS.
- Branch protection: `protect-main` ruleset bloqueia push direto na `main`; PR obrigatório.

---

## Trade-offs assumidos

| Decisão                                       | Trade-off aceito                                                                 |
|-----------------------------------------------|----------------------------------------------------------------------------------|
| Customer/Vehicle dentro do order              | Acoplamento maior dentro de order (justificável por transações conjuntas) em troca de menos coordenação distribuída. |
| `payment.replicas=1` em modo mock             | Adapter mock mantém estado em memória (Map). Em produção com adapter real do MP, sem essa limitação. |
| Sem MongoDB transactions                       | Lock otimista via `versionKey`. Em alta concorrência, retry adiciona latência (aceito para o volume esperado). |
| RabbitMQ at-least-once → consumers idempotentes | Toda lógica de domínio precisa lidar com reentrega. Adiciona complexidade local mas evita perda de mensagens. |
| Kong sem JWT plugin (validação dentro de cada serviço) | Cada serviço carrega `@nestjs/jwt`. Em troca, lógica de auth fica próxima ao domínio + Kong DB-less mais simples. |
| `SonarQube` removido temporariamente          | Coverage Jest cobre quality gate básico. Voltar com Community edition self-hosted é TODO documentado. |
| Migration job antes do rollout                | Sequência manual de aplicação (job → deploy). Falha de migration trava o deploy — comportamento desejado. |

---

## Limitações conhecidas

- **`payment-service` em modo mock obriga `replicas=1`** — o `MercadoPagoMockAdapter` mantém estado em memória. Para multi-réplica em dev, seria preciso persistir o estado mock no banco ou usar Redis.
- **Migrations Postgres não são revertidas no rollback de Deployment** — se uma migration nova quebra o app, o rollback do deployment não desfaz a migration. Operação requer atenção manual.
- **AWS Academy Lab tem restrições de IAM** (`iam:GetRole` negado) — adaptamos o Terraform para evitar features que exigem `IRSA`, usando `LabRole` como service account role do EKS.

---

## Referências

- [01-architecture.md](./01-architecture.md) — diagrama geral, fluxos e camadas
- [02-saga-pattern.md](./02-saga-pattern.md) — escolha entre orquestração e coreografia
- [READMEs dos serviços](https://github.com/kaikelfalcao?tab=repositories&q=autoflow) — endpoints, eventos e env vars de cada microsserviço
