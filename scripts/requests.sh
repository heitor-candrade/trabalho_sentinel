#!/bin/bash
# Envia N requisicoes ao Nginx e mostra, para cada uma, o status, o no que atendeu,
# o tempo total e o request_id. No fim, conta quantas cada no atendeu (Hora 4).
#   scripts/requests.sh [N=20] [caminho=/]
#   scripts/requests.sh fundo start [req_por_s=3] | stop | status | logs
#                       "usuarios" de fundo, em volume baixo de proposito (contêiner 'trafego')
#   REQ_ESTRITO=1 faz o script falhar se alguma resposta nao for 200.
#   REQ_RESUMO=1  imprime apenas o resumo.
source "$(dirname "$0")/lib.sh"
if [ "${1:-}" = "fundo" ]; then
  exigir_pilha
  case "${2:-}" in
    start)  TRAFEGO_RATE="${3:-3}" dc --profile trafego up -d trafego && registrar acoes.log "fundo start rate=${3:-3}/s"
            ok "trafego de fundo no ar. Veja: scripts/status.sh --usuario --servico trafego" ;;
    stop)   dc --profile trafego stop trafego && dc --profile trafego rm -f trafego >/dev/null && registrar acoes.log "fundo stop" && ok "trafego de fundo parado" ;;
    status) dc --profile trafego ps trafego; analisar --servico trafego --desde 60s ;;
    logs)   dc --profile trafego logs -f --no-log-prefix --tail=20 trafego ;;
    *) uso "$0"; exit 2 ;;
  esac
  exit 0
fi
N="${1:-20}"; CAM="${2:-/}"
URL="http://localhost:${HOST_PORT}${CAM}"
hdr="$(mktemp)"; res="$(mktemp)"; trap 'rm -f "$hdr" "$res"' EXIT
[ -n "${REQ_RESUMO:-}" ] || printf '%-4s %-7s %-9s %-9s %s\n' seq status no tempo_s request_id
for i in $(seq "$N"); do
  r="$(curl -s -m 6 -o /dev/null -D "$hdr" -w '%{http_code} %{time_total}' "$URL" 2>/dev/null)" || true
  code="${r%% *}"; t="${r#* }"; [ -n "$r" ] || { code=000; t=6.000; }
  no="$(tr -d '\r' < "$hdr" 2>/dev/null | awk -F': *' 'tolower($1)=="x-node" {print $2; exit}')"
  rid="$(tr -d '\r' < "$hdr" 2>/dev/null | awk -F': *' 'tolower($1)=="x-request-id" {print $2; exit}')"
  [ -n "${REQ_RESUMO:-}" ] || printf '%-4s %-7s %-9s %-9s %s\n' "$i" "$code" "${no:--}" "$t" "${rid:--}"
  echo "$code ${no:--}" >> "$res"
  : > "$hdr"
done
echo "--- resumo ($N requisicoes para $URL)"
awk '{ n[$2]++; s[$1]++ } END {
  printf "por no:     "; for (k in n) printf "%s=%d  ", k, n[k]; printf "\n";
  printf "por status: "; for (k in s) printf "%s=%d  ", k, s[k]; printf "\n" }' "$res"
if [ -n "${REQ_ESTRITO:-}" ] && awk '$1 != 200 { f = 1 } END { exit !f }' "$res"; then exit 1; fi
exit 0
