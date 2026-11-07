use async_channel::Sender;
use std::time::Duration;
use zbus::{
    blocking::{Connection, Proxy, connection::Builder},
    fdo::RequestNameFlags,
};

const APPLICATION: &str = "xyz.ipocket.MijiaLAN.Rust";
const ACTIVATION_PATH: &str = "/xyz/ipocket/MijiaLAN/Rust";
const ACTIVATION_INTERFACE: &str = "xyz.ipocket.MijiaLAN.Rust.Activation";

struct Activation(Sender<String>);

#[zbus::interface(name = "xyz.ipocket.MijiaLAN.Rust.Activation")]
impl Activation {
    fn activate(&self, token: String) {
        let _ = self.0.try_send(token);
    }
}

pub fn session() -> zbus::Result<Connection> {
    Builder::session()?
        .method_timeout(Duration::from_secs(2))
        .build()
}

/// Return true when the running instance accepted the activation.
pub fn reopen_existing(
    bus: &Connection,
    sender: Sender<String>,
    token: &str,
) -> zbus::Result<bool> {
    bus.object_server()
        .at(ACTIVATION_PATH, Activation(sender))?;
    match bus.request_name_with_flags(APPLICATION, RequestNameFlags::DoNotQueue.into()) {
        Ok(_) => Ok(false),
        Err(zbus::Error::NameTaken) => {
            Proxy::new(bus, APPLICATION, ACTIVATION_PATH, ACTIVATION_INTERFACE)?
                .call::<_, _, ()>("Activate", &(token,))?;
            Ok(true)
        }
        Err(error) => Err(error),
    }
}

pub fn has_tray_host(bus: &Connection) -> bool {
    Proxy::new(
        bus,
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
    )
    .and_then(|watcher| watcher.get_property("IsStatusNotifierHostRegistered"))
    .unwrap_or(false)
}
