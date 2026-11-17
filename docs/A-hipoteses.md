# Hipóteses — Operação Sentinel

**Disciplina:** FEELT37802 - Sistemas Distribuídos (2026/2)  
**Prof.:** Renato Carrijo  
**Líder:** Heitor Carvalho Andrade (12311ECP023)

---

## 1. Hipótese de Rede (Atraso / Timeout)
**Se** um atraso de rede de `3500 ms` for introduzido em `rust-a`, **então** o `Nginx` marcará o nó como inoperante e redirecionará 100% das requisições para `rust-b`, **porque** a latência excede o `proxy_read_timeout` de 1000 ms configurado no Nginx.

## 2. Hipótese de Observabilidade (Ausência de Métrica / Falso Verde)
**Se** o `watchdog` parar de coletar métricas devido a uma falha de DNS interno, **então** os alertas no Prometheus permanecerão em estado insatisfeito (falso verde), **porque** a ausência de atualização de dados não ativa automaticamente gatilhos baseados apenas em limiares de valores positivos sem verificação de ausência (`absent`).

## 3. Hipótese de Aplicação e Balanceamento (Readiness vs. Liveness)
**Se** a rota de prontidão `/health/ready` de rust-a retornar status `HTTP 503`, **então** o Nginx removerá o nó do pool de balanceamento sem encerrar o processo Rust, **porque** a checagem de saúde de upstream falhará mantendo a instância ativa para diagnóstico isolado.
