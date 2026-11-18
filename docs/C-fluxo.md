# Rastreamento Ponta a Ponta com `request_id` Real (Entrega C)

**Disciplina:** FEELT37802 - Sistemas Distribuídos (2026/2)  
**Prof.:** Renato Carrijo  
**Aluno:** Heitor Carvalho Andrade (12311ECP023)  
**Evidência de referência:** `evidencias/hora4-request-id.txt` (`qua. 18 nov 2026 03:11:56 UTC`)  
**Request ID capturado:** `815195a0bb28a16697020dd3caa5ea2b`

---

## Os 5 Passos da Requisição no Cluster Sentinel

### 1. Cliente (`curl` no host — `10.9.8.1`)
O cliente dispara uma requisição HTTP `GET /` para `http://localhost:8080/` (porta publicada no host e mapeada para a porta `80` do contêiner `nginx`). Na requisição de ida, nenhum identificador prévio é enviado; ao receber a resposta HTTP `200 OK`, o cliente obtém o cabeçalho `X-Request-Id: 815195a0bb28a16697020dd3caa5ea2b`, permitindo auditar o caminho exato percorrido pela chamada no cluster.

### 2. Nginx (Proxy Reverso e Balanceador — `10.9.8.10:80`)
O Nginx recebe a conexão proveniente do gateway da rede Docker (`client=10.9.8.1`), gera automaticamente um identificador hexadecimal único de 32 caracteres por meio da variável nativa `$request_id` (`815195a0bb28a16697020dd3caa5ea2b`) e propaga esse valor no cabeçalho HTTP `X-Request-Id` encaminhado ao back-end (além de devolvê-lo na resposta ao cliente). Em seguida, escolhe o nó `rust-a` (`10.9.8.11:8080`) seguindo o balanceamento *Round Robin* do bloco `upstream rust_pool`.

### 3. Nó de Aplicação (`rust-a` / Actix Web — `10.9.8.11:8080`)
A instância `rust-a` recebe a requisição encaminhada pelo Nginx (`client=10.9.8.10`). O middleware do servidor (`middleware::from_fn`) lê o cabeçalho `X-Request-Id` (`815195a0bb28a16697020dd3caa5ea2b`), inicia a medição da duração do processamento, executa o handler da rota `GET /` (que retorna `"atendido por rust-a\n"` com status `200 OK`), inclui os cabeçalhos `X-Node: rust-a` e `X-Request-Id: 815195a0bb28a16697020dd3caa5ea2b` na resposta e atualiza as métricas internas do Prometheus.

### 4. Log do Rust (`rust-a` stdout)
Ao finalizar a resposta HTTP, o middleware do `rust-a` registra em `stdout` uma linha estruturada com o carimbo temporal em UTC, o `request_id` propagado pelo Nginx, o endereço interno do proxy (`10.9.8.10`), o código `200` e o tempo de execução no nó (`dur_ms=0`):

```text
2026-11-18T03:11:56.112Z rust-a INFO request_id=815195a0bb28a16697020dd3caa5ea2b client=10.9.8.10 method=GET path=/ status=200 dur_ms=0
```

### 5. Log do Nginx (`nginx` stdout)
Após receber a resposta de `rust-a` e entregá-la ao cliente, o Nginx grava o registro consolidado da transação no `access_log` customizado, correlacionando o mesmo `request_id` ao cliente externo (`10.9.8.1`), ao nó que atendeu a chamada (`node=rust-a`), ao upstream utilizado (`10.9.8.11:8080`), ao status final (`200`) e à latência total (`req_time`):

```text
2026-11-18T03:11:56+00:00 nginx INFO request_id=815195a0bb28a16697020dd3caa5ea2b client=10.9.8.1 method=GET uri=/ status=200 node=rust-a upstream=10.9.8.11:8080 upstream_status=200 req_time=0.001
```