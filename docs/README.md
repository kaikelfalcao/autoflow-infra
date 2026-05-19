# Documentação técnica — autoflow

Documentação de arquitetura do ecossistema **autoflow** (FIAP Tech Challenge — Fase 4).

| Documento | Conteúdo |
|---|---|
| [01-architecture.md](./01-architecture.md) | Diagrama geral dos 6 microsserviços, bancos, mensageria. Fluxo end-to-end de uma OS. Camada de edge (Kong) e observabilidade. |
| [02-saga-pattern.md](./02-saga-pattern.md) | Estratégia de transações distribuídas: **modelo híbrido** — coreografia para o fluxo principal, orquestração para o sub-fluxo de estoque. Idempotência e tratamento de falhas. |
| [03-design-decisions.md](./03-design-decisions.md) | Justificativa da divisão dos 6 microsserviços. Stack: NestJS, Postgres, MongoDB, RabbitMQ, Kong, New Relic, kind/EKS. Trade-offs assumidos. |

Os diagramas estão em **Mermaid** — renderizam nativamente no GitHub e na maioria dos visualizadores Markdown.

---

## Referências cruzadas

- READMEs por serviço (endpoints, eventos, env vars): cada repo `autoflow-*-service/README.md`.
- Manifests k8s: `autoflow-infra/03-k8s-shared/`, `<service>/k8s/`.
- Scripts de deploy: `autoflow-infra/scripts/aws-lab-deploy.sh`, `autoflow-infra/local/bootstrap.sh`.
- Dashboard New Relic: `autoflow-infra/observability/dashboard.json`.
