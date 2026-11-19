# Operação Sentinel — Cluster Distribuído Resiliente

FEELT37802 – Sistemas Distribuídos 2026/2 · Prof. Renato Carrijo

Laboratório em Docker Compose: **Nginx** (proxy reverso) → **2 nós Rust heterogêneos** (A: `actix-web`, B: `axum`) · **watchdog**
independente (Python) · **Prometheus** · **painel** (FastAPI + uvicorn) · **toolbox** (contêiner de operação) ·
**chaos** (injeção de falhas de rede com `tc netem`).

> A rede é simulada pelo Docker em **uma única máquina Linux**. Isso não equivale a várias
> máquinas, zonas de disponibilidade ou uma rede real. Nada de carga agressiva nem testes
> fora dos contêineres deste projeto.

## Início rápido

```bash
scripts/setup.sh          # verifica pré-requisitos, constrói imagens, sobe tudo, teste de fumaça
scripts/status.sh         # estado dos contêineres, watchdog, nós, Prometheus, Nginx
scripts/status.sh --vivo  # painel ao vivo no terminal (Ctrl+C sai)
curl -i http://localhost:8080/
# painel (somente leitura, só em 127.0.0.1): http://localhost:8085/
```

Pré-requisitos: Linux, Docker Engine + Compose v2, `curl`, `awk`, `bash`. Para falhas de rede:
módulos de kernel `sch_netem`, `sch_prio`, `cls_u32`
(Ubuntu: `sudo apt install linux-modules-extra-$(uname -r) && sudo modprobe sch_netem sch_prio cls_u32`).

## Mapa do repositório

| Caminho | Conteúdo |
|---|---|
| `docker-compose.yml` | topologia (rede `10.9.8.0/24`, IPs fixos, só Nginx e Prometheus publicados) |
| `nginx/nginx.conf` | proxy reverso comentado (item C): log com `request_id`, timeouts, retry limitado |
| `rust-a/` · `rust-b/` | nós Rust com o **mesmo contrato** (`/`, `/erro`, `/health/live`, `/health/ready`, `/metrics`, `/admin/*`): A em **actix-web**, B em **axum** |
| `painel/` | página dinâmica (FastAPI + uvicorn, porta 8085): arquitetura, estado dos nós, gráfico de latência e alertas, tudo a partir do `/state` do watchdog |
| `watchdog/` | monitor: sonda `/health/ready`, conta falhas, marca DOWN/UP, expõe `:9100/metrics` e `/state` |
| `prometheus/` | `prometheus.yml`, `alerts.yml` (**a completar pela equipe**), `alerts.exemplo.yml` |
| `toolbox/` | imagem de operação + scripts dentro da rede (`admin.sh`, `promq.sh`, `sli.sh`, `snapshot.sh`, `traffic.sh`) |
| `chaos/` | imagem com `tc` e `tcpdump` anexada, sob demanda, à rede de um contêiner |
| `scripts/` | scripts do host (tabela abaixo) |
| `evidencias/` | **saídas de comandos e logs** (versione!) |
| `docs/` | roteiro (`.tex`/`.pdf`) e documentos da equipe (diagrama, plano, matriz, relatório, slides) |

## Scripts (`scripts/`)

| Script | Para quê |
|---|---|
| `setup.sh [--limpo\|--verificar]` | monta o ambiente inteiro (pré-requisitos, build com Rust, sobe, teste de fumaça) |
| `clean.sh [--tudo]` | derruba a topologia (só deste projeto); `--tudo` remove volumes e imagens locais |
| `status.sh [--vivo [s]\|--usuario [--desde 5m]]` | retrato do estado; painel ao vivo; o que o **usuário** viu (nós, retries, disponibilidade, p50/p95) |
| `requests.sh [N] [caminho]` · `requests.sh fundo start\|stop\|status\|logs` | N requisições (nó, status, tempo, `request_id`); tráfego de fundo baixo (3 req/s) |
| `admin.sh status\|ready\|atraso` · `admin.sh pool status\|drenar\|restaurar <nó>` | controla os nós pela rede interna; tira/devolve um nó do Nginx (reversível) |
| `chaos.sh atraso\|perda\|particao\|limpar\|status\|captura` | **falhas de rede** (`tc netem`), opcionalmente só entre dois pontos (`--para`) |
| `evidence.sh [rótulo] [--rede]` | preserva evidências **antes** de reiniciar algo |
| `experimento.sh <1-4>` | experimentos guiados *prever → observar → comparar* (`lista` mostra os 4) |
| `validar.sh [--recarregar]` | valida compose, `nginx -t`, `promtool`, scripts; com a opção, recarrega Nginx e Prometheus |
| `remover-tudo.sh [--simular\|--evidencias\|--imagens-base\|--cache\|--tudo]` | desliga **e remove** contêineres, rede, volumes e imagens do projeto; opções apagam também dados, cache e imagens-base |
- `scripts/inc.sh` — incidente guiado de ~3 min (use só quando o professor pedir; não leia o código). `iniciar`, `eventos`, `resolver`.
| `selftest.sh` | auto-verificação (~3 min; **somente professor**, não vai no pacote do aluno) |

## Fluxo de uma requisição

1. `curl` → Nginx (`:8080` no host, `:80` no contêiner). 2. O Nginx gera `request_id`, escolhe um
nó (round-robin) e repassa com `X-Request-Id`. 3. O nó Rust responde `atendido por rust-a|b`,
registra o `request_id` e devolve `X-Node`. 4. O Nginx registra nó, status e tempos.
5. Falha de conexão/timeout/502/503 → no máximo **uma** nova tentativa em outro nó.

## Operações do dia a dia

```bash
docker compose ps                         # estado
docker compose logs -f nginx rust-a rust-b watchdog   # seguir logs
docker compose stop rust-a                # derrubar um nó
docker compose start rust-a               # recuperar
scripts/admin.sh ready rust-a 0           # vivo, mas NÃO pronto (live 200, ready 503)
scripts/admin.sh atraso rust-a 2500       # latência artificial (ms)
scripts/admin.sh pool drenar rust-a       # tira A do Nginx (desfaz: pool restaurar rust-a)
scripts/chaos.sh atraso rust-a 800        # atraso de REDE de 800 ms nas respostas de A
scripts/chaos.sh perda rust-a 30          # 30% de perda de pacotes nas respostas de A
scripts/chaos.sh particao rust-a          # A vivo, porém isolado da rede
scripts/chaos.sh status                   # regras de rede ativas
scripts/chaos.sh limpar todos             # remove todas as falhas de rede
scripts/evidence.sh antes-de-reiniciar    # evidências ANTES de qualquer reinício
```

Falhas de rede somem ao **recriar** o contêiner e com `chaos.sh limpar`. Elas atuam na **saída**
do contêiner escolhido (equivale a atrasar/perder as *respostas* dele).

## Recuperação e limpeza

```bash
scripts/chaos.sh limpar todos && scripts/admin.sh ready rust-a 1 && scripts/admin.sh atraso rust-a 0
docker compose up -d                      # religa o que estiver parado
scripts/clean.sh                          # derruba a topologia (preserva evidencias/)
scripts/clean.sh --tudo                   # também remove volumes e imagens sentinel-*:local
scripts/remover-tudo.sh --simular         # mostra o que seria removido
scripts/remover-tudo.sh                   # remove contêineres, rede, volumes e imagens do projeto (pede confirmação)
scripts/remover-tudo.sh --tudo            # + evidencias/, cache de build, imagens-base, .env e rust-*/target
scripts/setup.sh --limpo                  # recomeça do zero
```

## Problemas comuns

* **Porta 8080/9090/8085 ocupada** → mude `HOST_PORT` (Nginx) ou `PAINEL_PORT` (painel) no `.env`; o Prometheus usa 9090.
* **Sub-rede em conflito (VPN/outra rede Docker)** → mude `NET_PREFIX` no `.env` (ex.: `10.78.0`) e rode `scripts/setup.sh --limpo`.
* **`chaos.sh` falha com "modulo ausente"** → instale/carregue `sch_netem`, `sch_prio`, `cls_u32` (veja acima).
* **Nginx não sobe** → `docker compose logs nginx`; `scripts/validar.sh` aponta o erro de sintaxe.
* **Alterei `nginx.conf` e nada mudou** → `scripts/validar.sh --recarregar` (valida com `nginx -t` e recarrega).
* **Alterei `alerts.yml`** → `scripts/validar.sh --recarregar`.

## Segurança do laboratório

Somente o Nginx (`HOST_PORT`), o Prometheus (`127.0.0.1:9090`) e o painel (`127.0.0.1:8085`) são publicados. `/admin` e
`/metrics` são bloqueados no Nginx e acessíveis apenas dentro da rede (toolbox). Imagens com
versão fixada (`nginx:1.27-alpine`, `prom/prometheus:v2.53.0`, `rust:1.88`, `python:3.12-alpine`, `python:3.12-slim`,
`alpine:3.20`). Não coloque senhas, tokens ou dados pessoais no repositório.

## Entregas da equipe (onde está cada item)

| Entrega | Arquivo(s) |
|---|---|
| A – diagrama e hipóteses | `docs/A-arquitetura.pdf`, `docs/A-hipoteses.md` |
| C – Nginx comentado e fluxo | `docs/C-nginx-comentado.conf`, `docs/C-fluxo.md`, `evidencias/hora4-*` |
| D – plano de monitoramento e alertas | `docs/D-plano-de-monitoramento.md`, `prometheus/alerts.yml`, `evidencias/hora5-*` |
| E – matriz de experimentos (7 experimentos, 3 extras, 2 de rede) | `docs/E-matriz.md`, `evidencias/exp1_*` … `exp7_*` |
| F – relatório de incidente | `docs/F-relatorio.pdf` (fonte `docs/F-relatorio.tex`), `evidencias/hora7-*` |
| G – este README (testado do zero em 19/11/2026 num clone novo) | `README.md`, `.env.example` |
| H – demonstração e slides | `docs/H-roteiro-demo.md`, `docs/H-slides-final.md`, prints em `docs/H-planoB/` |

Para compilar o relatório: `cd docs && pdflatex F-relatorio.tex` (duas vezes; usa `docs/preambulo.tex`).

### Notas de reprodução fora do Linux (macOS com Docker Desktop/OrbStack)

* `tc netem` funcionou no kernel da VM (OrbStack 7.2); `scripts/setup.sh` confirma com "kernel com prio + netem + u32".
* `scripts/inc.sh` usa `date -d` (GNU): no macOS, rode-o num Linux ou com GNU coreutils (`gdate`) no `PATH`.
* `scripts/admin.sh pool drenar|restaurar` foi ajustado para um `sed` compatível com BSD e GNU (antes falhava em silêncio no macOS).
* O arquivo `.env.example` que o `setup.sh` copia para `.env` está versionado.
