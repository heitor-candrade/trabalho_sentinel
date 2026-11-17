#!/bin/bash
# Desliga TODOS os contêineres do laboratorio e REMOVE tudo que pertence a ele: contêineres,
# rede, volumes e imagens locais. Opcionalmente tambem os dados (evidencias/), o cache de
# build e as imagens-base baixadas. Atua SOMENTE no projeto "sentinel" e dentro desta pasta.
#   scripts/remover-tudo.sh [opcoes]
#     (sem opcoes)    contêineres (todos os perfis), contêineres do chaos, rede, volumes e
#                     imagens sentinel-*:local. PRESERVA evidencias/, .env, codigo e alerts.yml
#     --evidencias    apaga tambem o conteudo de evidencias/ e /tmp/sentinel-incidente
#     --imagens-base  remove tambem as imagens-base (nginx, prometheus, python, alpine, debian, rust);
#                     outros projetos que as usem terao de baixa-las de novo
#     --cache         limpa o cache de build do Docker (afeta todos os projetos, nao so este)
#     --tudo          = --evidencias --imagens-base --cache, mais .env e rust-*/target (compilacao local)
#     --simular       apenas MOSTRA o que seria removido (nada e apagado)
#     --sim           nao pede confirmacao (use em automacao)
# Para recomecar do zero depois:  scripts/setup.sh
source "$(dirname "$0")/lib.sh"
EVID=0; BASE=0; CACHE=0; TUDO=0; SIMULAR=0; SIM=0
for a in "$@"; do
  case "$a" in
    --evidencias) EVID=1;; --imagens-base) BASE=1;; --cache) CACHE=1;;
    --tudo) EVID=1; BASE=1; CACHE=1; TUDO=1;;
    --simular) SIMULAR=1;; --sim) SIM=1;;
    -h|--help) uso "$0"; exit 0;;
    *) die "opcao desconhecida: $a (veja: scripts/remover-tudo.sh --help)";;
  esac
done
need docker "Instale o Docker Engine."
docker info >/dev/null 2>&1 || die "o daemon do Docker nao responde (ou seu usuario nao esta no grupo 'docker')."
grep -q '^name: sentinel' docker-compose.yml 2>/dev/null || die "execute dentro do projeto Sentinel (docker-compose.yml com 'name: sentinel' nao encontrado)."

PROJ="label=com.docker.compose.project=sentinel"
INC_DIR="${TMPDIR:-/tmp}/sentinel-incidente"
BASES="nginx:1.27-alpine prom/prometheus:v2.53.0 python:3.12-alpine python:3.12-slim-bookworm alpine:3.20 debian:bookworm-slim rust:1.88-slim-bookworm"

CONT="$( { docker ps -aq --filter "$PROJ"; docker ps -aq --filter ancestor=sentinel-chaos:local; } | sort -u)"
REDES="$(docker network ls -q --filter "$PROJ")"
VOLS="$(docker volume ls -q --filter "$PROJ")"
IMGS="$(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -E '^sentinel-[a-z-]+:local$' | sort -u)"
lista() { if [ -n "$1" ]; then echo "$1" | tr '\n' ' '; else echo "nenhum"; fi; }
NOMES_C="$(for c in $CONT; do docker ps -a --filter "id=$c" --format '{{.Names}}'; done)"
NOMES_R="$(for r in $REDES; do docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' "$r"; done)"

echo "${B}== Operacao Sentinel: remocao completa ==${N}"
echo "Sera removido (somente deste projeto):"
echo "  contêineres : $(lista "$NOMES_C")"
echo "  redes       : $(lista "$NOMES_R")"
echo "  volumes     : $(lista "$VOLS")"
echo "  imagens     : $(lista "$IMGS")"
[ $EVID -eq 1 ]  && echo "  dados       : conteudo de evidencias/ (mantem .gitkeep) e $INC_DIR"
[ $BASE -eq 1 ]  && echo "  imagens-base: $BASES (as que outros contêineres usam sao preservadas pelo Docker)"
[ $CACHE -eq 1 ] && echo "  cache       : cache de build do Docker (todos os projetos)"
[ $TUDO -eq 1 ]  && echo "  arquivos    : .env, rust-a/target, rust-b/target"
echo "Nao sera tocado: codigo, nginx/, prometheus/alerts.yml$([ $EVID -eq 0 ] && echo ', evidencias/')$([ $TUDO -eq 0 ] && echo ', .env')."

[ $SIMULAR -eq 1 ] && { info "modo --simular: nada foi removido."; exit 0; }
if [ $SIM -eq 0 ]; then
  [ -t 0 ] || die "sem terminal para confirmar: use --sim (ou --simular para so ver o plano)."
  read -r -p "Digite REMOVER para confirmar: " r
  [ "$r" = "REMOVER" ] || { info "cancelado, nada foi removido."; exit 0; }
fi

registrar acoes.log "remover-tudo.sh $*" 2>/dev/null || true
info "derrubando a topologia (todos os perfis)..."
docker compose --profile trafego --profile tools down -v --remove-orphans --timeout 5 >/dev/null 2>&1 || true
# o que sobrar (contêineres do chaos, rede ou volume orfaos)
CONT="$( { docker ps -aq --filter "$PROJ"; docker ps -aq --filter ancestor=sentinel-chaos:local; } | sort -u)"
[ -n "$CONT" ] && docker rm -f -v $CONT >/dev/null 2>&1 && ok "contêineres removidos"
for r in $(docker network ls -q --filter "$PROJ"); do docker network rm "$r" >/dev/null 2>&1 && ok "rede removida: $r"; done
for v in $(docker volume ls -q --filter "$PROJ"); do docker volume rm -f "$v" >/dev/null 2>&1 && ok "volume removido: $v"; done
for i in $IMGS; do docker image rm -f "$i" >/dev/null 2>&1 && ok "imagem removida: $i"; done
docker image prune -f --filter "label=com.docker.compose.project=sentinel" >/dev/null 2>&1 || true

if [ $BASE -eq 1 ]; then
  for i in $BASES; do docker image rm "$i" >/dev/null 2>&1 && ok "imagem-base removida: $i" || true; done
fi
[ $CACHE -eq 1 ] && { docker builder prune -af >/dev/null 2>&1 && ok "cache de build limpo"; }
if [ $EVID -eq 1 ]; then
  mkdir -p evidencias && find evidencias -mindepth 1 ! -name .gitkeep -delete && touch evidencias/.gitkeep && ok "evidencias/ esvaziada"
  [ "$INC_DIR" = "${TMPDIR:-/tmp}/sentinel-incidente" ] && rm -rf -- "$INC_DIR" && ok "removido $INC_DIR"
fi
if [ $TUDO -eq 1 ]; then
  rm -rf -- rust-a/target rust-b/target && ok "compilacao local (rust-*/target) removida"
  rm -f -- .env && ok ".env removido (o setup.sh o recria)"
fi

echo
info "conferencia final (esperado: nada listado abaixo)"
docker ps -a --filter "$PROJ" --format '  contêiner restante: {{.Names}} ({{.Status}})'
docker network ls --filter "$PROJ" --format '  rede restante: {{.Name}}'
docker volume ls --filter "$PROJ" --format '  volume restante: {{.Name}}'
docker image ls --format '  imagem restante: {{.Repository}}:{{.Tag}}' | grep -E 'sentinel-[a-z-]+:local' || true
ok "remocao concluida. Para subir de novo: scripts/setup.sh"
