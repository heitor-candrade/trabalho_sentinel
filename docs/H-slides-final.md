# Apresentação final (12/11) — conteúdo dos slides (Entrega H)

Formato do enunciado: 10 min por equipe = **3 min de slides** + 5 min de demonstração (`docs/H-roteiro-demo.md`) + 2 min de perguntas.
Conteúdo exigido: arquitetura final, achado mais importante dos experimentos, decisão no incidente, limites da simulação, uma melhoria priorizada e um teste futuro. Abaixo, um slide por item (6 slides, ~30 s cada), com o texto e a evidência a mostrar.

## Slide 1 — Arquitetura final e SPOFs (30 s)
- Diagrama de `docs/A-arquitetura.pdf`: cliente → Nginx (.10) → Rust A (actix-web, .11) | Rust B (axum, .12); watchdog (.20) sonda `/health/ready`; Prometheus (.30) coleta nós e watchdog; painel (.50) só lê o watchdog.
- SPOFs em vermelho: Nginx, o host, o watchdog (para a observabilidade) e o Prometheus (para alertas).
- Só 8080 publicada; `/admin` e `/metrics` bloqueados no Nginx.

## Slide 2 — O que medimos e o que alerta (30 s)
- 5 métricas (`docs/D-plano-de-monitoramento.md`): `sentinel_ready`, `sentinel_app_request_duration_seconds`, `sentinel_http_requests_total{code=~"5.."}`, `sentinel_inflight_requests`, `watchdog_target_down`.
- 4 alertas em `prometheus/alerts.yml`: `NoDown` (15 s = 3 falhas × 5 s), `TaxaDeErroAlta` (> 2 % por 2 min), `LatenciaAltaP95` (> 1 s por 1 min), `MonitorParado` (`up == 0` ou `absent()` ou idade > 30 s).
- Frase-chave: **alerta sem dados nunca dispara**; por isso `MonitorParado` usa `absent()`.

## Slide 3 — Achado mais importante: "lento não é parado" e "verde não é saudável" (40 s)
- Exp. 2 (2500 ms no nó): Nginx entrega 200 em 2,5 s; watchdog marca DOWN; painel vermelho, usuário atendido.
- Exp. 7 (rede +800 ms): usuário espera **1,6 s** (duas idas e voltas), **nenhum alerta**, painel amarelo, latência no nó 5 ms.
- Exp. 4: 30 erros 500 e `TaxaDeErroAlta` mudo na 1ª rodada (série nova → `rate` = 0); pending só na 2ª.
- Evidência na tela: `docs/E-matriz.md` (tabela "o que disparou / não disparou") e `docs/H-planoB/20261119-031959Z-painel-rust-a-sondagem-lenta-atraso-rede-800ms.jpg`.

## Slide 4 — Incidente: decisão com evidência (40 s)
- Linha do tempo (UTC 19/11): 03:27:35 watchdog marca B DOWN (`http_503`); Nginx segue 200 por B; 03:28:42 retries e 1 s (`netem 150 ms / 25 %` na saída de B → Nginx); 03:29:29 `evidence.sh antes-do-reinicio`.
- Verificação decisiva: sondar B de um **terceiro ponto** (`ready` 503, `live` 200, `ready_flag=false`) → nó vivo que *diz* não estar pronto; rede confirmada por `chaos.sh status` e `tcpdump`.
- Decisão: **drenar B** (reversível), **não reiniciar**; correção dirigida; recuperação confirmada 03:31:00 com `RestartCount=0`.
- Honestidade: a drenagem falhou no macOS (sed BSD), vimos pelo `pool status`, corrigimos o script e provamos depois (`hora7-10`).

## Slide 5 — Limites da simulação (20 s)
- Um host, um kernel, um relógio; sem falha independente, sem rede real (netem só na saída de uma interface virtual).
- 3 req/s não mostra saturação; Docker DNS some com o contêiner (`reason=dns`); `HEALTHCHECK` roda dentro do contêiner e nunca vê a rede.

## Slide 6 — Melhoria priorizada e teste futuro (20 s)
- **Prontidão consultada pelo balanceador**: controlador que, ao DOWN confirmado por um segundo ponto, faz `pool drenar`; ao UP, `pool restaurar` (ou balanceador com sondagem ativa).
- Teste futuro: repetir o incidente com o controlador ligado; metas: B fora do pool em < 30 s, zero retries para o usuário, retorno automático sem reinício.
- Também: métricas do caminho do usuário (log do Nginx) e alerta de **discordância** watchdog × Nginx.

## Apresentação preliminar (05/11) — registro
Os 5 slides da preliminar (arquitetura e SPOFs; o que já rodava; métricas e alertas planejados; hipóteses e experimentos previstos; riscos e plano) ficam em `docs/H-preliminar.*` (arquivo da equipe). _(Se a equipe apresentou com outro arquivo, salvar aqui a versão apresentada.)_
