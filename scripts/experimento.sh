#!/bin/bash
# Roda um experimento de resiliencia no ciclo: PREVER -> OBSERVAR -> COMPARAR.
#   scripts/experimento.sh lista
#   scripts/experimento.sh <n> [--sem-previsao] [--auto]
#     --sem-previsao  nao pede a previsao (apenas para ensaio do professor)
#     --auto          nao espera ENTER (ensaio/automacao)
# Em cada experimento o script: guarda sua previsao com horario; mede o ESTADO ANTES;
# injeta UMA falha; espera o efeito; mede DURANTE; recupera; mede DEPOIS e confere a
# recuperacao. Tudo vai para evidencias/exp<n>_<data>/ (linha-do-tempo.txt, antes.txt...).
source "$(dirname "$0")/lib.sh"

lista() { cat <<'L'
 1  Parar o Rust A                     (docker compose stop rust-a)            [matriz E, obrigatorio]
 2  Latencia alta no Rust A (2500 ms)  (/admin/atraso, dentro da rede)         [matriz E, obrigatorio]
 3  Interromper o watchdog             (quem vigia o vigia?)                   [matriz E, obrigatorio]
 4  Respostas de erro (GET /erro)      (taxa de erro 5xx)                      [matriz E, obrigatorio]

 Extras (rede): faca a mesma coisa com scripts/chaos.sh (atraso | perda | particao), escrevendo
 antes a previsao e salvando o antes/durante/depois com scripts/evidence.sh.
L
}
[ "${1:-}" = "lista" ] || [ $# -eq 0 ] && { lista; exit 0; }
N="$1"; shift
PREV=1; AUTO=0
for a in "$@"; do case "$a" in --sem-previsao) PREV=0;; --auto) AUTO=1;; esac; done
exigir_pilha

DIR="evidencias/exp${N}_$(agora_arq)"; mkdir -p "$DIR"
tl() { echo "$(agora) $*" | tee -a "$DIR/linha-do-tempo.txt"; }
pausa() { [ "$AUTO" -eq 1 ] || [ ! -t 0 ] || read -r -p "$1" _; }
espera() { # espera <segundos> <motivo>
  tl "aguardando ${1}s: $2"; local i; for ((i = $1; i > 0; i--)); do printf '\r   %3ds ' "$i"; sleep 1; done; printf '\r         \r'; }
snap() { # snap <nome>
  { echo "### $1 -- $(agora)"
    echo "--- 20 requisicoes pelo Nginx"; REQ_RESUMO=1 bash "$ROOT/scripts/requests.sh" 20
    echo "--- estado"; tbx /opt/sentinel/snapshot.sh 2>&1
    echo "--- contêineres"; dc ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}'
    echo "--- reinicios"; for s in nginx rust-a rust-b watchdog; do docker inspect -f "$s reinicios={{.RestartCount}} iniciou={{.State.StartedAt}}" "$(cid "$s")" 2>/dev/null; done
  } > "$DIR/$1.txt" 2>&1
  sed -n '/--- 20 requisicoes/,/--- estado/p' "$DIR/$1.txt" | grep -v -e '^---'
}
wd_down() { tbx curl -s -m 3 http://watchdog:9100/state | jq -r '[.alvos[] | select(.state=="down")] | length' 2>/dev/null; }
esperar_wd_up() { local fim=$((SECONDS + 60)); while [ $SECONDS -lt $fim ]; do [ "$(wd_down)" = "0" ] && return 0; sleep 2; done; return 1; }

case "$N" in
  1) TIT="Parar o Rust A";                     HIP="Se o Rust A for parado, o Nginx continua respondendo pelo Rust B; algumas requisicoes iniciais podem atrasar (timeout/retry); o watchdog marca A como DOWN apos ~3 falhas.";;
  2) TIT="Latencia alta no Rust A (2500 ms)";  HIP="Com 2500 ms de atraso no app, o Nginx (read timeout 3 s) ainda recebe resposta, mas o watchdog (timeout 2 s) marca A como DOWN: lento nao e o mesmo que parado.";;
  3) TIT="Interromper o watchdog";             HIP="Sem o watchdog, o servico segue normal; ninguem mais avalia os nos; so um alerta sobre o PROPRIO monitor denuncia o problema.";;
  4) TIT="Respostas de erro (GET /erro)";      HIP="Requisicoes a /erro retornam 500; o Nginx NAO faz retry em 500 (so error/timeout/502/503); a taxa de erro das metricas sobe proporcionalmente.";;
  *) die "experimento invalido: $N (veja: scripts/experimento.sh lista)";;
esac

echo "${B}=== Experimento $N: $TIT ===${N}"
echo "Saida em: $DIR"
echo
echo "Formato da previsao:  Se [evento], entao [efeito], porque [mecanismo]."
echo "(Dica de partida, NAO copie sem pensar:)  $HIP" | fold -s -w 100 | sed '1!s/^/    /'
if [ "$PREV" -eq 1 ] && [ "$AUTO" -eq 0 ] && [ -t 0 ]; then
  read -r -p "Sua PREVISAO (uma linha, antes de injetar a falha): " P
  [ -n "$P" ] || die "previsao vazia: sem previsao nao ha experimento (use --sem-previsao so para ensaio)."
  echo "$(agora) PREVISAO: $P" | tee "$DIR/previsao.txt" >/dev/null
fi
tl "experimento $N iniciado: $TIT"
tl "ANTES: coletando linha de base"; snap antes
pausa "ENTER para INJETAR a falha... "

tl "INJETANDO a falha"
case "$N" in
  1) registrar acoes.log "exp1 stop rust-a"; dc stop rust-a >/dev/null; ESP=25; MOTIVO="3 falhas x 5 s do watchdog + timeout";;
  2) tbx /opt/sentinel/admin.sh atraso rust-a 2500; ESP=25; MOTIVO="3 sondagens estouram o timeout de 2 s";;
  3) dc stop watchdog >/dev/null; ESP=40; MOTIVO="idade da ultima sondagem passa de 30 s";;
  4) for i in $(seq 30); do curl -s -m 5 -o /dev/null "http://localhost:${HOST_PORT}/erro"; curl -s -m 5 -o /dev/null "http://localhost:${HOST_PORT}/"; done; ESP=15; MOTIVO="janela de 1-2 min das taxas";;
esac
tl "falha injetada"
espera "$ESP" "$MOTIVO"
tl "DURANTE: observando"; snap durante
case "$N" in
  3) echo "--- Prometheus: o alvo watchdog ainda e coletado?"; tbx /opt/sentinel/promq.sh 'up{job="watchdog"}'
     echo "--- Prometheus: idade da ultima sondagem (sem dados se a serie sumiu)"; tbx /opt/sentinel/promq.sh 'time() - watchdog_last_probe_timestamp_seconds';;
  4) echo "--- taxa de erro vista pelo Prometheus"; tbx /opt/sentinel/sli.sh 2>&1 | sed -n '/Taxa de erro/,/Latencia/p';;
esac
echo "--- eventos do watchdog desde a injecao"; dc logs --no-color --no-log-prefix --since 90s watchdog 2>/dev/null | grep -E "state_change|reason=" | tail -6
echo "--- o que o usuario viu (Nginx, 60 s)"; analisar --desde 60s | tee "$DIR/nginx-durante.txt"
echo
echo "Agora compare com a sua PREVISAO. Confirmou? Em que ponto divergiu e por que?"
pausa "ENTER para RECUPERAR... "

tl "RECUPERANDO"
case "$N" in
  1) dc start rust-a >/dev/null;;
  2) tbx /opt/sentinel/admin.sh atraso rust-a 0;;
  3) dc start watchdog >/dev/null;;
  4) :;;
esac
tl "aguardando o retorno do servico (ate 60 s)"
if esperar_wd_up; then tl "RECUPERADO: watchdog informa todos os nos UP"; else tl "ATENCAO: o watchdog ainda reporta no DOWN apos 60 s"; fi
sleep 3; tl "DEPOIS: confirmando a recuperacao"; snap depois
echo "--- reinicios (esperado: sem reinicio em loop)"; grep reinicios "$DIR/depois.txt"
echo
ok "experimento $N concluido. Evidencias em $DIR/"
cat <<FIM

Linha para a matriz de experimentos (item E):
  Hipotese:   (sua previsao: $DIR/previsao.txt)
  Procedimento: scripts/experimento.sh $N   (${TIT})
  Esperado:   (o que voce previu)
  Evidencia:  $DIR/durante.txt e nginx-durante.txt
  Conclusao:  (confirmada / refutada / parcial -- e POR QUE)
FIM
