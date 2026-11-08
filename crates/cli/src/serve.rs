use anyhow::{Context, Result, ensure};
use clap::Args;
use mijialan_core::{Engine, Store};
use mijialan_homekit::HomeKit;
use std::{
    net::{Ipv4Addr, SocketAddrV4},
    path::PathBuf,
    sync::Arc,
};
use tokio::signal::unix::{SignalKind, signal};

mod setup;

#[derive(Args)]
pub struct Options {
    #[arg(long, env = "MIJIALAN_LAN_IP")]
    lan_ip: Ipv4Addr,
    #[arg(long, env = "MIJIALAN_HAP_PORT", default_value_t = 51826, value_parser = clap::value_parser!(u16).range(1024..))]
    hap_port: u16,
    #[arg(long, env = "MIJIALAN_SETUP_PORT", default_value_t = 17890, value_parser = clap::value_parser!(u16).range(1024..))]
    setup_port: u16,
    #[arg(long, default_value = "/data")]
    data_dir: PathBuf,
    #[arg(long, default_value = "/keys/master.key")]
    key_file: PathBuf,
    /// Consume an administrator-provisioned one-time setup code.
    #[arg(long)]
    setup_code_file: Option<PathBuf>,
    /// Open a maintenance setup window for an already configured bridge.
    #[arg(long, env = "MIJIALAN_SETUP")]
    setup: bool,
}

struct Service {
    engine: Arc<Engine>,
    bridge: HomeKit,
    address: SocketAddrV4,
}

impl Service {
    fn start(&self) -> Result<()> {
        self.bridge
            .start_at(self.address.into(), true)
            .with_context(|| {
                format!(
                    "无法在 {} 启动 HomeKit 桥，请检查 NAS 地址和端口占用",
                    self.address
                )
            })
    }

    fn finish_pairing(&self) -> Result<()> {
        self.engine
            .store
            .update(|config| config.bridge_enabled = true)?;
        Ok(())
    }
}

#[tokio::main(flavor = "current_thread")]
pub async fn run(options: Options) -> Result<()> {
    let ip = options.lan_ip;
    ensure!(
        !ip.is_unspecified() && !ip.is_loopback() && !ip.is_multicast() && !ip.is_broadcast(),
        "请选择这台 NAS 的局域网 IPv4 地址"
    );
    ensure!(
        options.hap_port != options.setup_port,
        "HomeKit 和向导端口必须不同"
    );
    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    let shutdown = async {
        tokio::select! {
            _ = terminate.recv() => {},
            _ = interrupt.recv() => {},
        }
    };
    tokio::pin!(shutdown);

    let store = Arc::new(Store::open_service(options.data_dir, &options.key_file)?);
    if store.config().keep_awake {
        store.update(|config| config.keep_awake = false)?;
    }
    let engine = Arc::new(Engine::new(store, false));
    let service = Arc::new(Service {
        engine: engine.clone(),
        bridge: HomeKit::new(engine.clone()),
        address: SocketAddrV4::new(ip, options.hap_port),
    });
    let saved = service.bridge.saved_pairing()?;
    let enabled = engine.store.config().bridge_enabled;
    ensure!(
        !enabled || saved.is_some(),
        "桥接身份缺失，请恢复原数据卷备份"
    );
    if saved == Some(true) && !enabled {
        service.finish_pairing()?;
    }
    if enabled || saved == Some(true) {
        service.start()?;
        println!("HomeKit 桥已在 {} 启动", service.address);
    }
    let _poller = engine.start_polling();

    let mut shutting_down = false;
    let code_file = options.setup_code_file.as_deref();
    let staged_setup = code_file
        .map(std::path::Path::try_exists)
        .transpose()?
        .unwrap_or(false);
    if options.setup || staged_setup || !service.bridge.info().paired {
        let address = SocketAddrV4::new(ip, options.setup_port);
        tokio::select! {
            result = setup::run(service.clone(), address, code_file) => {
                if let Err(error) = result {
                    if !service.bridge.info().running {
                        return Err(error);
                    }
                    eprintln!("{error:#}");
                }
                if service.bridge.info().paired && !engine.store.config().bridge_enabled {
                    service.finish_pairing()?;
                } else if !engine.store.config().bridge_enabled {
                    service.bridge.stop();
                }
            }
            _ = &mut shutdown => shutting_down = true,
        }
    }
    if !shutting_down {
        shutdown.await;
    }
    service.bridge.stop();
    Ok(())
}
