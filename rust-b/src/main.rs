// Operacao Sentinel - no B da aplicacao (Rust + axum + tokio)
// O no A (rust-a/) implementa o MESMO contrato com actix-web: aqui o cluster e heterogeneo.
//
// Rotas:
//   GET /                 "atendido por <no>" (aplica o atraso artificial)
//   GET /erro             responde 500 (experimento de erro)
//   GET /health/live      200 se o processo responde (liveness; nunca atrasa)
//   GET /health/ready     200 ou 503 (readiness; sofre o atraso artificial)
//   GET /metrics          texto no formato Prometheus
//   GET /admin/ready?v=0|1   liga/desliga a prontidao      (somente rede interna)
//   GET /admin/atraso?ms=N   define latencia artificial     (somente rede interna)
//   GET /admin/status        mostra o estado interno        (somente rede interna)
//
// Variaveis de ambiente:
//   NODE_NAME (default "node"), PORT (8080), WARMUP_SECONDS (3), INITIAL_DELAY_MS (0)
//
// Modo especial: `sentinel-node-axum --healthcheck` faz GET /health/live em 127.0.0.1
// e sai com codigo 0 (ok) ou 1 (falha). Usado pelo HEALTHCHECK do Docker.
//
// Cada requisicao gera uma linha de log:
//   timestamp no INFO request_id=... client=... method=GET path=/ status=200 dur_ms=3

use std::{
    collections::{BTreeMap, HashMap},
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use axum::{
    extract::{ConnectInfo, Query, Request, State},
    http::{header::CONTENT_TYPE, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Router,
};

const BOUNDS: [f64; 10] = [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0];
const MAX_DELAY_MS: u64 = 30_000;

struct AppState {
    node: String,
    started: Instant,
    warmup: Duration,
    ready_flag: AtomicBool,
    delay_ms: AtomicU64,
    inflight: AtomicU64,
    seq: AtomicU64,
    reqs: Mutex<BTreeMap<(&'static str, u16), u64>>,
    // histograma do trafego de usuario (rotas "root" e "erro"); ultimo balde = +Inf
    buckets: Vec<AtomicU64>,
    hist_count: AtomicU64,
    hist_sum_us: AtomicU64,
}

impl AppState {
    fn effective_ready(&self) -> bool {
        self.ready_flag.load(Ordering::Relaxed) && self.started.elapsed() >= self.warmup
    }
}

type Shared = Arc<AppState>;

// ---------- utilidades ----------

fn iso_now() -> String {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    let secs = d.as_secs() as i64;
    let ms = d.subsec_millis();
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // dias desde 1970-01-01 -> data civil (algoritmo de H. Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { y + 1 } else { y };
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        year,
        month,
        day,
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60,
        ms
    )
}

fn log(node: &str, level: &str, msg: &str) {
    println!("{} {} {} {}", iso_now(), node, level, msg);
}

fn route_of(path: &str) -> &'static str {
    match path {
        "/" => "root",
        "/erro" => "erro",
        "/health/live" => "health_live",
        "/health/ready" => "health_ready",
        "/metrics" => "metrics",
        p if p.starts_with("/admin") => "admin",
        _ => "other",
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(default)
}

// ---------- middleware: request_id, metricas e log ----------

async fn track(
    State(st): State<Shared>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request,
    next: Next,
) -> Response {
    let start = Instant::now();
    let method = req.method().to_string();
    let path = req.uri().path().to_string();
    let rid = req
        .headers()
        .get("x-request-id")
        .and_then(|v| v.to_str().ok())
        .filter(|s| !s.is_empty() && s.len() <= 64)
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            let n = st.seq.fetch_add(1, Ordering::Relaxed);
            format!("{}-{:06x}", st.node, n)
        });

    st.inflight.fetch_add(1, Ordering::Relaxed);
    let mut resp = next.run(req).await;
    st.inflight.fetch_sub(1, Ordering::Relaxed);

    let status = resp.status().as_u16();
    let dur = start.elapsed();
    let route = route_of(&path);

    if let Ok(mut m) = st.reqs.lock() {
        *m.entry((route, status)).or_insert(0) += 1;
    }
    if route == "root" || route == "erro" {
        let secs = dur.as_secs_f64();
        let idx = BOUNDS.iter().position(|b| secs <= *b).unwrap_or(BOUNDS.len());
        st.buckets[idx].fetch_add(1, Ordering::Relaxed);
        st.hist_count.fetch_add(1, Ordering::Relaxed);
        st.hist_sum_us.fetch_add(dur.as_micros() as u64, Ordering::Relaxed);
    }

    if let Ok(v) = HeaderValue::from_str(&st.node) {
        resp.headers_mut().insert("x-node", v);
    }
    if let Ok(v) = HeaderValue::from_str(&rid) {
        resp.headers_mut().insert("x-request-id", v);
    }

    let level = if status >= 500 { "WARN" } else { "INFO" };
    log(
        &st.node,
        level,
        &format!(
            "request_id={} client={} method={} path={} status={} dur_ms={}",
            rid,
            addr.ip(),
            method,
            path,
            status,
            dur.as_millis()
        ),
    );
    resp
}

// ---------- handlers ----------

async fn artificial_delay(st: &AppState) {
    let ms = st.delay_ms.load(Ordering::Relaxed);
    if ms > 0 {
        tokio::time::sleep(Duration::from_millis(ms)).await;
    }
}

async fn root(State(st): State<Shared>) -> impl IntoResponse {
    artificial_delay(&st).await;
    (StatusCode::OK, format!("atendido por {}\n", st.node))
}

async fn erro() -> impl IntoResponse {
    (StatusCode::INTERNAL_SERVER_ERROR, "erro simulado\n")
}

async fn live() -> impl IntoResponse {
    (StatusCode::OK, "live\n")
}

async fn ready(State(st): State<Shared>) -> impl IntoResponse {
    artificial_delay(&st).await;
    if st.effective_ready() {
        (StatusCode::OK, "ready\n")
    } else {
        (StatusCode::SERVICE_UNAVAILABLE, "not ready\n")
    }
}

async fn admin_ready(
    State(st): State<Shared>,
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    match q.get("v").map(|s| s.as_str()) {
        Some("1") => st.ready_flag.store(true, Ordering::Relaxed),
        Some("0") => st.ready_flag.store(false, Ordering::Relaxed),
        _ => return (StatusCode::BAD_REQUEST, "use /admin/ready?v=0 ou v=1\n".to_string()),
    }
    let v = st.ready_flag.load(Ordering::Relaxed);
    log(&st.node, "WARN", &format!("event=admin_ready ready_flag={}", v));
    (StatusCode::OK, format!("ready_flag={}\n", v))
}

async fn admin_atraso(
    State(st): State<Shared>,
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let ms = match q.get("ms").and_then(|s| s.parse::<u64>().ok()) {
        Some(v) if v <= MAX_DELAY_MS => v,
        _ => {
            return (
                StatusCode::BAD_REQUEST,
                format!("use /admin/atraso?ms=N com N entre 0 e {}\n", MAX_DELAY_MS),
            )
        }
    };
    st.delay_ms.store(ms, Ordering::Relaxed);
    log(&st.node, "WARN", &format!("event=admin_atraso delay_ms={}", ms));
    (StatusCode::OK, format!("delay_ms={}\n", ms))
}

async fn admin_status(State(st): State<Shared>) -> impl IntoResponse {
    format!(
        "node={} ready_flag={} effective_ready={} delay_ms={} uptime_s={}\n",
        st.node,
        st.ready_flag.load(Ordering::Relaxed),
        st.effective_ready(),
        st.delay_ms.load(Ordering::Relaxed),
        st.started.elapsed().as_secs()
    )
}

async fn metrics(State(st): State<Shared>) -> impl IntoResponse {
    let n = &st.node;
    let mut o = String::with_capacity(4096);

    o.push_str("# HELP sentinel_http_requests_total Requisicoes HTTP por rota e codigo.\n");
    o.push_str("# TYPE sentinel_http_requests_total counter\n");
    if let Ok(m) = st.reqs.lock() {
        for ((route, code), v) in m.iter() {
            o.push_str(&format!(
                "sentinel_http_requests_total{{node=\"{}\",route=\"{}\",code=\"{}\"}} {}\n",
                n, route, code, v
            ));
        }
    }

    o.push_str("# HELP sentinel_app_request_duration_seconds Latencia do trafego de usuario (rotas / e /erro), medida no no.\n");
    o.push_str("# TYPE sentinel_app_request_duration_seconds histogram\n");
    let mut cum = 0u64;
    for (i, b) in BOUNDS.iter().enumerate() {
        cum += st.buckets[i].load(Ordering::Relaxed);
        o.push_str(&format!(
            "sentinel_app_request_duration_seconds_bucket{{node=\"{}\",le=\"{}\"}} {}\n",
            n, b, cum
        ));
    }
    cum += st.buckets[BOUNDS.len()].load(Ordering::Relaxed);
    o.push_str(&format!(
        "sentinel_app_request_duration_seconds_bucket{{node=\"{}\",le=\"+Inf\"}} {}\n",
        n, cum
    ));
    o.push_str(&format!(
        "sentinel_app_request_duration_seconds_sum{{node=\"{}\"}} {}\n",
        n,
        st.hist_sum_us.load(Ordering::Relaxed) as f64 / 1e6
    ));
    o.push_str(&format!(
        "sentinel_app_request_duration_seconds_count{{node=\"{}\"}} {}\n",
        n,
        st.hist_count.load(Ordering::Relaxed)
    ));

    o.push_str("# HELP sentinel_ready 1 se o no esta pronto para receber trafego.\n# TYPE sentinel_ready gauge\n");
    o.push_str(&format!("sentinel_ready{{node=\"{}\"}} {}\n", n, st.effective_ready() as u8));
    o.push_str("# HELP sentinel_artificial_delay_ms Atraso artificial configurado (ms).\n# TYPE sentinel_artificial_delay_ms gauge\n");
    o.push_str(&format!(
        "sentinel_artificial_delay_ms{{node=\"{}\"}} {}\n",
        n,
        st.delay_ms.load(Ordering::Relaxed)
    ));
    o.push_str("# HELP sentinel_inflight_requests Requisicoes em andamento (saturacao).\n# TYPE sentinel_inflight_requests gauge\n");
    o.push_str(&format!(
        "sentinel_inflight_requests{{node=\"{}\"}} {}\n",
        n,
        st.inflight.load(Ordering::Relaxed)
    ));
    o.push_str("# HELP sentinel_uptime_seconds Tempo desde o inicio do processo.\n# TYPE sentinel_uptime_seconds gauge\n");
    o.push_str(&format!(
        "sentinel_uptime_seconds{{node=\"{}\"}} {}\n",
        n,
        st.started.elapsed().as_secs_f64()
    ));
    o.push_str("# HELP sentinel_info Informacoes estaticas do no.\n# TYPE sentinel_info gauge\n");
    o.push_str(&format!(
        "sentinel_info{{node=\"{}\",version=\"{}\",framework=\"axum\"}} 1\n",
        n,
        env!("CARGO_PKG_VERSION")
    ));

    ([(CONTENT_TYPE, "text/plain; version=0.0.4; charset=utf-8")], o)
}

async fn fallback() -> impl IntoResponse {
    (StatusCode::NOT_FOUND, "nao encontrado\n")
}

// ---------- healthcheck do Docker (sem dependencias externas) ----------

fn run_healthcheck(port: u16) -> i32 {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut s = match TcpStream::connect_timeout(&addr, Duration::from_secs(2)) {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    let req = "GET /health/live HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    if s.write_all(req.as_bytes()).is_err() {
        return 1;
    }
    let mut buf = [0u8; 64];
    match s.read(&mut buf) {
        Ok(n) if n >= 12 && &buf[9..12] == b"200" => 0,
        _ => 1,
    }
}

async fn shutdown_signal(node: String) {
    use tokio::signal::unix::{signal, SignalKind};
    let mut term = signal(SignalKind::terminate()).expect("sigterm");
    let mut int = signal(SignalKind::interrupt()).expect("sigint");
    tokio::select! {
        _ = term.recv() => {},
        _ = int.recv() => {},
    }
    log(&node, "INFO", "event=shutdown motivo=sinal");
}

#[tokio::main]
async fn main() {
    let port = env_u64("PORT", 8080) as u16;
    if std::env::args().any(|a| a == "--healthcheck") {
        std::process::exit(run_healthcheck(port));
    }

    let node = std::env::var("NODE_NAME").unwrap_or_else(|_| "node".to_string());
    let warmup = Duration::from_secs(env_u64("WARMUP_SECONDS", 3));
    let delay0 = env_u64("INITIAL_DELAY_MS", 0).min(MAX_DELAY_MS);

    let state: Shared = Arc::new(AppState {
        node: node.clone(),
        started: Instant::now(),
        warmup,
        ready_flag: AtomicBool::new(true),
        delay_ms: AtomicU64::new(delay0),
        inflight: AtomicU64::new(0),
        seq: AtomicU64::new(1),
        reqs: Mutex::new(BTreeMap::new()),
        buckets: (0..=BOUNDS.len()).map(|_| AtomicU64::new(0)).collect(),
        hist_count: AtomicU64::new(0),
        hist_sum_us: AtomicU64::new(0),
    });

    let app = Router::new()
        .route("/", get(root))
        .route("/erro", get(erro))
        .route("/health/live", get(live))
        .route("/health/ready", get(ready))
        .route("/metrics", get(metrics))
        .route("/admin/ready", get(admin_ready))
        .route("/admin/atraso", get(admin_atraso))
        .route("/admin/status", get(admin_status))
        .fallback(fallback)
        .layer(middleware::from_fn_with_state(state.clone(), track))
        .with_state(state.clone());

    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let listener = tokio::net::TcpListener::bind(addr).await.expect("bind");
    log(
        &node,
        "INFO",
        &format!(
            "event=start framework=axum port={} warmup_s={} initial_delay_ms={}",
            port,
            warmup.as_secs(),
            delay0
        ),
    );

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal(node.clone()))
    .await
    .expect("serve");
}
