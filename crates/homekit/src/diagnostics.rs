//! Shareable support reports built from an explicit allow-list, never from device/config serialization.
use chrono::{DateTime, Local, SecondsFormat, Utc};
use mijialan_core::Engine;
use regex::{Captures, Regex};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    io::Write,
    net::Ipv6Addr,
    path::{Path, PathBuf},
    sync::OnceLock,
    time::SystemTime,
};

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadFailure {
    pub device_id: String,
    pub aid: u64,
    pub iid: u64,
    pub service: String,
    pub characteristic: String,
    pub source: String,
    pub status: i32,
}

#[derive(Clone, Debug, Default)]
pub struct BridgeDiagnostics {
    pub status: String,
    pub paired: bool,
    pub pairing_state_known: bool,
    pub accessories: usize,
    pub keeps_awake: bool,
    pub structure_revision: u64,
    pub read_failures: Vec<ReadFailure>,
}

#[derive(Clone, Debug)]
pub struct ApplicationInfo {
    pub version: String,
    pub build: String,
    pub os_version: String,
}
impl Default for ApplicationInfo {
    fn default() -> Self {
        Self {
            version: env!("CARGO_PKG_VERSION").into(),
            build: String::new(),
            os_version: format!("{} {}", std::env::consts::OS, std::env::consts::ARCH),
        }
    }
}

pub fn timestamp(time: SystemTime) -> String {
    DateTime::<Utc>::from(time).to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn sensitive(name: &str) -> bool {
    let normalized = name.to_ascii_lowercase().replace('_', "-");
    let compact = normalized.replace(['-', ' '], "");
    if [
        "ipaddress",
        "macaddress",
        "privatekey",
        "publickey",
        "pairingkey",
        "pairingcode",
        "setupcode",
        "setuppin",
        "ltsk",
        "ltpk",
    ]
    .contains(&compact.as_str())
        || [
            "token",
            "password",
            "passwd",
            "secret",
            "credential",
            "credentials",
            "ssid",
        ]
        .iter()
        .any(|suffix| compact.ends_with(suffix))
    {
        return true;
    }
    normalized.split(['-', ' ']).any(|part| {
        [
            "token",
            "password",
            "passwd",
            "secret",
            "ssecurity",
            "servicetoken",
            "passtoken",
            "authorization",
            "credential",
            "credentials",
            "ssid",
            "bssid",
            "ip",
            "mac",
            "pairing",
            "certificate",
        ]
        .contains(&part)
    }) || ["private-key", "public-key", "setup-code"]
        .iter()
        .any(|part| normalized.contains(part))
}

pub fn redact(text: &str) -> String {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| [
        r"(?i)\b[0-9a-f]{32,}\b",
        r"(?i)\b(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b",
        r"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b",
        r"\b[0-9]{3}-[0-9]{2}-[0-9]{3}\b",
        r#"(?i)X-HM://[^\s"<>]+"#,
        r#"(?i)\b(?:token|password|passwd|secret|ssecurity|servicetoken|passtoken|authorization|(?:private|public)[-_ ]?key|(?:access|refresh)[-_ ]?token|ltsk|ltpk|ssid|bssid|pairing[-_ ]?(?:key|code)|setup[-_ ]?(?:code|pin))["']?\s*[:=]\s*(?:"[^"]*"|'[^']*'|[^\s,;&}]+)"#,
    ].into_iter().map(|pattern| Regex::new(pattern).expect("diagnostic redaction expression")).collect());
    let mut output = text.to_owned();
    for pattern in patterns {
        output = pattern.replace_all(&output, "[redacted]").into_owned();
    }
    static IPV6: OnceLock<Regex> = OnceLock::new();
    IPV6.get_or_init(|| {
        Regex::new(r"(?i)(?:[0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}(?:%[a-z0-9_.-]+)?").unwrap()
    })
    .replace_all(&output, |matched: &Captures<'_>| {
        let candidate = &matched[0];
        if candidate
            .split('%')
            .next()
            .unwrap_or_default()
            .parse::<Ipv6Addr>()
            .is_ok()
        {
            "[redacted]".to_string()
        } else {
            candidate.to_string()
        }
    })
    .into_owned()
}

fn public_value(value: &Value) -> Value {
    match value {
        Value::String(text) => Value::String(redact(text)),
        Value::Array(items) => Value::Array(items.iter().map(public_value).collect()),
        Value::Object(items) => Value::Object(
            items
                .iter()
                .filter(|(key, _)| !sensitive(key))
                .map(|(key, value)| (redact(key), public_value(value)))
                .collect(),
        ),
        value => value.clone(),
    }
}

pub fn report(
    engine: &Engine,
    bridge: &crate::HomeKit,
    application: &ApplicationInfo,
    now: SystemTime,
) -> Value {
    let states = engine.states();
    let probes = engine.probe_diagnostics();
    let bridge = bridge.diagnostic_snapshot(&states);
    let mut failures = BTreeMap::<&str, Vec<&ReadFailure>>::new();
    for failure in &bridge.read_failures {
        failures
            .entry(&failure.device_id)
            .or_default()
            .push(failure);
    }
    let devices: Vec<_> = states.iter().map(|state| {
        let document = mijialan_core::Specification::bundled(&state.device.model).map(str::to_owned)
            .or_else(|| engine.store.cached_spec(&state.device.model));
        let spec_type = document.and_then(|text| serde_json::from_str::<Value>(&text).ok())
            .and_then(|value| value["type"].as_str().map(str::to_owned));
        let probe = probes.get(&state.device.did);
        let readings: Vec<_> = state.spec.properties.iter().filter(|p| p.readable && !sensitive(&p.name)).map(|property| {
            let key = property.key();
            let value = state.values.get(&key).map(|value| public_value(value).to_string());
            let error = state.errors.get(&key);
            let code = if let Some(error) = error {
                error.strip_prefix("设备返回 ").and_then(|code| code.parse::<i64>().ok())
            } else { value.as_ref().map(|_| 0) };
            json!({"id":format!("p:{}:{}", property.siid, property.piid), "name":property.label(),
                "value":value, "code":code, "error":error,
                "updatedAt":probe.and_then(|p| p.last_read).map(timestamp)})
        }).collect();
        let home_failures: Vec<_> = failures.get(state.device.did.as_str()).into_iter().flatten().map(|failure| {
            json!({"service":failure.service, "characteristic":failure.characteristic, "source":failure.source,
                "status":failure.status, "aid":failure.aid, "iid":failure.iid})
        }).collect();
        json!({"did":state.device.did, "model":state.device.model, "name":state.device.name,
            "health":if state.online {"online"} else if state.error.is_some() {"offline"} else {"unknown"},
            "homeIncluded":state.device.bridged, "homeKitSupported":crate::mapping::maps_to_home(state), "specType":spec_type,
            "lastError":state.error, "lastSeen":probe.and_then(|p| p.last_seen).map(timestamp),
            "retryFailures":probe.map_or(0, |p| p.retry_failures),
            "nextRetryAt":probe.and_then(|p| p.next_retry_at).map(timestamp),
            "isProbing":probe.is_some_and(|p| p.active_probes > 0),
            "revision":state.revision, "readings":readings, "homeKitReadFailures":home_failures})
    }).collect();
    let mut report = json!({"reportVersion":1, "recordedAt":timestamp(now),
        "app":{"version":application.version,"build":application.build,"implementation":"rust"},
        "platform":std::env::consts::OS,"architecture":std::env::consts::ARCH,"osVersion":application.os_version,
        "language":if mijialan_core::localization::english(){"en"}else{"zh-Hans"},"demo":engine.is_demo(),
        "bridge":bridge.status,"paired":bridge.paired,"pairingStateKnown":bridge.pairing_state_known,
        "accessories":bridge.accessories,"keepsMacAwake":bridge.keeps_awake,
        "structureRevision":bridge.structure_revision,
        "valuesRevision":states.iter().fold(0u64, |total, state| total.saturating_add(state.revision)),"devices":devices});
    if cfg!(target_os = "macos") {
        report["macOS"] = json!(application.os_version);
    }
    public_value(&report)
}

/// Create an atomic, private report; never overwrite an existing export or follow its symlink.
pub fn write_report(path: &Path, report: &Value) -> anyhow::Result<PathBuf> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    std::fs::create_dir_all(parent)?;
    let mut output = tempfile::NamedTempFile::new_in(parent)?;
    serde_json::to_writer_pretty(&mut output, &public_value(report))?;
    output.write_all(b"\n")?;
    output.as_file().sync_all()?;
    output
        .persist_noclobber(path)
        .map_err(|error| error.error)?;
    Ok(path.to_owned())
}

pub fn suggested_name(now: SystemTime) -> String {
    format!(
        "MijiaLAN-Rust-Diagnostics-{}.json",
        DateTime::<Local>::from(now).format("%Y%m%d-%H%M%S%.3f")
    )
}
