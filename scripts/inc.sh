#!/bin/bash
# inc.sh - incidente guiado da Operacao Sentinel (dura cerca de 3 minutos)
#
#   scripts/inc.sh iniciar     liga o trafego de fundo e conduz o incidente, devagar, em etapas.
#                              Imprime os EVENTOS com horario real (UTC, igual aos logs).
#                              Deixe este terminal aberto e investigue em outro.
#   scripts/inc.sh eventos     mostra de novo os eventos do ultimo incidente
#   scripts/inc.sh resolver    remove tudo o que o incidente criou e para o trafego de fundo
#
# Sua tarefa: NAO leia o conteudo deste arquivo. Investigue como num incidente real, com
# status.sh, requests.sh, evidence.sh, os logs, o painel e o Prometheus, e preencha o
# relatorio da Hora 7 (linha do tempo, fatos x inferencias, hipoteses testaveis, proxima
# verificacao, decisao reversivel, recuperacao e prevencao). O incidente fica ativo ate
# alguem rodar "inc.sh resolver" (ou reiniciar algo: e uma jogada que tem custo, pense antes).
#
# Variavel opcional: INC_ESCALA=0.5 corta o tempo pela metade (uso do professor em testes).
set -u
source "$(dirname "$0")/lib.sh"

OUT="${TMPDIR:-/tmp}/sentinel-inc"; mkdir -p "$OUT"
EV="$OUT/eventos.txt"
FLAG="$OUT/trafego-iniciado-pelo-script"
ESC="${INC_ESCALA:-1}"

# parametros do cenario (codificados para nao serem lidos por acaso; nao e seguranca, e etica de laboratorio)
P="$(echo 'YWx2bz1ydXN0LWI7cHJvbnRvPTA7YXRyYXNvPTE1MDtwZXJkYT0yNQ==' | base64 -d)"
p() { echo "$P" | tr ';' '\n' | sed -n "s/^$1=//p"; }
ALVO="$(p alvo)"; PRONTO="$(p pronto)"; ATRASO="$(p atraso)"; PERDA="$(p perda)"

hms() { date -u -d "@$1" +%H:%M:%S; }
evento() { local t="$1"; shift; local l; l="$(hms "$t")  $*"; echo "${Y}[evento]${N} $l"; echo "$l" >> "$EV"; }
espera_ate() { # espera_ate <segundo-do-roteiro>   (relativo ao inicio, ajustado por INC_ESCALA)
  local alvo; alvo="$(awk -v t0="$T0" -v s="$1" -v e="$ESC" 'BEGIN{printf "%d", t0 + s*e}')"
  local agora; agora="$(date +%s)"; [ "$alvo" -gt "$agora" ] && sleep $((alvo - agora)); return 0
}
estado_wd() { tbx curl -s -m 3 http://watchdog:9100/state 2>/dev/null | jq -r ".alvos[\"$1\"].state" 2>/dev/null; }

aplicar_rede() { # aplicar_rede <no> <destino> <atraso_ms> <perda_pct>
  local id dip band; id="$(cid "$1")"; [ -n "$id" ] || die "$1 nao esta em execucao"
  dip="$(ip_de "$(cid "$2")")"; band="$(banda_de "$2")"
  docker run --rm --cap-add NET_ADMIN --network "container:$id" \
    -e DST_IP="$dip" -e DST_BAND="$band" -e DST_NAME="$2" -e NAME_MAP="$(mapa_nomes)" \
    sentinel-chaos:local aplicar "$3" 0 "$4" >/dev/null || die "falha ao aplicar a regra de rede (modulos tc do host?)"
}
limpar_rede() { local id; id="$(cid "$1")"; [ -n "$id" ] || return 0
  docker run --rm --cap-add NET_ADMIN --network "container:$id" sentinel-chaos:local limpar >/dev/null 2>&1; }
definir_pronto() { tbx curl -s -m 3 "http://$ALVO:8080/admin/ready?v=$1" >/dev/null 2>&1; }

iniciar() {
  exigir_pilha
  need jq "Instale o jq."
  [ "$(estado_wd rust-a)" = "up" ] && [ "$(estado_wd rust-b)" = "up" ] \
    || die "o watchdog nao informa A e B em UP. Normalize o ambiente (scripts/status.sh; inc.sh resolver) e tente de novo."
  docker image inspect sentinel-chaos:local >/dev/null 2>&1 || dc --profile tools build chaos >/dev/null || die "falha ao construir sentinel-chaos"
  : > "$EV"
  if [ -z "$(cid trafego)" ]; then
    TRAFEGO_RATE=3 dc --profile trafego up -d trafego >/dev/null && touch "$FLAG"
  fi
  T0="$(date +%s)"
  echo "${B}== INCIDENTE EM ANDAMENTO (cerca de 3 min). Anote os horarios; investigue em outro terminal. ==${N}"
  evento "$T0" "Inicio do exercicio. Trafego de fundo: 3 req/s. Sistema em estado normal."

  # ---- etapa 1: aos 20 s ---------------------------------------------------------
  espera_ate 20
  definir_pronto "$PRONTO"

  # ---- evento 1: o watchdog percebe (horario real do log) --------------------------
  local fim=$((SECONDS + 90)) linha E0
  while [ "$(estado_wd "$ALVO")" != "down" ] && [ $SECONDS -lt $fim ]; do sleep 1; done
  linha="$(dc logs --no-color --no-log-prefix --since 5m watchdog 2>/dev/null | grep "event=state_change target=$ALVO from=up to=down" | tail -1 | awk '{print $1}')"
  E0="$(date -u -d "${linha:-$(agora)}" +%s)"
  evento "$E0" "O watchdog marca Rust B como DOWN apos tres verificacoes consecutivas sem sucesso."

  # ---- evento 2: o usuario nao percebe ---------------------------------------------
  espera_ate 70
  evento "$(date +%s)" "O Nginx continua registrando respostas 200 em requisicoes encaminhadas a Rust B."

  # ---- etapa 2: aos 100 s ----------------------------------------------------------
  espera_ate 100
  aplicar_rede "$ALVO" nginx "$ATRASO" "$PERDA"
  evento "$(date +%s)" "O tempo de resposta visto pelo usuario aumenta; algumas requisicoes passam a ser repetidas em outro no."

  # ---- evento 4: o painel e o balanceador discordam --------------------------------
  espera_ate 150
  evento "$(date +%s)" "O painel (porta 8085) mostra Rust B em vermelho, mas o Nginx segue incluindo Rust B entre os destinos."

  espera_ate 180
  evento "$(date +%s)" "Fim da injecao. O sistema permanece no estado atual ate alguem agir (inc.sh resolver)."
  echo
  ok "incidente completo. Eventos salvos em $EV (inc.sh eventos). Para encerrar: scripts/inc.sh resolver"
}

eventos() { [ -s "$EV" ] && cat "$EV" || die "ainda nao ha eventos (rode: scripts/inc.sh iniciar)"; }

resolver() {
  exigir_pilha
  definir_pronto 1
  limpar_rede rust-b; limpar_rede rust-a; limpar_rede watchdog
  if [ -f "$FLAG" ]; then
    dc --profile trafego stop trafego >/dev/null 2>&1; dc --profile trafego rm -f trafego >/dev/null 2>&1
    rm -f "$FLAG"; echo "trafego de fundo parado"
  fi
  ok "incidente encerrado. Aguarde cerca de 20 s para o watchdog voltar a UP."
}

case "${1:-}" in
  iniciar)  iniciar;;
  eventos)  eventos;;
  resolver) resolver;;
  *) uso "$0"; exit 2;;
esac
