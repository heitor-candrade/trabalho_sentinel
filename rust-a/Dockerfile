# Operacao Sentinel - no A (Rust + actix-web) (build em duas etapas)
# Versao do compilador fixada (regra do enunciado: nada de "latest").
FROM rust:1.88-slim-bookworm AS build
WORKDIR /src

# 1) cache das dependencias: compila um main vazio antes de copiar o codigo real
COPY Cargo.toml Cargo.lock ./
RUN mkdir src && echo 'fn main() {}' > src/main.rs \
 && cargo build --release --locked \
 && rm -rf src target/release/sentinel-node-actix target/release/deps/sentinel_node_actix*

# 2) codigo real
COPY src ./src
RUN cargo build --release --locked

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --no-create-home sentinel
COPY --from=build /src/target/release/sentinel-node-actix /usr/local/bin/sentinel-node-actix
USER sentinel
ENV NODE_NAME=node PORT=8080 WARMUP_SECONDS=3
EXPOSE 8080
HEALTHCHECK --interval=5s --timeout=3s --start-period=3s --retries=3 \
  CMD ["/usr/local/bin/sentinel-node-actix", "--healthcheck"]
ENTRYPOINT ["/usr/local/bin/sentinel-node-actix"]
