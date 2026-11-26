#!/bin/bash
# lib.sh - funcoes comuns aos scripts do laboratorio (use: source "$(dirname "$0")/lib.sh")
# Todos os scripts rodam a partir da raiz do projeto, em qualquer diretorio de chamada.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Windows (Git Bash/MSYS): impede que caminhos Linux passados ao docker
# (ex.: /opt/sentinel/admin.sh) sejam reescritos como C:/Program Files/Git/...
export MSYS_NO_PATHCONV=1

if [ -t 1 ]; then R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'; else R=; G=; Y=; C=; B=; N=; fi
info() { echo "${C}[info]${N} $*"; }
ok()   { echo "${G}[ ok ]${N} $*"; }
warn() { echo "${Y}[aviso]${N} $*" >&2; }
erro() { echo "${R}[erro]${N} $*" >&2; }
die()  { erro "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' nao encontrado. ${2:-}"; }

if [ -f .env ]; then set -a; . ./.env; set +a; fi
HOST_PORT="${HOST_PORT:-8080}"
NET_PREFIX="${NET_PREFIX:-10.9.8}"
export HOST_PORT NET_PREFIX

SERVICOS_REDE="nginx rust-a rust-b watchdog prometheus toolbox trafego painel"

dc()  { docker compose "$@"; }
tbx() { docker compose exec -T toolbox "$@"; }               # comando dentro do contêiner de operacao
cid() { docker compose ps -q "$1" 2>/dev/null | head -1; }     # id do contêiner em execucao de um servico
ip_de() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null; }
agora() { date -u +%Y-%m-%dT%H:%M:%SZ; }
agora_arq() { date -u +%Y%m%d-%H%M%S; }
banda_de() { case "$1" in nginx) echo 2;; rust-a) echo 3;; rust-b) echo 4;; watchdog) echo 5;; prometheus) echo 6;; toolbox) echo 7;; trafego) echo 8;; painel) echo 10;; *) echo 9;; esac; }

# mapa "ip=servico" dos contêineres em execucao (para exibir nomes no status de rede)
mapa_nomes() {
  local s id ip out=""
  for s in $SERVICOS_REDE; do
    id="$(cid "$s")"; [ -n "$id" ] || continue
    ip="$(ip_de "$id")"; [ -n "$ip" ] && out="$out $ip=$s"
  done
  echo "$out"
}

exigir_pilha() {
  need docker "Instale o Docker Engine."
  docker info >/dev/null 2>&1 || die "o daemon do Docker nao responde (ou seu usuario nao esta no grupo 'docker')."
  [ -n "$(cid nginx)" ] || die "a pilha nao esta no ar. Rode: scripts/setup.sh"
}

registrar() { # registrar <arquivo-de-log> <mensagem...>  (evidencia na hora em que acontece)
  local arq="$1"; shift
  mkdir -p evidencias
  echo "$(agora) $*" >> "evidencias/$arq"
}

# imprime o bloco de comentarios do inicio de um script (usado como ajuda)
uso() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"; }

# analisar [--desde 5m] [--servico nginx|trafego] [--arquivo log.txt] [--compacto]
# Resume o que o USUARIO viu, a partir dos logs do Nginx (ou do gerador de trafego).
# Disponibilidade = respostas com status 100-499 (sem 5xx e sem falha de conexao).
analisar() {
  local DESDE=5m SERV=nginx ARQ="" COMPACTO=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --desde) DESDE="$2"; shift 2;;
      --servico) SERV="$2"; shift 2;;
      --arquivo) ARQ="$2"; shift 2;;
      --compacto) COMPACTO=1; shift;;
      *) die "opcao desconhecida: $1";;
    esac
  done
  local tsv tmpt; tsv="$(mktemp)"; tmpt="$(mktemp)"
  if [ -n "$ARQ" ]; then cat "$ARQ"; else dc --profile trafego logs --no-color --no-log-prefix --since "$DESDE" "$SERV" 2>/dev/null; fi |
  awk -v serv="$SERV" '
    function parse(line,   n, i, t, p, key, tok) {
      delete kv; n = split(line, tok, " "); key = ""
      for (i = 1; i <= n; i++) {
        t = tok[i]; p = index(t, "=")
        if (p > 1 && t ~ /^[a-z_]+=/) { key = substr(t, 1, p - 1); kv[key] = substr(t, p + 1) }
        else if (key != "") kv[key] = kv[key] " " t
      }
    }
    / nginx INFO request_id=/ { parse($0); nd = kv["node"]; if (nd == "" || nd == "-") nd = "(nenhum)";
        printf "%s\t%s\t%d\t%s\n", kv["status"], nd, (kv["upstream"] ~ /,/) ? 1 : 0, kv["req_time"]; next }
    / traffic (INFO|WARN) status=/ { parse($0); nd = kv["node"]; if (nd == "" || nd == "-") nd = "(nenhum)";
        printf "%s\t%s\t0\t%.3f\n", kv["status"], nd, kv["latency_ms"] / 1000; next }
  ' > "$tsv"

  awk -F'\t' -v tmp="$tmpt" -v desde="$DESDE" -v serv="$SERV" -v compacto="$COMPACTO" '
    function ordenar(a, k,   i, j, n, t) { n = 0; for (i in a) k[++n] = i
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (k[j] < k[i]) { t = k[i]; k[i] = k[j]; k[j] = t }
      return n }
    { n++; st[$1]++; nd[$2]++; if ($3 == 1) retry++; if ($1 ~ /^[1-4][0-9][0-9]$/) ok++; soma += $4; if ($4 + 0 > max) max = $4 + 0; print $4 > tmp }
    END {
      if (n == 0) { printf "(nenhuma requisicao de %s nos ultimos %s)\n", serv, desde; exit }
      close(tmp); cmd = "sort -n " tmp; i = 0; while ((cmd | getline v) > 0) a[++i] = v; close(cmd)
      p50i = int(0.50 * i); if (p50i < 0.50 * i) p50i++; p95i = int(0.95 * i); if (p95i < 0.95 * i) p95i++
      if (compacto == 0) printf "janela: ultimos %s | fonte: %s | requisicoes: %d\n", desde, serv, n
      else printf "  fonte=%s janela=%s requisicoes=%d\n", serv, desde, n
      k0 = ordenar(nd, k); printf "  por no:       "; for (j = 1; j <= k0; j++) printf "%s %d (%.0f%%)   ", k[j], nd[k[j]], 100 * nd[k[j]] / n; printf "\n"
      delete k; k0 = ordenar(st, k); printf "  por status:   "; for (j = 1; j <= k0; j++) printf "%s=%d  ", k[j], st[k[j]]; printf "\n"
      printf "  com retry:    %d (%.1f%%)   disponibilidade: %.1f%%\n", retry, 100 * retry / n, 100 * ok / n
      printf "  latencia (s): media %.3f  p50 %.3f  p95 %.3f  max %.3f\n", soma / n, a[p50i], a[p95i], max
    }' "$tsv"
  rm -f "$tsv" "$tmpt"
}

# valida (nginx -t) e recarrega o Nginx sem derrubar conexoes
recarregar_nginx() {
  local ngx=/etc/nginx/sentinel/nginx.conf
  dc exec -T nginx nginx -t -c "$ngx" 2>&1 | sed 's/^/   nginx -t: /'
  [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
  dc exec -T nginx nginx -c "$ngx" -s reload && ok "Nginx recarregado ($(agora))"
}
