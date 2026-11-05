//! Regression cases ported from native a56d52f / 30a731c; loopback and memory only.
use mijialan_core::{
    Device, Engine, MiioClient, Specification, Store, Token, client::parse_json, engine::numeric,
    naming, packet,
};
use serde_json::{Value, json};
use std::{
    net::{Ipv4Addr, UdpSocket},
    sync::{Arc, mpsc},
    time::{Duration, Instant},
};
const TOKEN: &str = "00112233445566778899aabbccddeeff";

#[test]
fn spec_comments_keep_the_name_without_explanations_or_placeholder_text() {
    for (input, expected) in [
        ("加热档位\n0-关\n1-小\n2-中", "加热档位"),
        ("夜灯App设置开关（用于智能夜灯设置）", "夜灯App设置开关"),
        ("电机反向 【 0: 正向（默认） 1: 反向】", "电机反向"),
        (
            "龙头默认模式开关；0：亮屏显示息屏前模式",
            "龙头默认模式开关",
        ),
        ("获取日志数据；", "获取日志数据"),
        (
            "开启时长;关闭时长;日期;开始时间",
            "开启时长;关闭时长;日期;开始时间",
        ),
        (
            "重置设备标志0云端待重置1设备待重置2云端设备都已重置",
            "重置设备标志",
        ),
        ("按摩力度1挡", "按摩力度1挡"),
        ("地图类型 0:实时图 1:指哪图", "地图类型"),
        (
            "AI 识别开关 AI 识别开关关闭：脏污识别开关自动关闭",
            "AI 识别开关",
        ),
        ("30%湿度", "30%湿度"),
    ] {
        assert_eq!(naming::comment(input).as_deref(), Some(expected));
    }
    for input in ["null", " NULL ", "  ", ""] {
        assert_eq!(naming::comment(input), None);
    }
}
fn p(iid: u32, name: &str, comment: Option<&str>) -> Value {
    let mut p = json!({"iid":iid,"type":format!("urn:miot-spec-v2:property:{name}:00000001:test:1"),"description":name,"format":"bool","access":["read","write"]});
    if let Some(comment) = comment {
        p["comment"] = json!(comment);
    }
    p
}
fn service(iid: u32, name: &str, description: &str, props: Vec<Value>) -> Value {
    json!({"iid":iid,"type":format!("urn:miot-spec-v2:service:{name}:00007801:test:1"),"description":description,"properties":props})
}
#[test]
fn duplicate_controls_take_specific_comments_then_their_service_then_a_number() {
    let doc = json!({"type":"urn:miot-spec-v2:device:switch:0000A003:test:1","services":[
        service(2,"switch","Left Switch Service",vec![p(1,"on",Some("左键")),p(2,"mode",Some("模式"))]),
        service(3,"switch","Right Switch Service",vec![p(1,"on",Some("右键")),p(2,"mode",Some("模式"))]),
        service(4,"switch-sensor","Left Switch Sensor",vec![p(1,"mode",Some("模式"))]),
        service(5,"light","Light",vec![p(1,"on",Some("开关"))]),
        service(6,"fridge-chamber","Refrigerating Chamber",vec![p(1,"on",None),p(2,"mode",Some("速冷模式")),p(3,"temperature",Some("温度"))]),
        service(7,"fridge-chamber","Freezing Chamber",vec![p(1,"on",Some("开关")),p(2,"mode",Some("速冻模式")),p(3,"temperature",Some("温度"))]),
        service(8,"filter","Filter",vec![p(1,"filter-life-level",Some("滤芯剩余寿命"))]),
        service(9,"filter","Filter",vec![p(1,"filter-life-level",Some("滤芯剩余寿命"))]),
        service(10,"filter","Fresh Air Filter",vec![p(1,"filter-life-level",Some("滤芯剩余寿命"))])
    ]});
    let spec = Specification::parse(&doc.to_string()).unwrap();
    for (key, expected) in [
        ("2.1", "左键"),
        ("3.1", "右键"),
        ("2.2", "左键模式"),
        ("3.2", "右键模式"),
        ("4.1", "左键按键模式"),
        ("5.1", "照明"),
        ("6.1", "冷藏室"),
        ("6.2", "速冷模式"),
        ("6.3", "冷藏室温度"),
        ("7.3", "冷冻室温度"),
        ("8.1", "滤芯寿命"),
        ("9.1", "滤芯寿命 2"),
        ("10.1", "新风滤芯寿命"),
    ] {
        assert_eq!(
            spec.properties
                .iter()
                .find(|p| p.key() == key)
                .unwrap()
                .title
                .as_ref()
                .unwrap()
                .zh,
            expected,
            "{key}"
        );
    }
    for english in [false, true] {
        let labels: Vec<_> = spec
            .properties
            .iter()
            .map(|p| p.title.as_ref().unwrap().get(english))
            .collect();
        assert_eq!(
            labels
                .iter()
                .collect::<std::collections::BTreeSet<_>>()
                .len(),
            labels.len()
        );
        if english {
            assert!(
                !labels
                    .iter()
                    .any(|s| s.chars().any(|c| ('\u{4e00}'..='\u{9fff}').contains(&c)))
            );
        }
    }
}
#[test]
fn option_details_remain_when_they_distinguish_values_and_null_uses_its_description() {
    let mut status = p(1, "status", Some("状态"));
    status["format"] = json!("uint8");
    status["value-list"] = json!([
        {"value":0,"description":"Idle","comment":"待机"},{"value":1,"description":"Charging","comment":"充电中"},
        {"value":2,"description":"Charging Breakpoint","comment":"充电中(断点中)"},{"value":3,"description":"Pause","comment":"null"},
        {"value":4,"description":"Error","comment":"故障（E1，见说明书）"}
    ]);
    let doc = json!({"type":"urn:miot-spec-v2:device:switch:1:test:1","services":[service(2,"switch","Switch",vec![status])]});
    let spec = Specification::parse(&doc.to_string()).unwrap();
    assert_eq!(
        spec.properties[0]
            .choices
            .iter()
            .map(|c| c.label(false))
            .collect::<Vec<_>>(),
        ["待机", "充电中", "充电中(断点中)", "暂停", "故障"]
    );
}

#[test]
fn native_wall_switch_and_airer_specs_keep_distinct_channel_and_light_names() {
    let switch = Specification::for_model(
        "xiaomi.switch.2b2",
        include_str!("fixtures/xiaomi-2b2.json"),
    )
    .unwrap();
    for (key, zh) in [("2.1", "左键"), ("3.1", "右键")] {
        assert_eq!(
            switch
                .properties
                .iter()
                .find(|p| p.key() == key)
                .unwrap()
                .title
                .as_ref()
                .unwrap()
                .zh,
            zh
        );
    }
    let airer = Specification::for_model(
        "xiaomi.airer.0002",
        include_str!("fixtures/xiaomi-airer-0002.json"),
    )
    .unwrap();
    assert!(
        airer.primary_power().is_none(),
        "a secondary light is not the device's main power switch"
    );
    assert_eq!(
        airer
            .properties
            .iter()
            .find(|p| p.service == "light" && p.name == "on")
            .unwrap()
            .title
            .as_ref()
            .unwrap()
            .zh,
        "照明"
    );
    for spec in [switch, airer] {
        for english in [false, true] {
            let names: Vec<_> = spec
                .properties
                .iter()
                .map(|p| p.title.as_ref().unwrap().get(english))
                .collect();
            assert_eq!(
                names
                    .iter()
                    .collect::<std::collections::BTreeSet<_>>()
                    .len(),
                names.len()
            );
        }
    }
}
#[test]
fn numeric_conversions_and_property_validation_reject_nonfinite_or_oversized_values() {
    for value in [
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
        1e300,
        9223372036854775808.,
    ] {
        assert!(numeric(value, "uint32").is_null());
    }
    let transform = json!({"kind":"number","ratio":1});
    for value in [json!("nan"), json!("inf"), json!("-inf")] {
        assert!(mijialan_core::legacy::read_transform(&transform, &value, "float").is_none());
    }
    assert_eq!(
        mijialan_core::legacy::read_transform(&transform, &json!(1e300), "float"),
        Some(json!(1e300))
    );
    let transform = json!({"kind":"integer","method":"set_value","ratio":1});
    assert!(mijialan_core::legacy::write_transform(&transform, &json!(1e300)).is_none());
    let spec = Specification::for_model(
        "yeelink.light.lamp4",
        Specification::bundled("yeelink.light.lamp4").unwrap(),
    )
    .unwrap();
    let mut brightness = spec
        .properties
        .iter()
        .find(|p| p.name == "brightness")
        .unwrap()
        .clone();
    for range in [
        [100., 1., 1.],
        [0., 100., 0.],
        [0., f64::INFINITY, 1.],
        [0., 100., f64::NAN],
    ] {
        brightness.range = Some(range);
        assert!(brightness.validate(&json!(50)).is_err());
    }
}

/// One actual miIO exchange; the optional gate holds only this device's property response.
fn endpoint(
    result: Value,
    gate: Option<(mpsc::Sender<()>, mpsc::Receiver<()>)>,
) -> (u16, std::thread::JoinHandle<()>) {
    endpoints(vec![result], gate)
}
fn endpoints(
    results: Vec<Value>,
    mut gate: Option<(mpsc::Sender<()>, mpsc::Receiver<()>)>,
) -> (u16, std::thread::JoinHandle<()>) {
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let port = socket.local_addr().unwrap().port();
    let thread = std::thread::spawn(move || {
        let token = Token::parse(TOKEN).unwrap();
        let mut data = [0; 65535];
        let mut results = results.into_iter().peekable();
        loop {
            let (len, from) = socket.recv_from(&mut data).unwrap();
            if data[..len] == packet::HELLO {
                let mut hello = vec![0x21, 0x31, 0, 32, 0, 0, 0, 0];
                hello.extend_from_slice(&77u32.to_be_bytes());
                hello.extend_from_slice(&900000u32.to_be_bytes());
                hello.extend_from_slice(&[0; 16]);
                socket.send_to(&hello, from).unwrap();
                continue;
            }
            let (_, plain) = packet::decode(&data[..len], &token).unwrap();
            let request = parse_json(&plain).unwrap();
            if let Some((entered, release)) = gate.take() {
                let _ = entered.send(());
                let _ = release.recv_timeout(Duration::from_secs(5));
            }
            let result = results.next().expect("scripted property result");
            let body = json!({"id":request["id"],"result":result}).to_string();
            socket
                .send_to(
                    &packet::encode(body.as_bytes(), &token, 77, 900001).unwrap(),
                    from,
                )
                .unwrap();
            if results.peek().is_none() {
                break;
            }
        }
    });
    (port, thread)
}
const SPEC: &str = r#"{"type":"urn:miot-spec-v2:device:light:1:test:1","services":[{"iid":2,"type":"urn:miot-spec-v2:service:light:1:test:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:1:test:1","format":"bool","access":["read","write"]}]}]}"#;
fn store_device(store: &Store, did: &str, port: u16) {
    store.cache_spec("test.light.poll", SPEC).unwrap();
    store
        .put(
            Device {
                did: did.into(),
                name: did.into(),
                model: "test.light.poll".into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port,
                bridged: true,
            },
            &Token::parse(TOKEN).unwrap(),
        )
        .unwrap();
}
#[test]
fn a_fast_poll_publishes_while_another_device_is_still_blocked() {
    let result = json!([{"siid":2,"piid":1,"code":0,"value":true}]);
    let (entered, waiting) = mpsc::channel();
    let (release, gate) = mpsc::channel();
    let (slow, slow_thread) = endpoint(result.clone(), Some((entered, gate)));
    let (fast, fast_thread) = endpoint(result, None);
    let store = Arc::new(Store::memory());
    store_device(&store, "slow", slow);
    store_device(&store, "fast", fast);
    let engine = Arc::new(Engine::new(store, false));
    let poller = engine.start_polling();
    waiting.recv_timeout(Duration::from_secs(2)).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !engine.state("fast").unwrap().online && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let fast_online = engine.state("fast").unwrap().online;
    let slow_revision = engine.state("slow").unwrap().revision;
    drop(poller);
    let _ = release.send(());
    slow_thread.join().unwrap();
    fast_thread.join().unwrap();
    assert!(fast_online, "fast device waited for the blocked poll");
    assert_eq!(
        slow_revision, 0,
        "slow gate must still be blocking when fast publishes"
    );
}

#[test]
fn a_completed_read_does_not_restore_a_device_removed_while_it_was_pending() {
    let (entered, waiting) = mpsc::channel();
    let (release, gate) = mpsc::channel();
    let (port, server) = endpoint(
        json!([{"siid":2,"piid":1,"code":0,"value":true}]),
        Some((entered, gate)),
    );
    let store = Arc::new(Store::memory());
    store_device(&store, "77", port);
    let engine = Arc::new(Engine::new(store, false));
    let worker = engine.clone();
    let read = std::thread::spawn(move || worker.refresh("77"));
    waiting.recv_timeout(Duration::from_secs(2)).unwrap();
    engine.remove("77").unwrap();
    release.send(()).unwrap();
    assert!(read.join().unwrap().is_err());
    server.join().unwrap();
    assert!(engine.state("77").is_none());
    assert!(engine.store.config().devices.is_empty());
}
#[test]
fn oversized_result_codes_and_wrapped_property_ids_cannot_be_accepted() {
    for code in [json!(1e300), json!(u64::MAX), json!("0"), Value::Null] {
        let (port, thread) = endpoint(json!([{"siid":2,"piid":1,"code":code}]), None);
        let mut client =
            MiioClient::with_port(Ipv4Addr::LOCALHOST, port, Token::parse(TOKEN).unwrap());
        assert!(client.set_property("77", 2, 1, json!(true)).is_err());
        thread.join().unwrap();
    }
    let (port, thread) = endpoint(
        json!([{"siid":4294967298_u64,"piid":1,"code":0,"value":true}]),
        None,
    );
    let store = Arc::new(Store::memory());
    store_device(&store, "77", port);
    let engine = Engine::new(store, false);
    assert!(engine.refresh("77").is_err());
    assert!(!engine.state("77").unwrap().online);
    thread.join().unwrap();
}

#[test]
fn rediscovery_at_the_same_ip_retries_an_offline_device_without_waiting_for_backoff() {
    let (port, thread) = endpoints(
        vec![
            json!([{"siid":2,"piid":1,"code":-4004}]),
            json!([{"siid":2,"piid":1,"code":0,"value":true}]),
        ],
        None,
    );
    let store = Arc::new(Store::memory());
    store_device(&store, "77", port);
    let engine = Arc::new(Engine::new(store, false));
    let poller = engine.start_polling();
    let deadline = Instant::now() + Duration::from_secs(2);
    while engine.state("77").unwrap().revision == 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!engine.state("77").unwrap().online);
    engine
        .update_discovered_hosts(&[mijialan_core::discovery::DiscoveredDevice {
            host: Ipv4Addr::LOCALHOST,
            device_id: 77,
        }])
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    while !engine.state("77").unwrap().online && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
    }
    let recovered = engine.state("77").unwrap().online;
    drop(poller);
    assert!(
        recovered,
        "discovery left the device waiting for its 30-second retry"
    );
    thread.join().unwrap();
}
