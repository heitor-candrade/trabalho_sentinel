#!/bin/bash
# Controle dos nos Rust (pela rede interna) e do grupo do Nginx.
#   scripts/admin.sh status [no]          estado interno dos nos
#   scripts/admin.sh ready  <no> 0|1      desliga/liga a prontidao (liveness segue 200)
#   scripts/admin.sh atraso <no> <ms>     latencia artificial (afeta / e /health/ready)
#   scripts/admin.sh pool status                     mostra os nos do upstream do Nginx
#   scripts/admin.sh pool drenar|restaurar <no>      tira/devolve um no do Nginx (reversivel, com copia)
# Os endpoints /admin NAO sao publicados no host. O Nginx de codigo aberto NAO sonda a saude dos
# nos: ele so aprende com falhas do trafego real (max_fails). Retirar um no e uma DECISAO da equipe.
# Cada mudanca do pool gera copia em evidencias/ e uma linha em evidencias/pool.log.
source "$(dirname "$0")/lib.sh"
[ $# -ge 1 ] || { uso "$0"; exit 2; }
if [ "$1" = pool ]; then
  CONF="nginx/nginx.conf"
  [ "${2:-}" = status ] && { grep -E "# POOL:" "$CONF" | sed 's/^ */  /'; exit 0; }
  modo="${2:-}"; no="${3:-}"
  case "$modo" in drenar|restaurar) ;; *) uso "$0"; exit 2;; esac
  case "$no" in rust-a|rust-b) ;; *) die "informe o no: rust-a ou rust-b";; esac
  exigir_pilha
  grep -q "# POOL:$no\$" "$CONF" || die "linha do $no nao encontrada em $CONF (marcador '# POOL:$no')"
  bak="evidencias/nginx.conf.$(agora_arq).bak"; mkdir -p evidencias; cp "$CONF" "$bak"
  # sed portavel (GNU e BSD/macOS): sem "-i" (o BSD exige argumento) e com ";" antes de "}"
  if [ "$modo" = drenar ]; then sed -E "/# POOL:${no}\$/ { /down;/! s/;( +# POOL)/ down;\\1/; }" "$CONF" > "$CONF.tmp"
  else sed -E "/# POOL:${no}\$/ s/ down;( +# POOL)/;\\1/" "$CONF" > "$CONF.tmp"; fi
  mv "$CONF.tmp" "$CONF"
  if recarregar_nginx; then registrar pool.log "$modo $no (copia: $bak)"
  else cp "$bak" "$CONF"; die "configuracao invalida: mudanca DESFEITA (restaurado de $bak)"; fi
  exit 0
fi
exigir_pilha
registrar acoes.log "admin.sh $*"
tbx /opt/sentinel/admin.sh "$@"
