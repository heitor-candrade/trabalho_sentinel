#!/bin/bash
# Estado do laboratorio: retrato unico, painel ao vivo ou visao do usuario.
#   scripts/status.sh                          retrato: contêineres, watchdog, nos, Prometheus, Nginx
#   scripts/status.sh --vivo [intervalo_s=3]   painel ao vivo (Ctrl+C sai)
#   scripts/status.sh --usuario [--desde 5m] [--servico nginx|trafego]
#                                              o que o USUARIO viu: nos, status, retries, disponibilidade, p50/p95
source "$(dirname "$0")/lib.sh"
exigir_pilha
retrato() {
  echo "${B}CONTEINERES${N}"
  dc --profile trafego ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}\t{{.Status}}'
  echo
  tbx /opt/sentinel/snapshot.sh || warn "toolbox indisponivel (rode: docker compose up -d toolbox)"
}
case "${1:-}" in
  --usuario) shift; analisar "$@" ;;
  --vivo)
    INT="${2:-3}"; trap 'exit 0' INT TERM
    while true; do
      quadro="$(echo "${B}OPERACAO SENTINEL - painel ao vivo${N}  (a cada ${INT}s; Ctrl+C sai)"; echo
                retrato; echo
                echo "${B}VISAO DO USUARIO - Nginx (30 s)${N}"; analisar --desde 30s --compacto
                [ -n "$(cid trafego)" ] && { echo "${B}VISAO DO USUARIO - gerador de trafego (30 s)${N}"; analisar --servico trafego --desde 30s --compacto; })"
      clear; echo "$quadro"; sleep "$INT"
    done ;;
  ""|-h|--help) [ "${1:-}" = "" ] && retrato || uso "$0" ;;
  *) uso "$0"; exit 2 ;;
esac
