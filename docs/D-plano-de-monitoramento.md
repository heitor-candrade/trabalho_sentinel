# Plano de Monitoramento e Observabilidade (Entrega D)

**Disciplina:** FEELT37802 - Sistemas Distribuídos (2026/2)  
**Prof.:** Renato Carrijo  
**Projeto:** Operação Sentinel: Cluster Distribuído Resiliente  
**Aluno:** Heitor Carvalho Andrade (Matrícula: 12311ECP023)  
**Evidências de referência:** `evidencias/hora5-sli.txt` (`14:54:43 UTC`), `evidencias/hora5-promq.txt` (`14:54:44 UTC`), `evidencias/hora5-painel.png` e `prometheus/alerts.yml`

---

## 1. Arquitetura de Observabilidade

A observabilidade do cluster Sentinel é estruturada em três camadas independentes para evitar pontos cegos entre o que a aplicação relata sobre si mesma e o que o usuário final realmente experimenta:

1. **Instrumentação Interna (Nós `rust-a` e `rust-b`):** Expõem o endpoint `/metrics` na porta `8080` (acessível apenas na rede interna `10.9.8.0/24`), contabilizando volume de requisições, códigos de retorno HTTP, histogramas de latência de processamento, prontidão (`sentinel_ready`) e concorrência ativa (`sentinel_inflight_requests`).
2. **Observador Externo Independente (`watchdog` — `10.9.8.20:9100`):** Executa sondagens ativas periódicas a cada `5 s` (com *timeout* de `2 s`) contra `/health/ready` dos nós Rust e contra o gateway Nginx, expondo o estado externo (`watchdog_target_down`), falhas consecutivas e o *timestamp* da última verificação bem-sucedida.
3. **Coleta, Armazenamento e Avaliação de Regras (`prometheus` — `10.9.8.30:9090`):** Realiza *scrape* periódico de todos os alvos (`rust-a`, `rust-b`, `watchdog` e `prometheus`), avalia as regras definidas em `prometheus/alerts.yml` e alimenta o painel operacional (`http://localhost:8085`).

---

## 2. Indicadores e Objetivos de Nível de Serviço (SLIs e SLOs)

| SLI | Fórmula / Expressão PromQL | Objetivo (SLO) | Janela de Avaliação | Perspectiva / Limitação |
| :--- | :--- | :---: | :---: | :--- |
| **SLI 1 — Disponibilidade de Requisições** | `1 - (sum(rate(sentinel_http_requests_total{route=~"root|erro",code=~"5.."}[5m])) / sum(rate(sentinel_http_requests_total{route=~"root|erro"}[5m])))` | $\ge 99,9\%$ | 7 dias | Mede sucesso HTTP nas rotas de usuário nos nós Rust; deve ser cruzado com os logs do Nginx (`status.sh --usuario`) para incluir falhas de conexão no proxy. |
| **SLI 2 — Latência de Processamento (p95)** | `histogram_quantile(0.95, sum by (le) (rate(sentinel_app_request_duration_seconds_bucket[5m])))` | $< 200\text{ ms}$ | 24 horas | Mede o tempo de resposta interno do back-end; não inclui latência de rede externa nem filas/retries no Nginx. |
| **SLI 3 — Disponibilidade Externa dos Nós** | `avg_over_time((watchdog_target_down == 0)[1h:])` | $\ge 99,5\%$ | 1 hora | Reflete a capacidade contínua de cada nó responder dentro do orçamento de `2 s` sob visão externa do `watchdog`. |

---

## 3. As 5 Métricas Principais Monitoradas

1. **`sentinel_ready` (Medidor / *Gauge* — Sinal: Disponibilidade / Prontidão):**  
   Indica se o nó concluiu o aquecimento (`WARMUP_SECONDS=3`) e está apto a receber tráfego (`1` = pronto, `0` = não pronto). Permite detectar estados de degradação silenciosa nos quais o contêiner permanece vivo (`/health/live` = `200`), mas indisponível para operar (`/health/ready` = `503`).
2. **`sentinel_app_request_duration_seconds_bucket` (Histograma / *Histogram* — Sinal: Latência):**  
   Distribui o tempo de execução das requisições HTTP em faixas (*buckets*) por nó, permitindo calcular percentis (`p50`, `p95`, `p99`) via `histogram_quantile` sem mascarar caudas longas de latência.
3. **`sentinel_http_requests_total{route=~"root|erro",code=~"5.."}` (Contador / *Counter* — Sinal: Erro):**  
   Contabiliza acumulativamente o total de requisições processadas por rota e código de status HTTP. A derivada (`rate`) permite calcular tanto o volume de tráfego quanto a proporção exata de falhas `5xx`.
4. **`sentinel_inflight_requests` (Medidor / *Gauge* — Sinal: Saturação):**  
   Informa quantas requisições estão sendo processadas simultaneamente em cada instância Rust no instante da coleta, antecipando gargalos de concorrência antes que ocorram *timeouts*.
5. **`watchdog_target_down` (Medidor / *Gauge* — Sinal: Disponibilidade Externa):**  
   Publicado pelo observador independente (`watchdog`). Assume `0` quando o alvo responde corretamente às sondagens e `1` após 3 falhas consecutivas, eliminando o viés de autoavaliação dos nós de aplicação.

---

## 4. Tabela de Alertas (`prometheus/alerts.yml`)

| Alerta | Expressão PromQL | Duração (`for`) | Justificativa do Limiar | Severidade / Dono | Procedimento de Resposta (*Runbook*) |
| :--- | :--- | :---: | :--- | :---: | :--- |
| **`NoDown`** | `watchdog_target_down == 1` | `15s` | O watchdog sonda a cada `5 s` e exige 3 falhas consecutivas (`15 s`) para declarar `DOWN`; aguardar mais `15 s` evita alarmes falsos por oscilação momentânea de rede. | `alta` / `plantao` | Preservar evidências (`scripts/evidence.sh`), testar conectividade a partir de outro ponto (`nginx`, `toolbox`) e drenar o nó antes de reiniciar. |
| **`TaxaDeErroAlta`** | `sum(rate(sentinel_http_requests_total{route=~"root|erro",code=~"5.."}[2m])) / sum(rate(sentinel_http_requests_total{route=~"root|erro"}[2m])) > 0.02` | `2m` | Mais de `2%` de falhas `5xx` sustentadas por `2 min` consome rapidamente o orçamento de erro e viola o SLO de disponibilidade de `99,9%`. | `alta` / `plantao` | Inspecionar logs dos nós Rust, drenar o nó afetado (`scripts/admin.sh pool drenar`) e avaliar *rollback*. |
| **`LatenciaAltaP95`** | `histogram_quantile(0.95, sum by (le, node) (rate(sentinel_app_request_duration_seconds_bucket[2m]))) > 1.0` | `1m` | Latência `p95 > 1,0 s` excede em 5x o SLO (`< 200 ms`) e aproxima-se do *timeout* do watchdog (`2 s`) e do Nginx (`3 s`). | `media` / `equipe` | Verificar saturação (`sentinel_inflight_requests`), uso de CPU no host e atrasos artificiais injetados (`/admin/status`). |
| **`MonitorParado`** | `(up{job="watchdog"} == 0) or absent(watchdog_last_probe_timestamp_seconds) or ((time() - max(watchdog_last_probe_timestamp_seconds)) > 30)` | `10s` | **Regra de Ouro 3 (vigiar o vigia):** `30 s` equivalem a 6 ciclos perdidos de sondagem de `5 s`. O uso de `up == 0` e `absent()` garante disparo mesmo se o contêiner `watchdog` parar e a série desaparecer. | `media` / `equipe` | Verificar o estado do contêiner `sentinel-watchdog` (`docker compose ps` e `logs`) e reiniciar o serviço se necessário. |

---

## 5. Validação em Estado Normal (Baseline Hora 5)

Em `18/11/2026` às `14:54:43 UTC` (`evidencias/hora5-sli.txt` e `evidencias/hora5-promq.txt`), após a recarga das regras via `scripts/validar.sh --recarregar`, o estado saudável do cluster foi comprovado pelos seguintes indicadores:

* **Alvos coletados (`up`):** `rust-a:8080 = 1`, `rust-b:8080 = 1`, `watchdog:9100 = 1` e `localhost:9090 = 1` (100% dos alvos ativos).
* **Prontidão e saturação dos nós:** `sentinel_ready = 1` e `sentinel_inflight_requests = 1` (apenas a coleta de métricas) em ambos os nós.
* **Sondagem externa (`watchdog`):** `watchdog_target_down = 0` e `watchdog_consecutive_failures = 0` para `rust-a` e `rust-b`, com idade da última sondagem em `~3,60 s` (dentro do intervalo regular de `5 s`).
* **Taxa de erro e alertas:** Zero erros `5xx` registrados na janela e todas as 4 regras de alerta em estado `Inactive` (verde) no Prometheus e no painel (`evidencias/hora5-painel.png`).