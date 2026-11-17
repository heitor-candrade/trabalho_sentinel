#!/bin/bash
# Gerador de trafego de "usuarios": RATE requisicoes/s (baixa, de proposito).
# Cada requisicao independente (circuito aberto): se o servico fica lento, o gerador
# NAO desacelera, como faria um usuario real. Limite: MAX_INFLIGHT em andamento.
# Saida (uma linha por requisicao):
#   timestamp traffic INFO status=200 node=rust-a latency_ms=12 request_id=...
TARGET="${TARGET:-http://nginx/}"
RATE="${RATE:-3}"
MAX_INFLIGHT="${MAX_INFLIGHT:-20}"
interval="$(awk -v r="$RATE" 'BEGIN { if (r <= 0) r = 1; printf "%.3f", 1 / r }')"

um() {
  local out code t node rid nivel
  out="$(curl -s -o /dev/null -D - -m 5 -w '\n__CODE=%{http_code} __T=%{time_total}\n' "$TARGET" 2>/dev/null)"
  code="$(printf '%s' "$out" | sed -n 's/.*__CODE=\([0-9]*\).*/\1/p')"
  t="$(printf '%s' "$out" | sed -n 's/.*__T=\([0-9.]*\).*/\1/p')"
  node="$(printf '%s' "$out" | tr -d '\r' | awk -F': *' 'tolower($1)=="x-node" {print $2; exit}')"
  rid="$(printf '%s' "$out" | tr -d '\r' | awk -F': *' 'tolower($1)=="x-request-id" {print $2; exit}')"
  [ "$code" = "200" ] && nivel=INFO || nivel=WARN
  printf '%s traffic %s status=%s node=%s latency_ms=%s request_id=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$nivel" "${code:-000}" "${node:--}" \
    "$(awk -v t="${t:-0}" 'BEGIN { printf "%d", t * 1000 }')" "${rid:--}"
}

trap 'exit 0' TERM INT
echo "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) traffic INFO event=start target=${TARGET} rate=${RATE}/s"
while true; do
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_INFLIGHT" ]; do sleep 0.1; done
  um &
  sleep "$interval"
done
