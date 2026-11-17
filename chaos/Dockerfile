# Operacao Sentinel - injecao de falhas de rede (tc netem) e captura de pacotes.
# Roda SOB DEMANDA, anexado a rede de um contêiner do projeto:
#   docker run --rm --cap-add NET_ADMIN --network container:<alvo> sentinel-chaos:local ...
# (use scripts/chaos.sh; nao e preciso chamar o docker run na mao)
FROM alpine:3.20
RUN apk add --no-cache bash iproute2 tcpdump iputils curl
COPY netem.sh /usr/local/bin/netem.sh
RUN chmod +x /usr/local/bin/netem.sh
ENTRYPOINT ["/usr/local/bin/netem.sh"]
