#!/bin/bash
# Preserva EVIDENCIAS antes de reiniciar ou alterar qualquer coisa (regra de ouro 8).
# Cria evidencias/AAAAMMDD-HHMMSS_<rotulo>/ com: estado dos contêineres (inclui contagem
# de reinicios), logs com horario, metricas, estado do watchdog, alertas, SLIs e a analise
# do que o usuario viu.
#   scripts/evidence.sh [rotulo] [--desde 10m] [--rede]
#   --rede  inclui as regras de rede ativas (tc) de cada contêiner (use quando suspeitar de rede)
source "$(dirname "$0")/lib.sh"
exigir_pilha
ROT="manual"; DESDE="10m"; REDE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --desde) DESDE="$2"; shift 2;;
    --rede) REDE=1; shift;;
    -h|--help) uso "$0"; exit 0;;
    *) ROT="$1"; shift;;
  esac
done
DIR="evidencias/$(agora_arq)_${ROT}"
mkdir -p "$DIR"
T0="$(agora)"
{ echo "rotulo=$ROT"; echo "instante_utc=$T0"; echo "janela_dos_logs=$DESDE"; echo "host=$(hostname)"; echo "kernel=$(uname -r)"
  git rev-parse --short HEAD 2>/dev/null | sed 's/^/commit=/'; } > "$DIR/meta.txt"

dc --profile trafego ps -a > "$DIR/compose-ps.txt" 2>&1
: > "$DIR/conteineres-estado.txt"
for s in nginx rust-a rust-b watchdog prometheus painel toolbox trafego; do
  id="$(dc --profile trafego ps -a -q "$s" 2>/dev/null | head -1)"; [ -n "$id" ] || continue
  docker inspect -f "$s status={{.State.Status}} saude={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} exit={{.State.ExitCode}} reinicios={{.RestartCount}} oom={{.State.OOMKilled}} iniciou={{.State.StartedAt}} terminou={{.State.FinishedAt}}" "$id" >> "$DIR/conteineres-estado.txt"
done
for s in nginx rust-a rust-b watchdog prometheus painel trafego; do
  dc --profile trafego logs --no-color --timestamps --since "$DESDE" "$s" > "$DIR/log-$s.txt" 2>&1
  [ -s "$DIR/log-$s.txt" ] || rm -f "$DIR/log-$s.txt"
done
if [ -n "$(cid toolbox)" ]; then
  tbx curl -s -m 3 http://watchdog:9100/state   > "$DIR/watchdog-state.json"    2>&1
  tbx curl -s -m 3 http://watchdog:9100/metrics > "$DIR/watchdog-metrics.txt"   2>&1
  tbx curl -s -m 3 http://rust-a:8080/metrics   > "$DIR/rust-a-metrics.txt"     2>&1
  tbx curl -s -m 3 http://rust-b:8080/metrics   > "$DIR/rust-b-metrics.txt"     2>&1
  tbx /opt/sentinel/admin.sh status             > "$DIR/rust-admin-status.txt"  2>&1
  tbx curl -s -m 3 http://nginx:8081/stub_status > "$DIR/nginx-stub-status.txt" 2>&1
  tbx curl -s -m 3 http://prometheus:9090/api/v1/alerts  > "$DIR/prometheus-alerts.json"  2>&1
  tbx curl -s -m 3 http://prometheus:9090/api/v1/targets > "$DIR/prometheus-targets.json" 2>&1
  tbx /opt/sentinel/sli.sh                      > "$DIR/sli.txt"                2>&1
  tbx /opt/sentinel/snapshot.sh                 > "$DIR/snapshot.txt"           2>&1
fi
analisar --desde "$DESDE" > "$DIR/analise-nginx.txt" 2>&1
[ -n "$(cid trafego)" ] && analisar --servico trafego --desde "$DESDE" > "$DIR/analise-trafego.txt" 2>&1
[ -f evidencias/chaos.log ] && cp evidencias/chaos.log "$DIR/chaos.log"
[ -f evidencias/acoes.log ] && cp evidencias/acoes.log "$DIR/acoes.log"
[ "$REDE" -eq 1 ] && bash "$ROOT/scripts/chaos.sh" status todos > "$DIR/rede-tc.txt" 2>&1

echo "- $T0  $DIR  (rotulo: $ROT, logs: $DESDE)" >> evidencias/INDEX.md
ok "evidencias salvas em $DIR"
ls -1 "$DIR" | sed 's/^/   /'
