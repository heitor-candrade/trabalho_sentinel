# Operacao Sentinel - contêiner de operacao (dentro da rede do projeto).
# Serve para: chamar /admin e /metrics (nao publicados no host), consultar o
# Prometheus, gerar trafego de teste e testar conectividade a partir de "outro ponto".
FROM alpine:3.20
RUN apk add --no-cache bash curl jq bind-tools iproute2 iputils tcpdump coreutils
COPY scripts /opt/sentinel
WORKDIR /opt/sentinel
CMD ["sleep", "infinity"]
