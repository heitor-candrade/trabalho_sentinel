# Roteiro da demonstração ao vivo (5 min) — Entrega H

**Disciplina:** FEELT37802 - Sistemas Distribuídos (2026/2) · **Prof.:** Renato Carrijo
**Projeto:** Operação Sentinel: Cluster Distribuído Resiliente
**Regra da demonstração:** antes de cada comando, dizer em voz alta **o que esperamos ver**; só depois executar.

## Antes de subir ao palco (checklist)

- [ ] Ambiente limpo e testado: `scripts/setup.sh --limpo` (constrói, sobe e faz o teste de fumaça) e `scripts/status.sh` sem alerta ativo.
- [ ] Nenhuma falha pendente: `scripts/chaos.sh status todos` sem regra; `scripts/admin.sh status` com `ready_flag=true delay_ms=0` nos dois nós.
- [ ] Três janelas abertas, fonte grande: (1) terminal de comandos, (2) `scripts/status.sh --vivo`, (3) navegador com o painel `http://localhost:8085` e `http://localhost:9090/alerts`.
- [ ] Tráfego de fundo ligado: `scripts/requests.sh fundo start` (3 req/s; dá "usuários" para o painel e para o Nginx).
- [ ] Plano B pronto (prints com horário em `docs/H-planoB/` e `evidencias/exp*/`).
- [ ] Sem senhas, tokens ou portas administrativas na tela (`/admin` e `/metrics` só na rede interna).
- [ ] Cronometrada no ensaio: cabe em 5 min (tempos abaixo somam 300 s).

## Passos (comando, fala e o que esperamos ver)

| N. | Passo | Comando | Fala: o que esperamos ver | Tempo |
|---:|---|---|---|---:|
| 1 | Estado inicial | `docker compose ps` e o painel (`localhost:8085`) | 7 contêineres `running`/`healthy`. No diagrama do painel: Nginx (.10) na frente, **A em actix-web (.11)** e **B em axum (.12)** atrás, watchdog (.20) sondando `/health/ready`, Prometheus (.30) coletando. Tudo verde. | 30 s |
| 2 | Fluxo normal | `scripts/requests.sh 6` e `docker compose logs --since 20s nginx rust-a` | Alternância A, B, A, B (round-robin), 6×200 em ~1 ms. O **mesmo `request_id`** aparece na linha do Nginx (`client=10.9.8.1`) e na linha do Rust (`client=10.9.8.10`). | 45 s |
| 3 | Falha de um nó | **Previsão em voz alta** → `docker compose stop rust-a` → `scripts/requests.sh 10` | Todas 200 por B; as primeiras tentativas em A levam ~1 s (`proxy_connect_timeout`) e aparecem no log como `upstream_status=504, 200`; depois de 3 falhas o Nginx isola A por 10 s. Em ~15 s o watchdog marca **A DOWN** (`reason=dns`/`no_route`), o painel fica vermelho e `NoDown` entra em *pending* e dispara 15 s depois em `localhost:9090/alerts`. | 90 s |
| 4 | Vivo, mas não pronto | `scripts/admin.sh ready rust-b 0` → `docker compose exec -T toolbox curl -s -o /dev/null -w '%{http_code}\n' http://rust-b:8080/health/live` e idem `/health/ready` | `live` 200 e `ready` 503 **no mesmo processo**. `docker compose ps` segue `healthy` (o HEALTHCHECK usa `live`). O Nginx continua mandando tráfego para B e o usuário recebe 200: o painel fica vermelho e o serviço, não. | 60 s |
| 5 | Recuperação | `scripts/admin.sh ready rust-b 1` e `docker compose start rust-a` → `scripts/requests.sh 6` → `docker inspect -f '{{.RestartCount}}' sentinel-rust-a-1` | Após o aquecimento de 3 s e 2 sondagens boas, A e B voltam a UP; o tráfego volta a alternar A/B; `RestartCount=0` (sem reinício em loop); alertas voltam a *inactive*. | 45 s |
| 6 | Falha do monitor | `docker compose stop watchdog` | O serviço do usuário **não muda** (`requests.sh 6` segue 200). O painel avisa "o watchdog não responde"; em 10 s `MonitorParado` dispara (`up{job="watchdog"} == 0` e `absent(...)`); `NoDown` fica mudo porque **alerta sem dados nunca dispara**. Quem vigia o vigia: o Prometheus, com uma regra que prevê a ausência da série. Encerrar com `docker compose start watchdog`. | 30 s |

**Fechamento (10 s):** achado mais importante — "lento não é parado": no experimento 2 e no atraso de rede de 800 ms o painel e os alertas discordam do que o usuário vê; limites da simulação (um host, um kernel, sem rede real) e a melhoria priorizada (readiness consultada pelo balanceador).

## Se algo der errado ao vivo

Narrar o que vimos, formular uma hipótese testável e dizer como testar (`scripts/status.sh`, `docker compose logs --since 2m <svc>`, `scripts/evidence.sh ao-vivo`). O professor pode pedir que a equipe reproduza uma falha da matriz: todas estão em `docs/E-matriz.md`, com o comando de injeção e o de recuperação.

## Plano B (sem demonstração ao vivo)

Prints com horário UTC em `docs/H-planoB/` (painel em estado normal, com A DOWN, com o watchdog parado e a página de alertas do Prometheus) e as saídas completas em `evidencias/exp1_*` … `evidencias/exp7_*`.

## Quem faz o quê

| Função | Integrante |
|---|---|
| Digita os comandos | _(preencher)_ |
| Narra e explica a previsão | _(preencher)_ |
| Cronometra e monitora `status.sh --vivo` e o painel | _(preencher)_ |
| Responde perguntas | _(preencher)_ |

## Reset entre ensaios

```bash
scripts/chaos.sh limpar todos; scripts/admin.sh ready rust-a 1; scripts/admin.sh ready rust-b 1; scripts/admin.sh atraso rust-a 0
docker compose up -d            # religa o que estiver parado
scripts/requests.sh fundo stop  # se não for usar o tráfego de fundo
```
