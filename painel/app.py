"""Operacao Sentinel - painel (FastAPI + uvicorn).

Pagina dinamica, SOMENTE LEITURA, que mostra a arquitetura e o estado dos nos
como o WATCHDOG os enxerga. O painel nao sonda os nos Rust: ele le o que o
watchdog publica em /state. Assim, se o watchdog estiver errado, o painel
tambem estara (e isso e proposital: "quem vigia o vigia?").

Rotas:
  GET /             a pagina (pagina.html)
  GET /api/estado   JSON consolidado (usado pela pagina a cada 2 s)
  GET /health       200 se o painel esta de pe (usado pelo HEALTHCHECK do Docker)

Variaveis de ambiente (todas opcionais):
  WATCHDOG_URL    http://watchdog:9100
  NGINX_URL       http://nginx/nginx-health            (sondagem direta do painel)
  PROMETHEUS_URL  http://prometheus:9090/-/healthy     (sondagem direta do painel)
  INTERVALO       segundos entre leituras              (padrao 2)
  HISTORICO       amostras guardadas em memoria        (padrao 150 = 5 min)
  NET_PREFIX      prefixo da rede, so para exibir IPs  (padrao 10.9.8)
  FRAMEWORKS      rotulos exibidos                     (padrao rust-a=actix-web,rust-b=axum)
"""
import json
import os
import threading
import time
import urllib.request
from collections import deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse

WATCHDOG = os.environ.get("WATCHDOG_URL", "http://watchdog:9100").rstrip("/")
NGINX = os.environ.get("NGINX_URL", "http://nginx/nginx-health")
PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090/-/healthy")
INTERVALO = float(os.environ.get("INTERVALO", "2"))
HISTORICO = int(os.environ.get("HISTORICO", "150"))
NET = os.environ.get("NET_PREFIX", "10.9.8")
FRAMEWORKS = dict(
    item.split("=", 1)
    for item in os.environ.get("FRAMEWORKS", "rust-a=actix-web,rust-b=axum").split(",")
    if "=" in item
)

# Componentes desenhados na pagina (a posicao de cada um fica em pagina.html).
COMPONENTES = [
    {"id": "cliente", "rotulo": "Cliente", "ip": None, "detalhe": "curl / navegador"},
    {"id": "nginx", "rotulo": "Nginx", "ip": f"{NET}.10", "detalhe": "proxy reverso :80"},
    {"id": "rust-a", "rotulo": "Rust A", "ip": f"{NET}.11", "detalhe": FRAMEWORKS.get("rust-a", "rust") + " :8080"},
    {"id": "rust-b", "rotulo": "Rust B", "ip": f"{NET}.12", "detalhe": FRAMEWORKS.get("rust-b", "rust") + " :8080"},
    {"id": "watchdog", "rotulo": "Watchdog", "ip": f"{NET}.20", "detalhe": "monitor :9100"},
    {"id": "prometheus", "rotulo": "Prometheus", "ip": f"{NET}.30", "detalhe": "metricas :9090"},
    {"id": "painel", "rotulo": "Painel", "ip": f"{NET}.50", "detalhe": "só leitura :8085"},
]

lock = threading.Lock()
INICIO = time.time()
historico = deque(maxlen=HISTORICO)   # amostras: {"t": epoch, "nos": {nome: {...}}}
eventos = deque(maxlen=40)            # mudancas de estado vistas pelo painel
atual = {}                            # ultima leitura completa
anterior = {}                         # nivel anterior de cada componente (para gerar eventos)


def agora_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def buscar(url, timeout):
    """Retorna (status|None, corpo|mensagem_de_erro)."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return r.status, r.read(1 << 20)
    except Exception as e:  # noqa: BLE001 - qualquer falha de leitura conta como "sem resposta"
        return None, f"{type(e).__name__}: {e}"


def classificar(no, cfg):
    """ok | atencao | down  (a partir do que o WATCHDOG diz)."""
    if no["estado"] == "down":
        return "down"
    lento = no["dur_ms"] >= 0.75 * cfg["timeout_s"] * 1000
    velho = no["idade_s"] is not None and no["idade_s"] > 3 * cfg["intervalo_s"]
    if no["falhas"] > 0 or lento or velho:
        return "atencao"
    return "ok"


def montar_alertas(monitor_ok, motivo_monitor, nos, cfg, nginx_ok, prom_ok):
    """Mecanismo de alerta ligado ao watchdog. Cada item: {nivel, texto}."""
    alertas = []
    if not monitor_ok:
        alertas.append({"nivel": "critico", "texto": (
            "O watchdog não responde ao painel (%s). Ninguém está avaliando os nós: o estado abaixo "
            "é o último conhecido. Quem vigia o vigia?" % motivo_monitor)})
    for nome, no in nos.items():
        if not monitor_ok:
            break
        if no["nivel"] == "down":
            alertas.append({"nivel": "critico", "texto": (
                "%s está DOWN segundo o watchdog: %d falhas seguidas (motivo: %s)."
                % (nome, no["falhas"], no["motivo"] or "n/d"))})
        elif no["falhas"] > 0:
            alertas.append({"nivel": "atencao", "texto": (
                "%s: %d de %d falhas seguidas (motivo: %s). Com mais %d, vira DOWN."
                % (nome, no["falhas"], cfg["limite_falhas"], no["motivo"], cfg["limite_falhas"] - no["falhas"]))})
        elif no["nivel"] == "atencao":
            if no["idade_s"] is not None and no["idade_s"] > 3 * cfg["intervalo_s"]:
                alertas.append({"nivel": "atencao", "texto": "%s: a última sondagem tem %.0f s (dados velhos)." % (nome, no["idade_s"])})
            else:
                alertas.append({"nivel": "atencao", "texto": (
                    "%s: sondagem lenta (%d ms; timeout do watchdog: %d ms)." % (nome, no["dur_ms"], cfg["timeout_s"] * 1000))})
    if not nginx_ok:
        alertas.append({"nivel": "critico", "texto": "O Nginx não responde ao painel: o caminho do usuário pode estar fora."})
    if not prom_ok:
        alertas.append({"nivel": "atencao", "texto": "O Prometheus não responde ao painel: métricas e alertas podem estar parados."})
    return alertas


def registrar_evento(chave, nivel_novo, texto):
    antes = anterior.get(chave)
    anterior[chave] = nivel_novo
    if antes is not None and antes != nivel_novo and time.time() - INICIO > 15:  # ignora o aquecimento inicial
        eventos.appendleft({"t": agora_iso(), "nivel": nivel_novo, "texto": texto})


def amostrar():
    global atual
    st, corpo = buscar(WATCHDOG + "/state", 1.5)
    monitor_ok, motivo_monitor, cfg, alvos = False, "", None, {}
    if st == 200:
        try:
            dados = json.loads(corpo)
            cfg, alvos, monitor_ok = dados["config"], dados["alvos"], True
        except (ValueError, KeyError) as e:
            motivo_monitor = "resposta invalida: %s" % type(e).__name__
    else:
        motivo_monitor = ("conexão recusada" if "refused" in str(corpo) else "tempo esgotado" if "timed out" in str(corpo) else str(corpo)[:60]) if st is None else "HTTP %s" % st
    nginx_ok = buscar(NGINX, 1.5)[0] == 200
    prom_ok = buscar(PROMETHEUS, 1.5)[0] == 200

    with lock:
        if monitor_ok:
            nos = {}
            for nome, a in alvos.items():
                nos[nome] = {
                    "estado": a["state"], "falhas": a["falhas_consecutivas"],
                    "dur_ms": round(a["ultima_duracao_s"] * 1000), "resultado": a["ultimo_resultado"],
                    "motivo": a["ultimo_motivo"], "idade_s": a.get("idade_ultima_sondagem_s"),
                    "ok": a["sondagens"]["ok"], "fail": a["sondagens"]["fail"],
                    "downs": a["transicoes"]["down"], "framework": FRAMEWORKS.get(nome, ""),
                }
                nos[nome]["nivel"] = classificar(nos[nome], cfg)
            historico.append({"t": time.time(), "nos": {n: {"ms": v["dur_ms"], "fail": v["resultado"] == "fail", "nivel": v["nivel"]} for n, v in nos.items()}})
        else:  # sem monitor: mantem o ultimo estado conhecido, mas marca como desconhecido
            nos = {n: dict(v, nivel="desconhecido") for n, v in atual.get("nos", {}).items()}
            cfg = atual.get("config") or {"intervalo_s": 5, "timeout_s": 2, "limite_falhas": 3, "limite_sucessos": 2, "caminho": "/health/ready"}
            historico.append({"t": time.time(), "nos": {n: {"ms": None, "fail": False, "nivel": "desconhecido"} for n in nos}})
        registrar_evento("watchdog", "ok" if monitor_ok else "down",
                         "O watchdog voltou a responder ao painel." if monitor_ok else "O watchdog parou de responder ao painel.")
        registrar_evento("nginx", "ok" if nginx_ok else "down", "Nginx voltou a responder." if nginx_ok else "Nginx não responde ao painel.")
        registrar_evento("prometheus", "ok" if prom_ok else "down", "Prometheus voltou a responder." if prom_ok else "Prometheus não responde ao painel.")
        for nome, no in nos.items():
            if monitor_ok:
                registrar_evento(nome, no["nivel"], "%s: %s." % (nome, {"ok": "saudável (UP)", "atencao": "em atenção (%s)" % (no["motivo"] or "lento"), "down": "DOWN segundo o watchdog (%s)" % no["motivo"]}[no["nivel"]]))
        alertas = montar_alertas(monitor_ok, motivo_monitor, nos, cfg, nginx_ok, prom_ok)
        resumo = "incidente" if any(a["nivel"] == "critico" for a in alertas) else ("atencao" if alertas else "normal")
        atual = {"agora": agora_iso(), "config": cfg, "monitor_ok": monitor_ok, "nginx_ok": nginx_ok,
                 "prometheus_ok": prom_ok, "nos": nos, "alertas": alertas, "resumo": resumo}


def laco():
    while True:
        t0 = time.monotonic()
        try:
            amostrar()
        except Exception as e:  # noqa: BLE001 - o painel nunca deve morrer por causa de uma leitura
            print("%s painel ERROR leitura falhou: %s" % (agora_iso(), e), flush=True)
        time.sleep(max(0.2, INTERVALO - (time.monotonic() - t0)))


@asynccontextmanager
async def vida(_app):
    threading.Thread(target=laco, daemon=True).start()
    print("%s painel INFO event=start porta=8085 watchdog=%s intervalo_s=%s" % (agora_iso(), WATCHDOG, INTERVALO), flush=True)
    yield


app = FastAPI(title="Operacao Sentinel - painel", docs_url=None, redoc_url=None, openapi_url=None, lifespan=vida)
PAGINA = (Path(__file__).parent / "pagina.html").read_text(encoding="utf-8")


@app.get("/", response_class=HTMLResponse)
def pagina():
    return PAGINA


@app.get("/api/estado")
def estado():
    with lock:
        corpo = dict(atual) if atual else {"resumo": "iniciando", "nos": {}, "alertas": [], "config": {}}
        corpo["componentes"] = COMPONENTES
        corpo["historico"] = list(historico)
        corpo["eventos"] = list(eventos)
        corpo["janela_s"] = HISTORICO * INTERVALO
        corpo["intervalo_painel_s"] = INTERVALO
    return JSONResponse(corpo, headers={"Cache-Control": "no-store"})


@app.get("/health", response_class=PlainTextResponse)
def health():
    return "ok\n"
