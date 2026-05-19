# Setup — SonarCloud no CI

Validação de qualidade de código (cobertura, code smells, security hotspots, duplicação) via **SonarCloud** — gratuito para repositórios públicos.

Cada um dos 6 microsserviços tem `sonar-project.properties` na raiz e um step no `ci.yml` que executa a análise. O step só roda se o secret `SONAR_TOKEN` estiver presente — sem token, o CI continua passando normal.

---

## Setup inicial (uma vez por organização)

### 1. Criar conta + organização

1. Acesse <https://sonarcloud.io/> e faça login com a conta GitHub `kaikelfalcao`.
2. **Create an Organization** → conecte ao GitHub → escolha "Free plan" (público).
3. Nome da organização: `kaikelfalcao` (mesmo do GitHub — é o que está hardcoded nos `sonar-project.properties`).

### 2. Importar os 6 microsserviços

Em "+" no topo → "Analyze new project" → para cada repo:

- `autoflow-identity-service`
- `autoflow-order-service`
- `autoflow-saga-orchestrator`
- `autoflow-catalog-service`
- `autoflow-payment-service`
- `autoflow-notification-service`

Para cada um, escolha **"With GitHub Actions"** como método de análise. O SonarCloud detecta o `sonar-project.properties` automaticamente.

### 3. Gerar token

1. Em <https://sonarcloud.io/account/security>, gere um **User Token** com nome ex: `autoflow-ci`.
2. Copie o token (formato: `<longa-string-hexadecimal>`).

### 4. Propagar o token via script

```bash
cd autoflow-infra
# Adicione o token ao .env:
echo "SONAR_TOKEN=<token-copiado>" >> .env

# Propague para os 7 repos do GitHub
./scripts/sync-github-secrets.sh
```

O script `sync-github-secrets.sh` já trata `SONAR_TOKEN` como **opcional** — se ele estiver vazio, o script pula sem erro. Se preenchido, é distribuído junto com `DOCKER_*`, `AWS_*` e `NEW_RELIC_LICENSE_KEY`.

### 5. Validar

```bash
# Em cada repo, confirma que o secret foi adicionado:
gh secret list --repo kaikelfalcao/autoflow-identity-service | grep SONAR_TOKEN
```

No próximo push, o step `SonarCloud Scan` aparece no log do CI e o resultado fica em <https://sonarcloud.io/dashboard?id=kaikelfalcao_autoflow-identity-service> (e similares).

---

## O que o Sonar avalia

O `sonar-project.properties` de cada repo configura:

- **Cobertura**: lê `coverage/lcov.info` gerado pelo `npm run test:cov` (que roda **antes** do step do Sonar).
- **Code smells**: bugs, type unsafety, complexidade ciclomática alta, código duplicado.
- **Security hotspots**: padrões de senha hardcoded, SQL injection, XSS, etc.
- **Quality gate**: bloqueia o CI se o gate padrão da SonarCloud falhar (`sonar.qualitygate.wait=true`). Pode ser ajustado por projeto no portal.

### Exclusões (já configuradas em todos os repos)

| Padrão | Por quê |
|---|---|
| `**/*.spec.ts`, `**/*.test.ts` | testes não contam para code smells |
| `**/dist/**`, `**/coverage/**`, `**/node_modules/**` | build artifacts |
| `**/migrations/**` | código gerado / one-shot |
| `**/*.dto.ts`, `**/*.module.ts`, `**/*.schema.ts`, `**/*.orm-entity.ts` | só interfaces / configuração / mapeamento ORM |
| `**/main.ts`, `**/newrelic.js`, `**/data-source.ts` | bootstrap / config externa |
| `**/__mocks__/**` | jest auto-mocks |

---

## Operação contínua

- **Quality Gate por PR**: SonarCloud comenta no PR com diff de cobertura + novos issues introduzidos. Configurar regras em <https://sonarcloud.io/organizations/kaikelfalcao/quality_gates>.
- **PR decoration**: requer instalar o GitHub App da SonarCloud na organização (passo opcional, mas recomendado).
- **Análise em main**: dispara junto com o CI em qualquer push para `main` (e na realidade em qualquer branch, já que o `ci.yml` roda em `branches: ['**']`).

---

## Troubleshooting

| Sintoma | Causa | Solução |
|---|---|---|
| Step "SonarCloud Scan" não aparece no log | `SONAR_TOKEN` não configurado | Rodar `sync-github-secrets.sh` com o token no `.env` |
| Erro "Project not found" | Projeto não importado no SonarCloud | Importar manualmente em `+ → Analyze new project` |
| Erro "Could not find a default branch" | Branch principal não configurada | Em SonarCloud → Project Settings → set `main` como default |
| Coverage vazia no Sonar | `coverage/lcov.info` não gerado | Confirmar que `npm run test:cov` rodou antes do step Sonar |
| Gate quality falhando em PR antigo | "New Code" definido como "all" | Ajustar em Project Settings → New Code → "Previous version" |

---

## Quando voltar para SonarQube self-hosted

A escolha atual (SonarCloud) é o caminho de menor atrito enquanto os repos são públicos. Se eventualmente os repos voltarem a ser privados (custo: GitHub Pro), avaliar:

- **SonarQube Community Edition** rodando no próprio EKS — descobertas e templates já documentados em `autoflow-infra/observability/dashboard.json` podem ser extendidos com NRQL apontando para o servidor self-hosted.
- O step do CI pode ser ajustado para apontar `SONAR_HOST_URL` para a instância interna em vez do SonarCloud público.
