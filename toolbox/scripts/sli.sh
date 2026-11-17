#!/bin/bash
# Indicadores (SLIs) calculados a partir das metricas dos nos e do watchdog.
# Atencao: estes numeros sao a visao DOS NOS. O que o usuario viu esta nos logs do
# Nginx e do gerador de trafego (scripts/status.sh --usuario).
P=/opt/sentinel/promq.sh
sec() { printf '\n== %s\n' "$1"; }
sec "Requisicoes de usuario por no (req/s, janela 1 min)"
"$P" 'sum by (node) (rate(sentinel_http_requests_total{route=~"root|erro"}[1m]))'
sec "Taxa de erro 5xx por no (janela 2 min)  [alerta sugerido > 0,02]"
"$P" 'sum by (node) (rate(sentinel_http_requests_total{route=~"root|erro",code=~"5.."}[2m])) / sum by (node) (rate(sentinel_http_requests_total{route=~"root|erro"}[2m]))'
sec "Latencia p95 por no, medida no no (s, janela 1 min)"
"$P" 'histogram_quantile(0.95, sum by (le, node) (rate(sentinel_app_request_duration_seconds_bucket[1m])))'
sec "Saturacao: requisicoes em andamento por no"
"$P" 'sentinel_inflight_requests'
sec "Prontidao informada pelo proprio no (1 = pronto)"
"$P" 'sentinel_ready'
sec "Visao do watchdog: DOWN (1) ou UP (0)"
"$P" 'watchdog_target_down'
sec "Visao do watchdog: falhas consecutivas"
"$P" 'watchdog_consecutive_failures'
sec "Idade da ultima sondagem do watchdog (s)  [monitor parado se > 30]"
"$P" 'time() - watchdog_last_probe_timestamp_seconds'
sec "Alvos coletados pelo Prometheus (1 = coleta ok)"
"$P" 'up'
