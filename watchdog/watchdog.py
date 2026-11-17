#!/usr/bin/env python3
"""Operacao Sentinel - watchdog (monitor independente).

Sonda periodicamente o endpoint de readiness de cada no, conta falhas
consecutivas e decide DOWN/UP. NAO reinicia nada: apenas observa, registra
e expoe metricas (regra de ouro 6: nao agir com base em um unico sinal).

Variaveis de ambiente (apenas biblioteca padrao do Python):
  ALVOS          "rust-a=http://rust-a:8080,rust-b=http://rust-b:8080"
  INTERVALO      segundos entre sondagens de cada alvo        (padrao 5)
  TIMEOUT        tempo maximo de cada sondagem, em segundos   (padrao 2)
  LIMITE_FALHAS  falhas consecutivas para marcar DOWN         (padrao 3)
  LIMITE_SUCESSOS sucessos consecutivos para voltar a UP      (padrao 2)
  CAMINHO        caminho sondado                              (padrao /health/ready)
  PORTA          porta de /metrics, /state e /health          (padrao 9100)

Cada alvo e sondado por uma thread propria: um alvo lento nao atrasa os demais.
"""
import json
import os
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def env_num(nome, padrao, tipo=float):
    try:
        return tipo(os.environ.get(nome, padrao))
    except ValueError:
        return tipo(padrao)


INTERVALO = env_num("INTERVALO", 5.0)
TIMEOUT = env_num("TIMEOUT", 2.0)
LIMITE_FALHAS = env_num("LIMITE_FALHAS", 3, int)
LIMITE_SUCESSOS = env_num("LIMITE_SUCESSOS", 2, int)
CAMINHO = os.environ.get("CAMINHO", "/health/ready")
PORTA = env_num("PORTA", 9100, int)
INICIO = time.time()


def parse_alvos(txt):
    alvos = {}
    for item in txt.split(","):
        item = item.strip()
        if not item:
            continue
        nome, _, url = item.partition("=")
        if not url:
            sys.exit(f"ALVOS invalido: '{item}' (use nome=url)")
        alvos[nome.strip()] = url.strip().rstrip("/")
    return alvos


ALVOS = parse_alvos(
    os.environ.get("ALVOS", "rust-a=http://rust-a:8080,rust-b=http://rust-b:8080")
)

lock = threading.Lock()
estado = {
    nome: {
        "url": url,
        "state": "up",  # otimista no inicio: so vira DOWN apos LIMITE_FALHAS falhas
        "falhas_consecutivas": 0,
        "sucessos_consecutivos": 0,
        "ultima_sondagem_ts": 0.0,
        "ultima_duracao_s": 0.0,
        "ultimo_resultado": "nenhum",
        "ultimo_motivo": "",
        "sondagens": {"ok": 0, "fail": 0},
        "falhas_por_motivo": {},
        "transicoes": {"up": 0, "down": 0},
    }
    for nome, url in ALVOS.items()
}


def agora_iso():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def log(nivel, msg):
    print(f"{agora_iso()} watchdog {nivel} {msg}", flush=True)


def sondar(url):
    """Retorna (ok, motivo, duracao_s)."""
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(url + CAMINHO, timeout=TIMEOUT) as r:
            codigo = r.status
            r.read(256)
        dur = time.monotonic() - t0
        if codigo != 200:
            return False, f"http_{codigo}", dur
        if dur > TIMEOUT:  # urlopen limita cada operacao, nao o total
            return False, "late", dur
        return True, "ok", dur
    except urllib.error.HTTPError as e:
        return False, f"http_{e.code}", time.monotonic() - t0
    except urllib.error.URLError as e:
        r = e.reason
        if isinstance(r, socket.timeout) or "timed out" in str(r):
            motivo = "timeout"
        elif isinstance(r, ConnectionRefusedError):
            motivo = "refused"
        elif isinstance(r, OSError) and r.errno == 113:
            motivo = "no_route"  # ex.: contêiner parado: ninguem responde ao ARP
        elif isinstance(r, OSError) and r.errno == 101:
            motivo = "net_unreachable"
        elif isinstance(r, socket.gaierror):
            motivo = "dns"
        else:
            motivo = "erro_" + type(r).__name__
        return False, motivo, time.monotonic() - t0
    except (socket.timeout, TimeoutError):
        return False, "timeout", time.monotonic() - t0
    except ConnectionError as e:
        return False, "erro_" + type(e).__name__, time.monotonic() - t0
    except Exception as e:  # noqa: BLE001 - qualquer outra falha conta como falha de sondagem
        return False, "erro_" + type(e).__name__, time.monotonic() - t0


def laco_alvo(nome):
    while True:
        inicio = time.monotonic()
        ok, motivo, dur = sondar(estado[nome]["url"])
        with lock:
            e = estado[nome]
            e["ultima_sondagem_ts"] = time.time()
            e["ultima_duracao_s"] = dur
            e["ultimo_resultado"] = "ok" if ok else "fail"
            e["ultimo_motivo"] = motivo
            anterior = e["state"]
            if ok:
                e["sondagens"]["ok"] += 1
                e["falhas_consecutivas"] = 0
                e["sucessos_consecutivos"] += 1
                if anterior == "down" and e["sucessos_consecutivos"] >= LIMITE_SUCESSOS:
                    e["state"] = "up"
            else:
                e["sondagens"]["fail"] += 1
                e["falhas_por_motivo"][motivo] = e["falhas_por_motivo"].get(motivo, 0) + 1
                e["sucessos_consecutivos"] = 0
                e["falhas_consecutivas"] += 1
                if anterior == "up" and e["falhas_consecutivas"] >= LIMITE_FALHAS:
                    e["state"] = "down"
            novo = e["state"]
            if novo != anterior:
                e["transicoes"][novo] += 1
            linha = (
                f"target={nome} result={'ok' if ok else 'fail'} reason={motivo} "
                f"latency_ms={int(dur * 1000)} consecutive_failures={e['falhas_consecutivas']} "
                f"state={novo}"
            )
            falhas = e["falhas_consecutivas"]
        log("INFO" if ok else "WARN", linha)
        if novo != anterior:
            log(
                "ERROR" if novo == "down" else "INFO",
                f"event=state_change target={nome} from={anterior} to={novo} "
                f"consecutive_failures={falhas} reason={motivo}",
            )
        time.sleep(max(0.0, INTERVALO - (time.monotonic() - inicio)))


def render_metrics():
    L = []

    def gauge(nome, ajuda, tipo="gauge"):
        L.append(f"# HELP {nome} {ajuda}")
        L.append(f"# TYPE {nome} {tipo}")

    with lock:
        snap = json.loads(json.dumps(estado))
    gauge("watchdog_target_up", "1 se o watchdog considera o alvo UP.")
    for n, e in snap.items():
        L.append(f'watchdog_target_up{{target="{n}"}} {1 if e["state"] == "up" else 0}')
    gauge("watchdog_target_down", "1 se o watchdog considera o alvo DOWN.")
    for n, e in snap.items():
        L.append(f'watchdog_target_down{{target="{n}"}} {1 if e["state"] == "down" else 0}')
    gauge("watchdog_consecutive_failures", "Falhas de sondagem consecutivas.")
    for n, e in snap.items():
        L.append(f'watchdog_consecutive_failures{{target="{n}"}} {e["falhas_consecutivas"]}')
    gauge("watchdog_probe_duration_seconds", "Duracao da ultima sondagem.")
    for n, e in snap.items():
        L.append(f'watchdog_probe_duration_seconds{{target="{n}"}} {e["ultima_duracao_s"]:.6f}')
    gauge("watchdog_last_probe_timestamp_seconds", "Instante (epoch) da ultima sondagem concluida.")
    for n, e in snap.items():
        L.append(f'watchdog_last_probe_timestamp_seconds{{target="{n}"}} {e["ultima_sondagem_ts"]:.3f}')
    gauge("watchdog_probes_total", "Sondagens realizadas, por resultado.", "counter")
    for n, e in snap.items():
        for r, v in e["sondagens"].items():
            L.append(f'watchdog_probes_total{{target="{n}",result="{r}"}} {v}')
    gauge("watchdog_probe_failures_total", "Falhas de sondagem por motivo.", "counter")
    for n, e in snap.items():
        for m, v in sorted(e["falhas_por_motivo"].items()):
            L.append(f'watchdog_probe_failures_total{{target="{n}",reason="{m}"}} {v}')
    gauge("watchdog_state_changes_total", "Mudancas de estado por destino.", "counter")
    for n, e in snap.items():
        for to, v in e["transicoes"].items():
            L.append(f'watchdog_state_changes_total{{target="{n}",to="{to}"}} {v}')
    gauge("watchdog_config_interval_seconds", "Intervalo de sondagem configurado.")
    L.append(f"watchdog_config_interval_seconds {INTERVALO}")
    gauge("watchdog_config_timeout_seconds", "Timeout de sondagem configurado.")
    L.append(f"watchdog_config_timeout_seconds {TIMEOUT}")
    gauge("watchdog_config_failure_threshold", "Falhas consecutivas para marcar DOWN.")
    L.append(f"watchdog_config_failure_threshold {LIMITE_FALHAS}")
    gauge("watchdog_uptime_seconds", "Tempo de vida do processo do watchdog.")
    L.append(f"watchdog_uptime_seconds {time.time() - INICIO:.3f}")
    return "\n".join(L) + "\n"


def render_state():
    with lock:
        snap = json.loads(json.dumps(estado))
    agora = time.time()
    for e in snap.values():
        e["idade_ultima_sondagem_s"] = (
            round(agora - e["ultima_sondagem_ts"], 1) if e["ultima_sondagem_ts"] else None
        )
    return json.dumps(
        {
            "agora": agora_iso(),
            "config": {
                "intervalo_s": INTERVALO,
                "timeout_s": TIMEOUT,
                "limite_falhas": LIMITE_FALHAS,
                "limite_sucessos": LIMITE_SUCESSOS,
                "caminho": CAMINHO,
            },
            "alvos": snap,
        },
        indent=2,
        ensure_ascii=False,
    ) + "\n"


class Handler(BaseHTTPRequestHandler):
    def _responder(self, codigo, corpo, tipo):
        dados = corpo.encode()
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(dados)))
        self.end_headers()
        self.wfile.write(dados)

    def do_GET(self):  # noqa: N802
        caminho = self.path.split("?")[0]
        if caminho == "/metrics":
            self._responder(200, render_metrics(), "text/plain; version=0.0.4; charset=utf-8")
        elif caminho == "/state":
            self._responder(200, render_state(), "application/json; charset=utf-8")
        elif caminho == "/health":
            self._responder(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._responder(404, "nao encontrado\n", "text/plain; charset=utf-8")

    def log_message(self, *args):  # silencia o log por requisicao
        pass


def encerrar(*_):
    log("INFO", "event=shutdown motivo=sinal")
    os._exit(0)


def main():
    signal.signal(signal.SIGTERM, encerrar)
    signal.signal(signal.SIGINT, encerrar)
    log(
        "INFO",
        f"event=start alvos={','.join(ALVOS)} intervalo_s={INTERVALO} timeout_s={TIMEOUT} "
        f"limite_falhas={LIMITE_FALHAS} limite_sucessos={LIMITE_SUCESSOS} caminho={CAMINHO} porta={PORTA}",
    )
    for nome in ALVOS:
        threading.Thread(target=laco_alvo, args=(nome,), daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORTA), Handler).serve_forever()


if __name__ == "__main__":
    main()
