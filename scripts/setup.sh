#!/bin/bash
# Monta TODO o ambiente: verifica pre-requisitos, constroi as imagens, sobe a topologia
# e confirma com um teste de fumaca.
#   scripts/setup.sh              sobe (ou atualiza) o ambiente
#   scripts/setup.sh --limpo      derruba tudo (inclui volumes) e sobe do zero
#   scripts/setup.sh --verificar  apenas confere os pre-requisitos
source "$(dirname "$0")/lib.sh"
MODO="${1:-}"

echo "${B}== Operacao Sentinel: preparacao do ambiente ==${N}"
need docker "Instale o Docker Engine (https://docs.docker.com/engine/install/)."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 nao encontrado ('docker compose version')."
docker info >/dev/null 2>&1 || die "o daemon do Docker nao responde. Inicie-o (systemctl start docker) e confira se seu usuario esta no grupo 'docker'."
ok "docker $(docker version -f '{{.Server.Version}}' 2>/dev/null), $(docker compose version --short 2>/dev/null)"
need curl "sudo apt install curl"
need awk

if [ "$(uname -s)" != "Linux" ]; then
  warn "Este laboratorio foi preparado para Linux (injecao de falhas usa tc/netem no kernel do host)."
fi

[ -f .env ] || { cp .env.example .env; info "criado .env a partir de .env.example (HOST_PORT=$HOST_PORT, NET_PREFIX=$NET_PREFIX)"; }
mkdir -p evidencias

porta_ocupada() { command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | awk -v p=":$1\$" '$4 ~ p {f=1} END{exit !f}'; }
if [ -z "$(cid nginx)" ]; then
  for p in "$HOST_PORT" 9090 "${PAINEL_PORT:-8085}"; do
    porta_ocupada "$p" && die "a porta $p do host ja esta em uso. Libere-a ou mude HOST_PORT no .env (Prometheus: 9090; painel: PAINEL_PORT, padrao 8085)."
  done
fi
if ! docker network inspect sentinel_sentinel >/dev/null 2>&1; then
  redes="$(docker network ls -q)"
  if [ -n "$redes" ] && docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' $redes 2>/dev/null | grep -q "${NET_PREFIX}\.0/24"; then
    die "a sub-rede ${NET_PREFIX}.0/24 ja e usada por outra rede Docker. Mude NET_PREFIX no .env (ex.: 10.78.0)."
  fi
fi
ok "pre-requisitos basicos conferidos"
[ "$MODO" = "--verificar" ] && { ok "ambiente apto (falta apenas subir: scripts/setup.sh)"; exit 0; }

if [ "$MODO" = "--limpo" ]; then
  info "derrubando ambiente anterior (down -v)..."
  dc --profile trafego --profile tools down -v --remove-orphans
fi

info "construindo imagens (a primeira vez compila o Rust: 2 a 5 minutos)..."
dc --profile tools --profile trafego build || die "falha na construcao das imagens (veja a saida acima)."

info "testando suporte do kernel a tc/netem (injecao de falhas de rede)..."
if r="$(docker run --rm --cap-add NET_ADMIN sentinel-chaos:local teste 2>&1)" && [ "$r" = "ok" ]; then
  ok "kernel com prio + netem + u32"
else
  warn "injecao de falhas de rede indisponivel: $r"
  warn "No Ubuntu/Debian tente:  sudo apt install linux-modules-extra-\$(uname -r) && sudo modprobe sch_netem sch_prio cls_u32"
  warn "O restante do laboratorio funciona; apenas scripts/chaos.sh ficara indisponivel."
fi

info "subindo a topologia..."
dc up -d || die "falha ao subir. Veja: docker compose logs"

info "aguardando todos os servicos ficarem saudaveis (ate 120 s)..."
fim=$((SECONDS + 120))
while :; do
  pend="$(dc ps --format '{{.Service}} {{.State}} {{.Health}}' | awk '$2!="running" || ($3!="" && $3!="healthy") {print $1"("$2"/"$3")"}' | tr '\n' ' ')"
  [ -z "$pend" ] && break
  [ $SECONDS -ge $fim ] && { dc ps; die "tempo esgotado esperando: $pend"; }
  sleep 2
done
ok "todos os servicos de pe"

info "teste de fumaca (6 requisicoes pelo Nginx)..."
bash "$ROOT/scripts/requests.sh" 6 || die "o teste de fumaca falhou"
info "teste do painel (http://localhost:${PAINEL_PORT:-8085}/api/estado)..."
sleep 3
if curl -s -m 4 "http://127.0.0.1:${PAINEL_PORT:-8085}/api/estado" | grep -q '"monitor_ok": *true'; then ok "painel lendo o watchdog"
else warn "o painel respondeu, mas ainda nao mostra o watchdog (aguarde alguns segundos e abra o painel)"; fi

echo
dc ps
cat <<FIM

${G}Ambiente pronto.${N}
  Servico (via Nginx):  http://localhost:${HOST_PORT}/
  Prometheus (local):   http://localhost:9090/
  Painel (local):       http://localhost:${PAINEL_PORT:-8085}/
  Estado resumido:      scripts/status.sh
  Painel ao vivo:       scripts/status.sh --vivo
  Falhas de rede:       scripts/chaos.sh ajuda
  Limpeza:              scripts/clean.sh   (remover tudo, inclusive imagens e dados: scripts/remover-tudo.sh)
FIM
