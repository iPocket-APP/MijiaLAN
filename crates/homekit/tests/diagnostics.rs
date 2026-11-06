use mijialan_core::{Device, Engine, Store, Token};
use mijialan_homekit::{
    HomeKit,
    diagnostics::{self, ApplicationInfo},
    mapping::{self, Layout},
};
use serde_json::{Value, json};
use std::{
    net::{Ipv4Addr, SocketAddr},
    sync::{Arc, atomic::Ordering},
    time::SystemTime,
};

mod support;

#[test]
fn exported_fields_match_native_without_reading_or_creating_bridge_credentials() {
    let store = Arc::new(Store::memory());
    let token = "00112233445566778899aabbccddeeff";
    store
        .put(
            Device {
                did: "123".into(),
                name: "落地扇".into(),
                model: "dmaker.fan.p28".into(),
                host: Ipv4Addr::new(192, 168, 31, 57),
                room: "private room".into(),
                port: 54321,
                bridged: true,
            },
            &Token::parse(token).unwrap(),
        )
        .unwrap();
    // Deliberately invalid: an exporter must not decode, replace or serialize identity material.
    store
        .vault
        .set(
            "homekit:identity",
            Some("PAIRING_SECRET_MUST_NOT_BE_READ".into()),
        )
        .unwrap();
    let engine = Arc::new(Engine::new(store.clone(), false));
    let bridge = HomeKit::new(engine.clone());
    let data = diagnostics::report(
        &engine,
        &bridge,
        &ApplicationInfo::default(),
        SystemTime::UNIX_EPOCH,
    );
    let text = serde_json::to_string(&data).unwrap();
    for secret in [
        token,
        "192.168.31.57",
        "private room",
        "PAIRING_SECRET_MUST_NOT_BE_READ",
    ] {
        assert!(!text.contains(secret), "{secret}");
    }
    assert_eq!(data["recordedAt"], "1970-01-01T00:00:00.000Z");
    assert_eq!(data["app"]["implementation"], "rust");
    assert_eq!(data["devices"][0]["did"], "123");
    assert_eq!(data["devices"][0]["homeIncluded"], true);
    assert!(
        data["devices"][0]["specType"]
            .as_str()
            .unwrap()
            .starts_with("urn:miot-spec")
    );
    assert_eq!(data["bridge"], "stopped");
    assert_eq!(data["pairingStateKnown"], false);
    assert!(!bridge.info().running);
    assert_eq!(
        store.vault.get("homekit:identity").unwrap().unwrap(),
        "PAIRING_SECRET_MUST_NOT_BE_READ"
    );
}

#[test]
fn report_explains_the_same_failures_as_homekit_reads_and_drops_them_after_recovery() {
    let fixture = support::MiotDevice::start();
    let store = Arc::new(Store::memory());
    store
        .put(
            Device {
                did: "77".into(),
                name: "Fixture Purifier".into(),
                model: "zhimi.airpurifier.rma1".into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port: fixture.port,
                bridged: true,
            },
            &Token::parse(support::TOKEN).unwrap(),
        )
        .unwrap();
    let engine = Arc::new(Engine::new(store, false));
    fixture.phase.store(1, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    let bridge = HomeKit::new(engine.clone());
    bridge
        .start_at(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)), false)
        .unwrap();
    let original = bridge.info();
    let database = mapping::build(&engine, &mut Layout::default());
    let snapshot = bridge.diagnostic_snapshot(&engine.states());
    assert!(!snapshot.read_failures.is_empty());
    for failure in &snapshot.read_failures {
        assert_eq!(
            database.read(&engine, failure.aid, failure.iid, false),
            Err(failure.status)
        );
        assert!(failure.source.starts_with("p:"));
    }
    let report = diagnostics::report(
        &engine,
        &bridge,
        &ApplicationInfo::default(),
        SystemTime::now(),
    );
    let device = &report["devices"][0];
    assert_eq!(
        device["homeKitReadFailures"].as_array().unwrap().len(),
        snapshot.read_failures.len()
    );
    assert!(device["lastSeen"].as_str().is_some());
    assert_eq!(device["isProbing"], false);
    let text = report.to_string();
    for secret in [
        support::TOKEN,
        original.code.as_str(),
        original.uri.as_str(),
        "127.0.0.1",
    ] {
        assert!(!text.contains(secret));
    }
    fixture.phase.store(0, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    assert!(
        bridge
            .diagnostic_snapshot(&engine.states())
            .read_failures
            .is_empty()
    );
    assert_eq!(bridge.info().uri, original.uri);
    bridge.stop();
    assert_eq!(fixture.writes.load(Ordering::SeqCst), 0);
    assert!(fixture.commands.lock().unwrap().is_empty());
}

#[test]
fn diagnostic_redaction_covers_nested_data_errors_ipv6_and_setup_codes() {
    let values = [
        "00112233445566778899aabbccddeeff",
        "AA:BB:CC:DD:EE:FF",
        "192.168.31.57",
        "fe80::1234%en0",
        "123-45-678",
        "X-HM://001234ABCD",
        "password=hunter2",
        "token: plainSecret",
        "privateKey=Base64PrivateSigningKey==",
    ];
    for value in values {
        let output = diagnostics::redact(value);
        assert!(!output.contains(value), "not redacted: {value} -> {output}");
    }
    for safe in [
        "p:2:1 Direct",
        "urn:miot-spec-v2:device:fan:0000A005:dmaker-p28:1",
        "-70402",
    ] {
        assert_eq!(diagnostics::redact(safe), safe);
    }
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("report.json");
    diagnostics::write_report(&path,&json!({"devices":[{"name":"台灯", "readings":[{"value":{
        "token":"NOT_FOR_EXPORT", "wifi-password":"NOT_FOR_EXPORT", "wifiPassword":"NOT_FOR_EXPORT", "privateKey":"NOT_FOR_EXPORT", "pairingKey":"NOT_FOR_EXPORT", "refreshToken":"NOT_FOR_EXPORT", "state":"on", "address":"192.168.31.57"}}]}]})).unwrap();
    let text = std::fs::read_to_string(path).unwrap();
    assert!(!text.contains("NOT_FOR_EXPORT"));
    assert!(!text.contains("192.168.31.57"));
    assert!(text.contains("台灯") && text.contains("on"));
}

#[test]
fn exports_are_private_complete_and_do_not_overwrite_existing_files() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory
        .path()
        .join(diagnostics::suggested_name(SystemTime::UNIX_EPOCH));
    assert!(!path.file_name().unwrap().to_string_lossy().contains(':'));
    diagnostics::write_report(&path, &json!({"recordedAt":"now","devices":[]})).unwrap();
    let before = std::fs::read(&path).unwrap();
    assert!(diagnostics::write_report(&path, &json!({"different":true})).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), before);
    serde_json::from_slice::<Value>(&before).unwrap();
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(path).unwrap().permissions().mode() & 0o077,
            0
        );
    }
}

#[test]
fn failed_credential_reads_clear_probe_activity_and_do_not_retain_removed_devices() {
    let store = Arc::new(Store::memory());
    store
        .update(|config| {
            config.devices.push(Device {
                did: "no-token".into(),
                name: "Fixture".into(),
                model: "dmaker.fan.p28".into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port: 1,
                bridged: true,
            })
        })
        .unwrap();
    let engine = Engine::new(store, false);
    assert!(engine.refresh("no-token").is_err());
    let probes = engine.probe_diagnostics();
    assert_eq!(probes["no-token"].active_probes, 0);
    assert!(probes["no-token"].last_seen.is_none());
    engine.remove("no-token").unwrap();
    assert!(!engine.probe_diagnostics().contains_key("no-token"));
    assert!(engine.refresh("removed").is_err());
    assert!(!engine.probe_diagnostics().contains_key("removed"));
}
