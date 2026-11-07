use ed25519_dalek::SigningKey;
use hap_crypto::{
    ControllerKeypair, PairSetupClient, PairSetupStep, PairVerifyClient, PairVerifyStep,
};
use mijialan_core::Engine;
use mijialan_homekit::{
    HomeKit,
    crypto::{self, PairSetup, PairVerify, Session},
};
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{Ipv4Addr, TcpStream},
    sync::Arc,
    time::Duration,
};

mod support;

#[allow(dead_code)]
#[path = "../../core/tests/support/vacuum.rs"]
mod vacuum_support;

#[test]
fn encrypted_fan_speed_commands_and_same_value_error_recovery_match_native() {
    use mijialan_core::{Device, Store, Token};
    use std::sync::atomic::Ordering;
    let document = include_str!("../../core/tests/fixtures/dmaker-p220.json");
    let device = support::MiotDevice::with_spec("dmaker.fan.p220", document);
    let store = Arc::new(Store::memory());
    store.cache_spec("dmaker.fan.p220", document).unwrap();
    store
        .put(
            Device {
                did: "77".into(),
                name: "Fixture Fan".into(),
                model: "dmaker.fan.p220".into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port: device.port,
                bridged: true,
            },
            &Token::parse(support::TOKEN).unwrap(),
        )
        .unwrap();
    let engine = Arc::new(Engine::new(store, false));
    engine.refresh("77").unwrap();
    let bridge = HomeKit::new(engine.clone());
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let info = bridge.info();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let controller = ControllerKeypair::from_seed("native-fan-parity".into(), [67; 32]);
    let accessory = pair_controller(&mut stream, &info.code, &controller);
    let mut session = verify(&mut stream, &controller, &accessory);
    let (_, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
    let db: Value = serde_json::from_slice(&body).unwrap();
    let fan = &db["accessories"][1];
    let aid = fan["aid"].as_u64().unwrap();
    let service = fan["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["type"] == "B7")
        .unwrap();
    assert_eq!(service["primary"], true);
    let speed = service["characteristics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == "29")
        .unwrap();
    let iid = speed["iid"].as_u64().unwrap();
    for value in [0, 75] {
        let body = json!({"characteristics":[{"aid":aid,"iid":iid,"value":value}]}).to_string();
        assert_eq!(
            encrypted_request(
                &mut stream,
                &mut session,
                "PUT",
                "/characteristics",
                body.as_bytes()
            )
            .0,
            204
        );
    }
    let commands = device.commands.lock().unwrap().clone();
    assert_eq!(
        commands.len(),
        3,
        "0% must send power-off only; a nonzero speed sends speed then power-on"
    );
    let params: Vec<_> = commands.iter().map(|r| r["params"][0].clone()).collect();
    assert_eq!(
        (
            params[0]["siid"].clone(),
            params[0]["piid"].clone(),
            params[0]["value"].clone()
        ),
        (json!(2), json!(1), json!(false))
    );
    assert_eq!(params[1]["value"], 75);
    assert_eq!(params[2]["value"], true);
    assert_eq!(engine.state("77").unwrap().values["2.1"], true);
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":true}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let event = |stream: &mut TcpStream, session: &mut Session| -> Value {
        let (_, body) = read_encrypted(stream, session);
        let data: Value = serde_json::from_slice(&body).unwrap();
        data["characteristics"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["iid"] == iid)
            .unwrap()
            .clone()
    };
    assert_eq!(
        event(&mut stream, &mut session)["value"].as_f64(),
        Some(75.)
    );
    device.phase.store(1, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    assert_eq!(event(&mut stream, &mut session)["status"], -70402);
    // Native 0.1.5 corrected this envelope. Rust already emitted status:0 for
    // successful entries: keep that guarantee across devices and value types.
    let child_lock = service["characteristics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == "A7")
        .unwrap()["iid"]
        .as_u64()
        .unwrap();
    let path = format!("/characteristics?id={aid}.{iid},{aid}.{child_lock},1.9");
    let (status, bytes) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
    assert_eq!(status, 207);
    let mixed: Value = serde_json::from_slice(&bytes).unwrap();
    let items = mixed["characteristics"].as_array().unwrap();
    assert_eq!(items[0]["status"], -70402);
    assert!(items[0].get("value").is_none());
    for item in &items[1..] {
        assert_eq!(item["status"], 0);
        assert!(item.get("value").is_some());
    }
    assert_eq!(items[1]["value"], 0);
    assert_eq!(items[2]["value"], "1.1.0");
    let path = format!("/characteristics?id={aid}.{child_lock},1.9");
    let (status, bytes) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
    assert_eq!(status, 200);
    let good: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(
        good["characteristics"]
            .as_array()
            .unwrap()
            .iter()
            .all(|v| v.get("status").is_none())
    );
    device.phase.store(0, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    assert_eq!(
        event(&mut stream, &mut session)["value"].as_f64(),
        Some(75.),
        "recovery with the same number must still emit success"
    );
    drop(stream);
    // A fresh subscription starts while unavailable, and must recover through the same ordered writer.
    device.phase.store(1, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut session = verify(&mut stream, &controller, &accessory);
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    assert_eq!(event(&mut stream, &mut session)["status"], -70402);
    device.phase.store(0, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    assert_eq!(
        event(&mut stream, &mut session)["value"].as_f64(),
        Some(75.)
    );
    stream
        .set_read_timeout(Some(Duration::from_millis(600)))
        .unwrap();
    let mut byte = [0];
    let error = stream.read(&mut byte).unwrap_err();
    assert!(
        matches!(
            error.kind(),
            std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
        ),
        "unexpected old error or duplicate event after recovery"
    );
    assert_eq!(bridge.info().uri, info.uri);
    assert!(bridge.info().paired);
    bridge.stop();
}

#[test]
fn concurrent_listener_start_keeps_one_identity_and_one_running_server() {
    let bridge = Arc::new(HomeKit::new(Arc::new(Engine::demo())));
    std::thread::scope(|scope| {
        for _ in 0..8 {
            let bridge = bridge.clone();
            scope.spawn(move || {
                bridge
                    .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
                    .unwrap()
            });
        }
    });
    let first = bridge.info();
    assert!(first.running && first.port > 0);
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let second = bridge.info();
    assert_eq!(first.port, second.port);
    assert_eq!(first.uri, second.uri);
    bridge.stop();
}

#[test]
fn paired_home_vacuum_switch_starts_cleaning_and_docks_even_when_already_off_but_paused() {
    use std::sync::atomic::Ordering;
    use vacuum_support::{C1, V19, Vacuum};
    // Windows surfaced a timing-sensitive failure in this real-socket path.
    // Exercise transitions repeatedly while the other controller tests are active.
    for repetition in 0..if cfg!(target_os = "windows") { 8 } else { 1 } {
        for (model, document, start_method, dock_method, paused) in [
            ("roborock.vacuum.c1", C1, "app_start", "app_charge", 10),
            ("ijai.vacuum.v19", V19, "action", "action", 2),
        ] {
            let device = Vacuum::start(model, document);
            let engine = device.engine(model, document);
            let bridge = HomeKit::new(engine.clone());
            bridge
                .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
                .unwrap();
            let info = bridge.info();
            let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let controller = ControllerKeypair::from_seed("vacuum-controller".into(), [32; 32]);
            let accessory = pair_controller(&mut stream, &info.code, &controller);
            let mut session = verify(&mut stream, &controller, &accessory);
            let (_, body) =
                encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
            let database: Value = serde_json::from_slice(&body).unwrap();
            let accessory = &database["accessories"][1];
            let aid = accessory["aid"].as_u64().unwrap();
            let service = accessory["services"]
                .as_array()
                .unwrap()
                .iter()
                .find(|s| {
                    s["type"] == "49"
                        && s["characteristics"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|c| c["type"] == "23" && c["value"] == "Fixture Vacuum")
                })
                .unwrap();
            let on = service["characteristics"]
                .as_array()
                .unwrap()
                .iter()
                .find(|c| c["type"] == "25")
                .unwrap();
            assert_eq!(on["value"], false);
            let iid = on["iid"].as_u64().unwrap();
            let path = format!("/characteristics?id={aid}.{iid}");
            for (index, value) in [true, true, false, false, false].into_iter().enumerate() {
                if index == 4 {
                    device.state.store(paused, Ordering::SeqCst);
                    engine.refresh("77").unwrap();
                }
                let body =
                    json!({"characteristics":[{"aid":aid,"iid":iid,"value":value}]}).to_string();
                let (status, response) = encrypted_request(
                    &mut stream,
                    &mut session,
                    "PUT",
                    "/characteristics",
                    body.as_bytes(),
                );
                assert_eq!(
                    status,
                    204,
                    "{model}, repetition {repetition}, step {index}, request {value}, response {}, state {:?}, commands {:?}, requests {:?}",
                    String::from_utf8_lossy(&response),
                    engine.state("77").map(|s| (s.online, s.error, s.values)),
                    device.commands(),
                    device.requests()
                );
                let (_, body) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
                assert_eq!(
                    serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["value"],
                    value
                );
            }
            let commands = device.commands();
            assert_eq!(commands.len(), 3, "repeated Home writes must be idempotent");
            assert_eq!(commands[0]["method"], start_method);
            assert_eq!(commands[1]["method"], dock_method);
            assert_eq!(commands[2]["method"], dock_method);
            if start_method == "action" {
                assert_eq!(
                    commands[0]["params"],
                    json!({"did":"77","siid":2,"aiid":1,"in":[]})
                );
                assert_eq!(
                    commands[1]["params"],
                    json!({"did":"77","siid":3,"aiid":1,"in":[]})
                );
            } else {
                assert!(commands.iter().all(|r| r["params"] == json!([])));
            }
            device.state.store(255, Ordering::SeqCst);
            engine.refresh("77").unwrap();
            let (_, body) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
            // Unknown legacy states deliberately normalize to Idle, as in native.
            if start_method == "action" {
                assert_eq!(
                    serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["status"],
                    -70402
                );
            }
            assert!(bridge.info().paired);
            assert_eq!(bridge.info().uri, info.uri);
            bridge.stop();
        }
    }
}

fn pair_controller(
    stream: &mut TcpStream,
    code: &str,
    controller: &ControllerKeypair,
) -> hap_crypto::AccessoryPairing {
    let mut setup = PairSetupClient::new(code, controller.clone()).unwrap();
    let (_, m2) = request(stream, "POST", "/pair-setup", &setup.start());
    let m3 = send(setup.handle(&m2).unwrap());
    let (_, m4) = request(stream, "POST", "/pair-setup", &m3);
    let m5 = send(setup.handle(&m4).unwrap());
    let (_, m6) = request(stream, "POST", "/pair-setup", &m5);
    match setup.handle(&m6).unwrap() {
        PairSetupStep::Done(v) => v,
        _ => panic!(),
    }
}

#[cfg(target_os = "linux")]
#[test]
fn linux_service_reopens_a_paired_light_and_accepts_writes_with_the_old_controller() {
    use mijialan_core::{Device, Specification, Store, Token};

    let model = "yeelink.light.lamp4";
    let lamp = support::MiotDevice::with_spec(model, Specification::bundled(model).unwrap());
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("data");
    let keys = temp.path().join("keys");
    std::fs::create_dir(&keys).unwrap();
    let key = keys.join("master.key");
    let open = || {
        Arc::new(Engine::new(
            Arc::new(Store::open_service(root.clone(), &key).unwrap()),
            false,
        ))
    };
    let listen = (Ipv4Addr::LOCALHOST, 0).into();
    let controller = ControllerKeypair::from_seed("linux-controller".into(), [73; 32]);
    let (accessory, before, brightness) = {
        let engine = open();
        engine
            .import(
                Device {
                    did: "77".into(),
                    name: "Fixture Lamp".into(),
                    model: model.into(),
                    host: Ipv4Addr::LOCALHOST,
                    room: String::new(),
                    port: lamp.port,
                    bridged: true,
                },
                &Token::parse(support::TOKEN).unwrap(),
            )
            .unwrap();
        engine.refresh("77").unwrap();
        let bridge = HomeKit::new(engine);
        bridge.start_at(listen, false).unwrap();
        let before = bridge.info();
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, before.port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let accessory = pair_controller(&mut stream, &before.code, &controller);
        let mut session = verify(&mut stream, &controller, &accessory);
        let (_, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
        let db: Value = serde_json::from_slice(&body).unwrap();
        let light = &db["accessories"][1];
        let brightness = light["services"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|service| service["characteristics"].as_array().unwrap())
            .find(|characteristic| characteristic["type"] == "8")
            .unwrap();
        drop(stream);
        bridge.stop();
        (
            accessory,
            before,
            (light["aid"].clone(), brightness["iid"].clone()),
        )
    };

    let engine = open();
    engine.refresh("77").unwrap();
    let bridge = HomeKit::new(engine.clone());
    assert_eq!(bridge.saved_pairing().unwrap(), Some(true));
    bridge.start_at(listen, false).unwrap();
    let after = bridge.info();
    assert_eq!((after.port, after.uri), (before.port, before.uri));
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, after.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut session = verify(&mut stream, &controller, &accessory);
    let payload =
        json!({"characteristics": [{"aid": brightness.0, "iid": brightness.1, "value": 42}]})
            .to_string();
    let (status, _) = encrypted_request(
        &mut stream,
        &mut session,
        "PUT",
        "/characteristics",
        payload.as_bytes(),
    );
    assert_eq!(status, 204);
    assert_eq!(engine.refresh("77").unwrap().values["2.2"], 42);
    bridge.stop();
}

#[test]
fn bad_udp_readings_do_not_corrupt_the_encrypted_hap_database_or_events() {
    use mijialan_core::{Device, Store, Token};
    use std::sync::atomic::Ordering;
    let device = support::MiotDevice::start();
    let store = Arc::new(Store::memory());
    store
        .put(
            Device {
                did: "77".into(),
                name: "Fixture Purifier".into(),
                model: "zhimi.airpurifier.rma1".into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port: device.port,
                bridged: true,
            },
            &Token::parse(support::TOKEN).unwrap(),
        )
        .unwrap();
    let engine = Arc::new(Engine::new(store, false));
    assert!(engine.refresh("77").unwrap().online);
    let bridge = HomeKit::new(engine.clone());
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let info = bridge.info();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let controller = ControllerKeypair::from_seed("bad-readings-test".into(), [29; 32]);
    let accessory = pair_controller(&mut stream, &info.code, &controller);
    let mut session = verify(&mut stream, &controller, &accessory);
    let (_, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
    let good: Value = serde_json::from_slice(&body).unwrap();
    let purifier = &good["accessories"][1];
    let aid = purifier["aid"].as_u64().unwrap();
    let humidity = purifier["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["type"] == "82")
        .unwrap()["characteristics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == "10")
        .unwrap();
    assert_eq!(humidity["value"].as_f64(), Some(45.));
    let iid = humidity["iid"].as_u64().unwrap();
    device.phase.store(1, Ordering::SeqCst);
    assert_eq!(engine.refresh("77").unwrap().values["3.1"], 123);
    let (status, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
    assert_eq!(status, 200);
    let bad: Value = serde_json::from_slice(&body).unwrap();
    for service in bad["accessories"][1]["services"].as_array().unwrap() {
        for c in service["characteristics"].as_array().unwrap() {
            if ["B0", "A9", "10", "11"].iter().any(|t| c["type"] == *t) {
                assert!(c["value"].is_null(), "invalid source value leaked: {c}");
            }
        }
    }
    let path = format!("/characteristics?id={aid}.{iid}");
    let (status, body) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
    assert_eq!(status, 207);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["status"],
        -70402
    );
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":true}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["status"],
        -70402
    );
    device.phase.store(2, Ordering::SeqCst);
    engine.refresh("77").unwrap();
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["value"].as_f64(),
        Some(55.)
    );
    assert_eq!(device.writes.load(Ordering::SeqCst), 0);
    assert_eq!(bridge.info().uri, info.uri);
    assert!(bridge.info().paired);
    bridge.stop();
}

#[test]
fn a_controller_can_roll_back_pairing_and_retry_without_resetting_bridge_identity() {
    let bridge = HomeKit::new(Arc::new(Engine::demo()));
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let info = bridge.info();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let first = ControllerKeypair::from_seed("rollback-controller".into(), [30; 32]);
    let accessory = pair_controller(&mut stream, &info.code, &first);
    let mut session = verify(&mut stream, &first, &accessory);
    let body = crypto::tlv(&[(6, &[1]), (0, &[4]), (1, first.id.as_bytes())]);
    let (status, body) = encrypted_request(&mut stream, &mut session, "POST", "/pairings", &body);
    assert_eq!(status, 200);
    assert_eq!(crypto::parse(&body).unwrap()[&6], [2]);
    assert!(!bridge.info().paired);
    drop(stream);
    let mut retry = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    retry
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let second = ControllerKeypair::from_seed("retry-controller".into(), [31; 32]);
    let accessory = pair_controller(&mut retry, &info.code, &second);
    let mut session = verify(&mut retry, &second, &accessory);
    assert_eq!(
        encrypted_request(&mut retry, &mut session, "GET", "/accessories", &[]).0,
        200
    );
    assert!(bridge.info().paired);
    assert_eq!(bridge.info().uri, info.uri);
    bridge.stop();
}

fn send(step: PairSetupStep) -> Vec<u8> {
    match step {
        PairSetupStep::Send(v) => v,
        _ => panic!("expected outbound setup message"),
    }
}
#[test]
fn setup_and_verify_interoperate_with_independent_controller() {
    let controller = ControllerKeypair::from_seed("controller-test".into(), [9; 32]);
    let signing = SigningKey::from_bytes(&[7; 32]);
    let mut client = PairSetupClient::new("135-79-246", controller.clone()).unwrap();
    let _m1 = client.start();
    let (mut server, m2) = PairSetup::start("135-79-246").unwrap();
    let m3 = send(client.handle(&m2).unwrap());
    let m4 = server.prove(&m3).unwrap();
    let m5 = send(client.handle(&m4).unwrap());
    let (id, public, m6) = server.finish(&m5, "AA:BB:CC:DD:EE:01", &signing).unwrap();
    assert_eq!(id, controller.id);
    assert_eq!(public, controller.ltpk());
    let accessory = match client.handle(&m6).unwrap() {
        PairSetupStep::Done(v) => v,
        _ => panic!("expected completion"),
    };
    let mut verify = PairVerifyClient::new(&controller, &accessory);
    let m1 = verify.start();
    let (server, m2) = PairVerify::start(&m1, &accessory.pairing_id, &signing).unwrap();
    let m3 = match verify.handle(&m2).unwrap() {
        PairVerifyStep::Send(v) => v,
        _ => panic!("expected M3"),
    };
    let (id, signature) = server.controller(&m3).unwrap();
    let session = server.finish(&id, &public, &signature).unwrap();
    let keys = match verify.handle(&crypto::tlv(&[(6, &[4])])).unwrap() {
        PairVerifyStep::Done(v) => v,
        _ => panic!("expected session"),
    };
    assert_eq!(session.write_key, keys.read_key);
    assert_eq!(session.read_key, keys.write_key);
    let mut tampered = signature.clone();
    tampered[0] ^= 1;
    assert!(server.finish(&id, &public, &tampered).is_err());
    assert!(
        server
            .finish("wrong-controller", &public, &signature)
            .is_err()
    );
}
#[test]
fn wrong_setup_code_and_out_of_order_steps_are_rejected() {
    let controller = ControllerKeypair::from_seed("controller-test".into(), [9; 32]);
    let mut client = PairSetupClient::new("135-79-247", controller).unwrap();
    let _ = client.start();
    let (mut server, m2) = PairSetup::start("135-79-246").unwrap();
    let m3 = send(client.handle(&m2).unwrap());
    assert!(server.prove(&m3).is_err());
    assert!(
        server
            .finish(&[], "id", &SigningKey::from_bytes(&[7; 32]))
            .is_err()
    );
    assert!(crypto::parse(&[1, 5, 0]).is_err());
}
#[test]
fn encrypted_frames_enforce_1024_byte_limit_authentication_and_nonce_order() {
    let mut sender = Session {
        read_key: [1; 32],
        write_key: [2; 32],
        read_count: 0,
        write_count: 0,
    };
    let mut receiver = Session {
        read_key: [2; 32],
        write_key: [1; 32],
        read_count: 0,
        write_count: 0,
    };
    let plain = vec![42; 5500];
    let encoded = sender.encode(&plain).unwrap();
    let mut remaining = encoded.as_slice();
    let mut decoded = Vec::new();
    let mut frames = 0;
    while !remaining.is_empty() {
        let length = u16::from_le_bytes([remaining[0], remaining[1]]) as usize;
        assert!(length <= 1024);
        decoded.extend_from_slice(&receiver.decode_frame(&remaining[..length + 18]).unwrap());
        remaining = &remaining[length + 18..];
        frames += 1;
    }
    assert_eq!(decoded, plain);
    assert_eq!(frames, 6);
    assert!(receiver.decode_frame(&encoded[..1042]).is_err());
    let mut frame = sender.encode(b"next").unwrap();
    frame[3] ^= 1;
    assert!(receiver.decode_frame(&frame).is_err());
}
fn read_plain(stream: &mut TcpStream) -> (u16, Vec<u8>) {
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        let mut b = [0];
        stream.read_exact(&mut b).unwrap();
        header.push(b[0]);
        assert!(header.len() < 16384);
    }
    let text = String::from_utf8(header).unwrap();
    let status = text.split_whitespace().nth(1).unwrap().parse().unwrap();
    let length = text
        .lines()
        .find_map(|s| s.strip_prefix("Content-Length: "))
        .unwrap()
        .parse::<usize>()
        .unwrap();
    let mut body = vec![0; length];
    stream.read_exact(&mut body).unwrap();
    (status, body)
}
fn request(stream: &mut TcpStream, method: &str, path: &str, body: &[u8]) -> (u16, Vec<u8>) {
    let header = format!(
        "{method} {path} HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
        body.len()
    );
    stream.write_all(header.as_bytes()).unwrap();
    stream.write_all(body).unwrap();
    read_plain(stream)
}
fn encrypted_request(
    stream: &mut TcpStream,
    session: &mut Session,
    method: &str,
    path: &str,
    body: &[u8],
) -> (u16, Vec<u8>) {
    let mut plain = format!(
        "{method} {path} HTTP/1.1\r\nContent-Length: {}\r\n\r\n",
        body.len()
    )
    .into_bytes();
    plain.extend_from_slice(body);
    stream.write_all(&session.encode(&plain).unwrap()).unwrap();
    read_encrypted(stream, session)
}
fn read_encrypted(stream: &mut TcpStream, session: &mut Session) -> (u16, Vec<u8>) {
    let mut plain = Vec::new();
    loop {
        let mut length = [0; 2];
        stream.read_exact(&mut length).unwrap();
        let mut frame = vec![0; u16::from_le_bytes(length) as usize + 18];
        frame[..2].copy_from_slice(&length);
        stream.read_exact(&mut frame[2..]).unwrap();
        plain.extend_from_slice(&session.decode_frame(&frame).unwrap());
        if let Some(offset) = plain.windows(4).position(|s| s == b"\r\n\r\n") {
            let text = std::str::from_utf8(&plain[..offset]).unwrap();
            let length = text
                .lines()
                .find_map(|s| s.strip_prefix("Content-Length: "))
                .unwrap()
                .parse::<usize>()
                .unwrap();
            if plain.len() >= offset + 4 + length {
                return (
                    text.split_whitespace().nth(1).unwrap().parse().unwrap(),
                    plain[offset + 4..offset + 4 + length].to_vec(),
                );
            }
        }
    }
}
fn verify(
    stream: &mut TcpStream,
    controller: &ControllerKeypair,
    accessory: &hap_crypto::AccessoryPairing,
) -> Session {
    let mut client = PairVerifyClient::new(controller, accessory);
    let (_, m2) = request(stream, "POST", "/pair-verify", &client.start());
    let m3 = match client.handle(&m2).unwrap() {
        PairVerifyStep::Send(v) => v,
        _ => panic!(),
    };
    let (_, m4) = request(stream, "POST", "/pair-verify", &m3);
    let keys = match client.handle(&m4).unwrap() {
        PairVerifyStep::Done(v) => v,
        _ => panic!(),
    };
    Session {
        read_key: keys.read_key,
        write_key: keys.write_key,
        read_count: 0,
        write_count: 0,
    }
}
#[test]
fn real_tcp_pairing_multi_frame_database_writes_events_and_admin_permissions() {
    let engine = Arc::new(Engine::demo());
    let bridge = HomeKit::new(engine.clone());
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let info = bridge.info();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    assert_eq!(request(&mut stream, "GET", "/accessories", &[]).0, 470);
    let controller = ControllerKeypair::from_seed("administrator".into(), [11; 32]);
    let mut setup = PairSetupClient::new(&info.code, controller.clone()).unwrap();
    let (_, m2) = request(&mut stream, "POST", "/pair-setup", &setup.start());
    let m3 = send(setup.handle(&m2).unwrap());
    let (_, m4) = request(&mut stream, "POST", "/pair-setup", &m3);
    let m5 = send(setup.handle(&m4).unwrap());
    let (_, m6) = request(&mut stream, "POST", "/pair-setup", &m5);
    let accessory = match setup.handle(&m6).unwrap() {
        PairSetupStep::Done(v) => v,
        _ => panic!(),
    };
    assert!(bridge.info().paired);
    let mut session = verify(&mut stream, &controller, &accessory);
    let (status, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
    assert_eq!(status, 200);
    assert!(body.len() > 1024);
    let database: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(database["accessories"].as_array().unwrap().len(), 5);
    let lamp = database["accessories"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| {
            a["services"][0]["characteristics"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["type"] == "21" && c["value"] == "yeelink.light.lamp4")
        })
        .unwrap();
    let aid = lamp["aid"].as_u64().unwrap();
    let iid = lamp["services"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|s| s["characteristics"].as_array().unwrap())
        .find(|c| c["type"] == "25")
        .unwrap()["iid"]
        .as_u64()
        .unwrap();
    for (kind, key, invalid) in [("8", "2.2", json!(2.5)), ("CE", "2.3", json!(10000))] {
        let attribute = lamp["services"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|s| s["characteristics"].as_array().unwrap())
            .find(|c| c["type"] == kind)
            .unwrap();
        let before = engine.state("1").unwrap().values[key].clone();
        let body = json!({"characteristics":[{"aid":aid,"iid":attribute["iid"],"value":invalid}]})
            .to_string();
        let (status, body) = encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes(),
        );
        assert_eq!(status, 207);
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["status"],
            -70410
        );
        assert_eq!(
            engine.state("1").unwrap().values[key],
            before,
            "invalid HAP input reached device conversion"
        );
    }
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"value":false}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    assert_eq!(engine.state("1").unwrap().values["2.1"], false);
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":true}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let (_, event) = read_encrypted(&mut stream, &mut session);
    let event: Value = serde_json::from_slice(&event).unwrap();
    assert_eq!(event["characteristics"][0]["value"], false);
    engine.write("1", "2.1", json!(true)).unwrap();
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["value"],
        true
    );
    // A controller must receive the authoritative value even if the successful
    // command leaves it unchanged (as with momentary presets and actions).
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"value":true}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["value"],
        true
    );
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":false}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let user = ControllerKeypair::from_seed("ordinary-user".into(), [12; 32]);
    let body = crypto::tlv(&[
        (6, &[1]),
        (0, &[3]),
        (1, user.id.as_bytes()),
        (3, &user.ltpk()),
        (11, &[0]),
    ]);
    assert_eq!(
        encrypted_request(&mut stream, &mut session, "POST", "/pairings", &body).0,
        200
    );
    let mut user_stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    user_stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let mut user_session = verify(&mut user_stream, &user, &accessory);
    let (_, body) = encrypted_request(
        &mut user_stream,
        &mut user_session,
        "POST",
        "/pairings",
        &crypto::tlv(&[(6, &[1]), (0, &[5])]),
    );
    assert_eq!(crypto::parse(&body).unwrap()[&7], [2]);
    bridge.stop();
    drop(stream);
    drop(user_stream);
    assert!(!bridge.info().running);
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    assert_eq!(bridge.info().port, info.port);
    assert!(bridge.info().paired);
    let old_uri = bridge.info().uri;
    bridge.stop();
    bridge.reset_pairing().unwrap();
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    assert!(!bridge.info().paired);
    assert_ne!(bridge.info().uri, old_uri);
    bridge.stop();
}

#[test]
fn real_tcp_configured_name_notifications_and_utf8_byte_limit() {
    let engine = Arc::new(Engine::demo());
    let bridge = HomeKit::new(engine.clone());
    bridge
        .start_at((Ipv4Addr::LOCALHOST, 0).into(), false)
        .unwrap();
    let info = bridge.info();
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, info.port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let controller = ControllerKeypair::from_seed("name-controller".into(), [27; 32]);
    let mut setup = PairSetupClient::new(&info.code, controller.clone()).unwrap();
    let (_, m2) = request(&mut stream, "POST", "/pair-setup", &setup.start());
    let m3 = send(setup.handle(&m2).unwrap());
    let (_, m4) = request(&mut stream, "POST", "/pair-setup", &m3);
    let m5 = send(setup.handle(&m4).unwrap());
    let (_, m6) = request(&mut stream, "POST", "/pair-setup", &m5);
    let accessory = match setup.handle(&m6).unwrap() {
        PairSetupStep::Done(v) => v,
        _ => panic!(),
    };
    let mut session = verify(&mut stream, &controller, &accessory);
    let (status, body) = encrypted_request(&mut stream, &mut session, "GET", "/accessories", &[]);
    assert_eq!(status, 200);
    let database: Value = serde_json::from_slice(&body).unwrap();
    let accessories = database["accessories"].as_array().unwrap();
    let protocol = accessories.iter().find(|a| a["aid"] == 1).unwrap()["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["type"] == "A2")
        .unwrap();
    assert!(
        protocol["characteristics"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["type"] == "37" && c["value"] == "1.1.0")
    );
    let lamp = accessories
        .iter()
        .find(|a| {
            a["services"][0]["characteristics"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["type"] == "21" && c["value"] == "yeelink.light.lamp4")
        })
        .unwrap();
    let aid = lamp["aid"].as_u64().unwrap();
    let configured = lamp["services"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|s| s["characteristics"].as_array().unwrap())
        .find(|c| c["type"] == "E3")
        .unwrap();
    let iid = configured["iid"].as_u64().unwrap();
    assert!(
        configured["perms"]
            .as_array()
            .unwrap()
            .iter()
            .any(|p| p == "ev")
    );
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":true}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["value"],
        configured["value"]
    );

    // 22 Chinese characters occupy 66 UTF-8 bytes, despite being <64 characters.
    let body =
        json!({"characteristics":[{"aid":aid,"iid":iid,"value":"灯".repeat(22)}]}).to_string();
    let (status, body) = encrypted_request(
        &mut stream,
        &mut session,
        "PUT",
        "/characteristics",
        body.as_bytes(),
    );
    assert_eq!(status, 207);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["status"],
        -70410
    );

    let valid = format!("{}a", "灯".repeat(21));
    assert_eq!(valid.len(), 64);
    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"value":valid}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let (_, event) = read_encrypted(&mut stream, &mut session);
    assert_eq!(
        serde_json::from_slice::<Value>(&event).unwrap()["characteristics"][0]["value"],
        valid
    );
    let path = format!("/characteristics?id={aid}.{iid}");
    let (status, body) = encrypted_request(&mut stream, &mut session, "GET", &path, &[]);
    assert_eq!(status, 200);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["value"],
        valid
    );

    let body = json!({"characteristics":[{"aid":aid,"iid":iid,"ev":false}]}).to_string();
    assert_eq!(
        encrypted_request(
            &mut stream,
            &mut session,
            "PUT",
            "/characteristics",
            body.as_bytes()
        )
        .0,
        204
    );
    let name = lamp["services"][0]["characteristics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == "23")
        .unwrap()["iid"]
        .as_u64()
        .unwrap();
    let body = json!({"characteristics":[{"aid":aid,"iid":name,"ev":true}]}).to_string();
    let (status, body) = encrypted_request(
        &mut stream,
        &mut session,
        "PUT",
        "/characteristics",
        body.as_bytes(),
    );
    assert_eq!(status, 207);
    assert_eq!(
        serde_json::from_slice::<Value>(&body).unwrap()["characteristics"][0]["status"],
        -70406
    );
    assert!(bridge.info().paired);
    assert_eq!(bridge.info().uri, info.uri);
    bridge.stop();
}
