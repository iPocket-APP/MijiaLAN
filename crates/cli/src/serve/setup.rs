use super::Service;
use anyhow::{Context, Result};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Request, State},
    http::{HeaderMap, HeaderValue, Method, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
};
use mijialan_core::{
    cloud,
    import_job::{ImportJob, Progress},
};
use mijialan_homekit::mapping;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeSet,
    net::SocketAddrV4,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use subtle::ConstantTimeEq;
use tokio::{
    net::TcpListener,
    sync::Notify,
    time::{self, Instant},
};

const WINDOW: Duration = Duration::from_secs(20 * 60);
const SESSION_COOKIE: &str = "mijialan_setup";
const POLICY: &str = "default-src 'none'; script-src 'self'; style-src 'self'; img-src data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";

type Failure = (StatusCode, String);

struct Auth {
    code: Option<String>,
    session: String,
}

struct Wizard {
    service: Arc<Service>,
    import: Arc<ImportJob>,
    host: String,
    origin: String,
    deadline: Instant,
    auth: Mutex<Auth>,
    closed: AtomicBool,
    finished: Notify,
}

impl Wizard {
    fn active(&self) -> bool {
        !self.closed.load(Ordering::Relaxed) && Instant::now() < self.deadline
    }

    fn require_active(&self) -> Result<(), Failure> {
        if self.active() {
            Ok(())
        } else {
            Err((StatusCode::GONE, "设置窗口已关闭".into()))
        }
    }

    fn authenticated(&self, headers: &HeaderMap) -> bool {
        let auth = self.auth.lock().unwrap();
        auth.code.is_none()
            && headers
                .get(header::COOKIE)
                .and_then(|value| value.to_str().ok())
                .is_some_and(|cookies| {
                    cookies.split(';').any(|cookie| {
                        let (name, value) = cookie.trim().split_once('=').unwrap_or_default();
                        name == SESSION_COOKIE && matches_secret(&auth.session, value)
                    })
                })
    }

    fn close(&self) {
        self.closed.store(true, Ordering::Relaxed);
        self.import.cancel();
        self.finished.notify_one();
    }
}

impl Drop for Wizard {
    fn drop(&mut self) {
        self.import.cancel();
    }
}

fn matches_secret(expected: &str, actual: &str) -> bool {
    bool::from(expected.as_bytes().ct_eq(actual.as_bytes()))
}

pub(super) async fn run(service: Arc<Service>, address: SocketAddrV4) -> Result<()> {
    let listener = TcpListener::bind(address)
        .await
        .with_context(|| format!("无法在 {address} 打开设置向导，请检查 NAS 地址和端口占用"))?;
    let code = hex::encode(rand::random::<[u8; 24]>());
    let wizard = Arc::new(Wizard {
        service,
        import: Arc::new(ImportJob::default()),
        host: address.to_string(),
        origin: format!("http://{address}"),
        deadline: Instant::now() + WINDOW,
        auth: Mutex::new(Auth {
            code: Some(code.clone()),
            session: hex::encode(rand::random::<[u8; 24]>()),
        }),
        closed: AtomicBool::new(false),
        finished: Notify::new(),
    });
    println!(
        "请在可信局域网打开 {}，向导将在 20 分钟后关闭",
        wizard.origin
    );
    println!("一次性设置码: {code}");
    serve(listener, wizard).await?;
    println!("浏览器设置向导已关闭");
    Ok(())
}

async fn serve(listener: TcpListener, wizard: Arc<Wizard>) -> std::io::Result<()> {
    let routes = routes(wizard.clone());
    axum::serve(listener, routes)
        .with_graceful_shutdown(async move {
            tokio::select! {
                _ = time::sleep_until(wizard.deadline) => wizard.close(),
                _ = wizard.finished.notified() => {},
            }
        })
        .await
}

fn routes(wizard: Arc<Wizard>) -> Router {
    Router::new()
        .route("/", get(|| async { Html(include_str!("setup.html")) }))
        .route(
            "/setup.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("setup.css"),
                )
            }),
        )
        .route(
            "/setup.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("setup.js"),
                )
            }),
        )
        .route("/api/unlock", post(unlock))
        .route("/api/state", get(status))
        .route("/api/import", post(import))
        .route("/api/bridge", post(select_devices))
        .route("/api/finish", post(finish))
        .layer(DefaultBodyLimit::max(32 * 1024))
        .layer(middleware::from_fn_with_state(wizard.clone(), guard))
        .with_state(wizard)
}

async fn guard(State(wizard): State<Arc<Wizard>>, request: Request, next: Next) -> Response {
    let headers = request.headers();
    let allowed_host = headers
        .get(header::HOST)
        .is_some_and(|value| value == wizard.host.as_str());
    let allowed_origin = request.method() != Method::POST
        || headers
            .get(header::ORIGIN)
            .is_some_and(|value| value == wizard.origin.as_str());
    let path = request.uri().path();
    let mut response = if let Err(error) = wizard.require_active() {
        error.into_response()
    } else if !allowed_host || !allowed_origin {
        (StatusCode::FORBIDDEN, "请直接使用 NAS 局域网地址访问向导").into_response()
    } else if path.starts_with("/api/") && path != "/api/unlock" && !wizard.authenticated(headers) {
        (StatusCode::UNAUTHORIZED, "请输入一次性设置码").into_response()
    } else {
        let deadline = wizard.deadline.min(Instant::now() + Duration::from_secs(8));
        time::timeout_at(deadline, next.run(request))
            .await
            .unwrap_or_else(|_| (StatusCode::REQUEST_TIMEOUT, "请求超时，请重试").into_response())
    };
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        HeaderValue::from_static(POLICY),
    );
    headers.insert(
        header::REFERRER_POLICY,
        HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    response
}

#[derive(Deserialize)]
struct Unlock {
    code: String,
}

async fn unlock(
    State(wizard): State<Arc<Wizard>>,
    Json(body): Json<Unlock>,
) -> Result<Response, Failure> {
    wizard.require_active()?;
    let mut auth = wizard.auth.lock().unwrap();
    if !auth
        .code
        .as_ref()
        .is_some_and(|code| matches_secret(code, &body.code))
    {
        return Err((
            StatusCode::UNAUTHORIZED,
            "设置码错误或已使用。可从原浏览器继续，或在 DSM 重新启动向导。".into(),
        ));
    }
    auth.code = None;
    let ttl = wizard
        .deadline
        .saturating_duration_since(Instant::now())
        .as_secs()
        .max(1);
    let cookie = format!(
        "{SESSION_COOKIE}={}; HttpOnly; SameSite=Strict; Path=/; Max-Age={ttl}",
        auth.session
    );
    Ok((StatusCode::NO_CONTENT, [(header::SET_COOKIE, cookie)]).into_response())
}

fn qr_svg(text: &str) -> Option<String> {
    qrcode::QrCode::new(text.as_bytes()).ok().map(|qr| {
        qr.render::<qrcode::render::svg::Color>()
            .min_dimensions(264, 264)
            .quiet_zone(true)
            .build()
    })
}

#[derive(Serialize)]
struct DeviceOption {
    id: String,
    name: String,
    room: String,
    available: bool,
    online: bool,
    selected: bool,
}

async fn status(State(wizard): State<Arc<Wizard>>) -> impl IntoResponse {
    let (progress, detail, login_qr) = match wizard.import.snapshot() {
        Progress::Idle => ("idle", None, None),
        Progress::Fetching => ("fetching", None, None),
        Progress::Waiting(ticket) => ("waiting", None, qr_svg(&ticket.login_url)),
        Progress::Importing => ("importing", None, None),
        Progress::Done(text) => ("done", Some(text), None),
        Progress::Failed(message) => ("failed", Some(message), None),
    };
    let bridge = wizard.service.bridge.info();
    let devices: Vec<_> = wizard
        .service
        .engine
        .states()
        .into_iter()
        .map(|state| {
            let available = mapping::maps_to_home(&state);
            let device = state.device;
            DeviceOption {
                id: device.did,
                name: device.name,
                room: device.room,
                available,
                online: state.online,
                selected: device.bridged,
            }
        })
        .collect();
    Json(serde_json::json!({
        "import": { "progress": progress, "detail": detail, "qr": login_qr },
        "devices": devices,
        "bridge": {
            "running": bridge.running,
            "paired": bridge.paired,
            "qr": if bridge.running && !bridge.paired { qr_svg(&bridge.uri) } else { None },
            "pin": (bridge.running && !bridge.paired).then_some(bridge.code),
        },
    }))
}

#[derive(Deserialize)]
struct Import {
    region: String,
}

async fn import(
    State(wizard): State<Arc<Wizard>>,
    Json(body): Json<Import>,
) -> Result<StatusCode, Failure> {
    wizard.require_active()?;
    if !cloud::regions().contains(&body.region.as_str()) {
        return Err((StatusCode::BAD_REQUEST, "请选择有效的米家区域".into()));
    }
    require_idle(&wizard)?;
    wizard
        .import
        .start_unbridged(wizard.service.engine.clone(), body.region);
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
struct Selection {
    devices: BTreeSet<String>,
}

async fn select_devices(
    State(wizard): State<Arc<Wizard>>,
    Json(body): Json<Selection>,
) -> Result<StatusCode, Failure> {
    wizard.require_active()?;
    require_idle(&wizard)?;
    let engine = &wizard.service.engine;
    if body.devices.is_empty()
        || body.devices.len() > mapping::MAX_BRIDGED_DEVICES
        || !body.devices.iter().all(|id| {
            engine
                .state(id)
                .is_some_and(|state| mapping::maps_to_home(&state))
        })
    {
        return Err((
            StatusCode::BAD_REQUEST,
            format!(
                "请选择 1 至 {} 台支持 HomeKit 的设备",
                mapping::MAX_BRIDGED_DEVICES
            ),
        ));
    }
    engine
        .select_bridged_devices(&body.devices)
        .map_err(storage_failure)?;
    wizard
        .service
        .start()
        .map_err(|error| (StatusCode::CONFLICT, error.to_string()))?;
    Ok(StatusCode::NO_CONTENT)
}

async fn finish(State(wizard): State<Arc<Wizard>>) -> Result<StatusCode, Failure> {
    wizard.require_active()?;
    require_idle(&wizard)?;
    if !wizard.service.bridge.info().paired {
        return Err((StatusCode::CONFLICT, "请先在 Apple「家庭」完成配对".into()));
    }
    wizard.service.finish_pairing().map_err(storage_failure)?;
    wizard.close();
    Ok(StatusCode::NO_CONTENT)
}

fn require_idle(wizard: &Wizard) -> Result<(), Failure> {
    if wizard.import.busy() {
        Err((StatusCode::CONFLICT, "请等待本次导入完成".into()))
    } else {
        Ok(())
    }
}

fn storage_failure(error: impl std::fmt::Display) -> Failure {
    eprintln!("无法保存家庭桥设置：{error}");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        "无法保存设置，请检查 DSM 中的数据卷状态".into(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::Body,
        http::{self, Request},
    };
    use mijialan_core::Engine;
    use mijialan_homekit::HomeKit;
    use tower::ServiceExt;

    const HOST: &str = "127.0.0.1:17890";
    const ORIGIN: &str = "http://127.0.0.1:17890";

    fn fixture(deadline: Instant) -> Arc<Wizard> {
        let engine = Arc::new(Engine::demo());
        let service = Arc::new(Service {
            engine: engine.clone(),
            bridge: HomeKit::new(engine),
            address: "127.0.0.1:51826".parse().unwrap(),
        });
        Arc::new(Wizard {
            service,
            import: Arc::new(ImportJob::default()),
            host: HOST.into(),
            origin: ORIGIN.into(),
            deadline,
            auth: Mutex::new(Auth {
                code: Some("fixture-code".into()),
                session: "fixture-session".into(),
            }),
            closed: AtomicBool::new(false),
            finished: Notify::new(),
        })
    }

    fn get(path: &str, host: &str) -> http::request::Builder {
        Request::get(path).header(header::HOST, host)
    }

    fn post(path: &str, origin: &str) -> http::request::Builder {
        Request::post(path)
            .header(header::HOST, HOST)
            .header(header::ORIGIN, origin)
            .header(header::CONTENT_TYPE, "application/json")
    }

    async fn send(
        router: &Router,
        request: http::request::Builder,
        body: &'static str,
    ) -> Response {
        router
            .clone()
            .oneshot(request.body(Body::from(body)).unwrap())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn setup_requires_same_origin_and_a_one_time_session() {
        let router = routes(fixture(Instant::now() + WINDOW));
        assert_eq!(
            send(&router, get("/api/state", HOST), "").await.status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            send(&router, get("/", "untrusted.test"), "").await.status(),
            StatusCode::FORBIDDEN
        );
        let payload = r#"{"code":"fixture-code"}"#;
        assert_eq!(
            send(
                &router,
                post("/api/unlock", "http://untrusted.test"),
                payload
            )
            .await
            .status(),
            StatusCode::FORBIDDEN
        );
        let response = send(&router, post("/api/unlock", ORIGIN), payload).await;
        assert_eq!(response.status(), StatusCode::NO_CONTENT);
        let cookie = response.headers()[header::SET_COOKIE]
            .to_str()
            .unwrap()
            .split(';')
            .next()
            .unwrap();
        assert_eq!(
            send(&router, post("/api/unlock", ORIGIN), payload)
                .await
                .status(),
            StatusCode::UNAUTHORIZED
        );
        let status = send(
            &router,
            get("/api/state", HOST).header(header::COOKIE, cookie),
            "",
        )
        .await;
        assert_eq!(status.status(), StatusCode::OK);
        assert_eq!(status.headers()[header::CACHE_CONTROL], "no-store");
        let body = axum::body::to_bytes(status.into_body(), 64 * 1024)
            .await
            .unwrap();
        let data: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(data["bridge"]["pin"].is_null());
        assert_eq!(
            send(
                &router,
                post("/api/finish", ORIGIN).header(header::COOKIE, cookie),
                "{}"
            )
            .await
            .status(),
            StatusCode::CONFLICT
        );
    }

    #[tokio::test]
    async fn an_expired_setup_rejects_requests() {
        let router = routes(fixture(Instant::now()));
        assert_eq!(
            send(&router, get("/", HOST), "").await.status(),
            StatusCode::GONE
        );
    }

    #[tokio::test]
    async fn the_setup_listener_closes_and_rejects_an_occupied_port() {
        let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))
            .await
            .unwrap();
        let std::net::SocketAddr::V4(address) = listener.local_addr().unwrap() else {
            unreachable!()
        };
        let wizard = fixture(Instant::now() + Duration::from_millis(25));
        let error = run(wizard.service.clone(), address).await.unwrap_err();
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::AddrInUse
        );
        time::timeout(Duration::from_secs(3), serve(listener, wizard))
            .await
            .unwrap()
            .unwrap();
        assert!(tokio::net::TcpStream::connect(address).await.is_err());
    }
}
