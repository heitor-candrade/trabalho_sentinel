#!/bin/bash
# Injecao de falhas de REDE (tc netem) em um contêiner do projeto. Seguro por construcao:
# so atua em contêineres do projeto "sentinel", na interface virtual deles, e os efeitos
# desaparecem ao recriar o contêiner ou com "limpar". Nada toca no host.
#
# Uso:
#   scripts/chaos.sh atraso   <no> <ms>  [--jitter ms] [--perda %] [--para ALVO]
#   scripts/chaos.sh perda    <no> <%>   [--atraso ms]              [--para ALVO]
#   scripts/chaos.sh particao <no>                                  [--para ALVO]
#   scripts/chaos.sh aplicar  <no> [--atraso ms] [--jitter ms] [--perda %] [--para ALVO]
#   scripts/chaos.sh limpar   <no|todos> [--para ALVO]
#   scripts/chaos.sh status   [no|todos]
#   scripts/chaos.sh captura  <no> [segundos=10] ["filtro tcpdump"]
#
# <no>   : nginx | rust-a | rust-b | watchdog | prometheus | toolbox | painel
# --para : restringe a falha ao trafego QUE SAI de <no> com destino a ALVO
#          (nginx|rust-a|rust-b|watchdog|prometheus|toolbox|painel ou um IPv4).
#          Sem --para, a falha vale para toda a saida de <no>.
#
# Modelo (e seu limite): a falha atua na SAIDA de <no>. Atrasar/perder a saida de rust-a
# equivale a atrasar/perder as RESPOSTAS de rust-a. Nao ha falha de hardware, de
# roteador nem de varias maquinas: e uma simulacao dentro de um unico host.
# Exemplos:
#   scripts/chaos.sh atraso rust-a 800                # respostas de A demoram +800 ms para todos
#   scripts/chaos.sh perda rust-a 30                  # 30% dos pacotes de saida de A se perdem
#   scripts/chaos.sh particao rust-a                  # A vivo, mas isolado da rede
#   scripts/chaos.sh limpar todos
source "$(dirname "$0")/lib.sh"
VALIDOS="nginx rust-a rust-b watchdog prometheus toolbox painel"
usar() { uso "$0"; }

[ $# -ge 1 ] || { usar; exit 2; }
ACAO="$1"; shift
[ "$ACAO" = "ajuda" ] || [ "$ACAO" = "-h" ] || [ "$ACAO" = "--help" ] && { usar; exit 0; }
exigir_pilha

NO=""; ATRASO=0; JITTER=0; PERDA=0; PARA=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --atraso) ATRASO="${2:-}"; shift 2;;
    --jitter) JITTER="${2:-}"; shift 2;;
    --perda)  PERDA="${2:-}"; shift 2;;
    --para)   PARA="${2:-}"; shift 2;;
    -h|--help) usar; exit 0;;
    *) POS+=("$1"); shift;;
  esac
done
NO="${POS[0]:-}"

num() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "valor numerico invalido: '$1'"; }
valido() { for v in $VALIDOS; do [ "$v" = "$1" ] && return 0; done; return 1; }
imagem() { docker image inspect sentinel-chaos:local >/dev/null 2>&1 || { info "construindo a imagem sentinel-chaos..."; dc --profile tools build chaos >/dev/null || die "falha ao construir sentinel-chaos"; }; }

# roda netem.sh no namespace de rede de <servico>; demais argumentos vao ao netem.sh
no_exec() { # no_exec <servico> <dst_ip> <dst_band> <dst_nome> <args...>
  local svc="$1" dip="$2" dband="$3" dnome="$4"; shift 4
  local id; id="$(cid "$svc")"; [ -n "$id" ] || { erro "o servico '$svc' nao esta em execucao"; return 1; }
  docker run --rm --cap-add NET_ADMIN --network "container:$id" \
    -e DST_IP="$dip" -e DST_BAND="$dband" -e DST_NAME="$dnome" -e NAME_MAP="$(mapa_nomes)" \
    sentinel-chaos:local "$@"
}

resolver_para() { # define DST_IP DST_BAND DST_NOME a partir de $PARA
  DST_IP=""; DST_BAND=""; DST_NOME=""
  [ -n "$PARA" ] || return 0
  if [[ "$PARA" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then DST_IP="$PARA"; DST_BAND=9; DST_NOME="$PARA"; return 0; fi
  valido "$PARA" || die "--para invalido: '$PARA' (use: $VALIDOS ou um IPv4)"
  [ "$PARA" != "$NO" ] || die "--para nao pode ser o proprio no"
  local id; id="$(cid "$PARA")"; [ -n "$id" ] || die "o servico '$PARA' nao esta em execucao"
  DST_IP="$(ip_de "$id")"; DST_BAND="$(banda_de "$PARA")"; DST_NOME="$PARA"
}

exigir_no() { [ -n "$NO" ] || { erro "informe o no ($VALIDOS)"; usar; exit 2; }; valido "$NO" || die "no invalido: '$NO' (use: $VALIDOS)"; }

case "$ACAO" in
  atraso)   exigir_no; ATRASO="${POS[1]:-$ATRASO}"; num "$ATRASO"; [ "$ATRASO" != 0 ] || die "informe o atraso em ms"; ACAO=aplicar;;
  perda)    exigir_no; PERDA="${POS[1]:-$PERDA}"; num "$PERDA"; [ "$PERDA" != 0 ] || die "informe a perda em %"; ACAO=aplicar;;
  particao) exigir_no; PERDA=100; ACAO=aplicar;;
esac

case "$ACAO" in
  aplicar)
    exigir_no; num "$ATRASO"; num "$JITTER"; num "$PERDA"
    awk -v p="$PERDA" -v a="$ATRASO" 'BEGIN{exit !(p<=100 && a<=30000)}' || die "perda deve ser <= 100 e atraso <= 30000 ms"
    imagem; resolver_para
    t0="$(agora)"
    if no_exec "$NO" "$DST_IP" "$DST_BAND" "$DST_NOME" aplicar "$ATRASO" "$JITTER" "$PERDA"; then
      registrar chaos.log "aplicar no=$NO para=${DST_NOME:-todos} atraso=${ATRASO}ms jitter=${JITTER}ms perda=${PERDA}%"
      info "falha ativa desde $t0 (registrada em evidencias/chaos.log). Para desfazer: scripts/chaos.sh limpar $NO${PARA:+ --para $PARA}"
    else exit 1; fi ;;
  limpar)
    imagem
    if [ "${NO:-}" = "todos" ] || [ -z "${NO:-}" ]; then
      for s in $VALIDOS; do [ -n "$(cid "$s")" ] && no_exec "$s" "" "" "" limpar | sed "s/^/[$s] /"; done
      registrar chaos.log "limpar todos"
    else
      exigir_no; resolver_para
      no_exec "$NO" "$DST_IP" "$DST_BAND" "$DST_NOME" limpar && registrar chaos.log "limpar no=$NO para=${DST_NOME:-todos}"
    fi ;;
  status)
    imagem
    lista="${NO:-todos}"; [ "$lista" = "todos" ] && lista="$VALIDOS"
    for s in $lista; do
      valido "$s" || die "no invalido: '$s'"
      [ -n "$(cid "$s")" ] || { echo "== $s: nao esta em execucao"; continue; }
      echo "== $s"; no_exec "$s" "" "" "" status | sed 's/^/   /'
    done ;;
  captura)
    exigir_no; imagem
    no_exec "$NO" "" "" "" captura "${POS[1]:-10}" "${POS[2]:-tcp port 8080 or tcp port 9100 or icmp}" ;;
  *) erro "acao desconhecida: $ACAO"; usar; exit 2 ;;
esac
