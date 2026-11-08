use mijialan_core::{Device, Engine, Specification, Store, Token};
use mijialan_homekit::{
    HomeKit,
    diagnostics::{self, ApplicationInfo},
    mapping::{self, Database, Layout, Transform},
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, net::Ipv4Addr, sync::Arc, time::SystemTime};

#[allow(dead_code)] // Other suites use the fixture's live phase and write counters.
mod support;

const AIRER: &str = include_str!("../../core/tests/fixtures/xiaomi-airer-0002.json");
const FAN: &str = include_str!("../../core/tests/fixtures/dmaker-p220.json");
const BED: &str = include_str!("../../core/tests/fixtures/satori-sd01.json");

fn engine(model: &str, document: &str, port: u16) -> Engine {
    let store = Arc::new(Store::memory());
    store.cache_spec(model, document).unwrap();
    store
        .put(
            Device {
                did: "77".into(),
                name: "Fixture".into(),
                model: model.into(),
                host: Ipv4Addr::LOCALHOST,
                room: String::new(),
                port,
                bridged: true,
            },
            &Token::parse(support::TOKEN).unwrap(),
        )
        .unwrap();
    Engine::new(store, false)
}

fn fixture(
    model: &str,
    document: &str,
    readings: impl IntoIterator<Item = (&'static str, Value)>,
) -> (Engine, support::MiotDevice) {
    let server = support::MiotDevice::with_readings(
        model,
        document,
        readings
            .into_iter()
            .map(|(k, v)| (k.to_owned(), v))
            .collect(),
    );
    let engine = engine(model, document, server.port);
    engine.refresh("77").unwrap();
    (engine, server)
}

fn characteristic(db: &Database, key: &str, kind: &str) -> (u64, u64) {
    db.bindings
        .iter()
        .find_map(|(&(aid, iid), binding)| {
            (binding.key == key && db.attribute(aid, iid).unwrap()["type"] == kind)
                .then_some((aid, iid))
        })
        .unwrap_or_else(|| panic!("missing characteristic {key} ({kind})"))
}

#[test]
fn write_only_motor_control_reads_off_and_only_on_sends_a_command() {
    let (engine, server) = fixture("test.airer.0002", AIRER, []);
    let state = engine.state("77").unwrap();
    let property = state
        .spec
        .properties
        .iter()
        .find(|p| p.key() == "2.5")
        .unwrap();
    assert!(!property.readable && !state.values.contains_key("2.5"));
    let db = mapping::build(&engine, &mut Layout::default());
    let (aid, iid) = characteristic(&db, "2.5", "25");
    assert_eq!(db.read(&engine, aid, iid, false), Ok(json!(false)));
    let binding = &db.bindings[&(aid, iid)];
    binding.write(&engine, &json!(false)).unwrap();
    assert!(server.commands.lock().unwrap().is_empty());
    binding.write(&engine, &json!(true)).unwrap();
    let commands = server.commands.lock().unwrap();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0]["params"][0]["piid"], 5);
    assert_eq!(commands[0]["params"][0]["value"], property.choices[0].value);
    assert_eq!(db.read(&engine, aid, iid, false), Ok(json!(false)));
}

#[test]
fn light_brightness_powers_on_first_and_zero_preserves_the_level() {
    let source = Specification::bundled("yeelink.light.lamp4").unwrap();
    for (maximum, raw, percent) in [(255, 128, 50), (65535, 32768, 50), (100, 40, 40)] {
        let mut spec: Value = serde_json::from_str(source).unwrap();
        let light = spec["services"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|service| service["iid"] == 2)
            .unwrap();
        let brightness = light["properties"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|property| property["iid"] == 2)
            .unwrap();
        brightness["value-range"] = json!([1, maximum, 1]);
        if maximum == 65535 {
            brightness["format"] = json!("uint16");
        }
        let (engine, server) = fixture(
            "test.light.scaled",
            &spec.to_string(),
            [("2.1", json!(false)), ("2.2", json!(raw))],
        );
        let db = mapping::build(&engine, &mut Layout::default());
        let (aid, iid) = characteristic(&db, "2.2", "8");
        assert_eq!(db.read(&engine, aid, iid, false), Ok(json!(percent)));
        let binding = &db.bindings[&(aid, iid)];
        binding.write(&engine, &json!(100)).unwrap();
        assert_eq!(db.read(&engine, aid, iid, false), Ok(json!(100)));
        binding.write(&engine, &json!(0)).unwrap();
        let commands = server.commands.lock().unwrap();
        assert_eq!(commands.len(), 3);
        assert_eq!(commands[0]["params"][0]["piid"], 1);
        assert_eq!(commands[0]["params"][0]["value"], true);
        assert_eq!(commands[1]["params"][0]["piid"], 2);
        assert_eq!(commands[1]["params"][0]["value"], maximum);
        assert_eq!(commands[2]["params"][0]["piid"], 1);
        assert_eq!(commands[2]["params"][0]["value"], false);
        assert_eq!(engine.state("77").unwrap().values["2.2"], maximum);
    }
}

#[test]
fn firmware_modes_remain_visible_without_enabling_a_home_mode_switch() {
    for (reported, expected) in [
        (json!(9), Ok(json!(false))),
        (json!("invalid"), Err(-70402)),
    ] {
        let (engine, server) = fixture("test.fan.p220", FAN, [("2.3", reported.clone())]);
        let state = engine.state("77").unwrap();
        assert_eq!(state.values["2.3"], reported);
        let db = mapping::build(&engine, &mut Layout::default());
        let modes: Vec<_> = db
            .bindings
            .iter()
            .filter(|((aid, iid), binding)| {
                binding.key == "2.3" && db.attribute(*aid, *iid).unwrap()["type"] == "25"
            })
            .collect();
        assert!(!modes.is_empty());
        for (&(aid, iid), _) in modes {
            assert_eq!(db.read(&engine, aid, iid, false), expected);
        }
        assert!(engine.write("77", "2.3", json!(9)).is_err());
        assert!(server.commands.lock().unwrap().is_empty());
    }

    let doc = Specification::bundled("lumi.acpartner.mcn02").unwrap();
    for (mode, target, current) in [
        (1, Ok(json!(2)), Ok(json!(3))),
        (2, Ok(json!(0)), Ok(json!(1))),
        (7, Err(-70402), Err(-70402)),
    ] {
        let (engine, _) = fixture("test.air-conditioner", doc, [("2.2", json!(mode))]);
        let db = mapping::build(&engine, &mut Layout::default());
        let (aid, iid) = characteristic(&db, "2.2", "B2");
        assert_eq!(db.read(&engine, aid, iid, false), target);
        let (aid, iid) = characteristic(&db, "2.1", "B1");
        assert_eq!(db.read(&engine, aid, iid, false), current);
    }
}

#[test]
fn purifier_uses_motor_speed_when_present_and_power_when_absent() {
    let source = Specification::bundled("zhimi.airpurifier.rma1").unwrap();
    for (rpm, expected) in [
        (None, Ok(json!(2))),
        (Some(json!(0)), Ok(json!(1))),
        (Some(json!(500)), Ok(json!(2))),
        (Some(Value::Null), Err(-70402)),
    ] {
        let mut spec: Value = serde_json::from_str(source).unwrap();
        if rpm.is_none() {
            for service in spec["services"].as_array_mut().unwrap() {
                if let Some(properties) = service["properties"].as_array_mut() {
                    properties
                        .retain(|p| !p["type"].as_str().unwrap().contains(":moto-speed-rpm:"));
                }
            }
        }
        let readings: BTreeMap<_, _> = rpm.map(|rpm| ("9.1", rpm)).into_iter().collect();
        let (engine, _) = fixture("test.purifier", &spec.to_string(), readings);
        let db = mapping::build(&engine, &mut Layout::default());
        let (aid, iid) = characteristic(&db, "2.1", "A9");
        assert_eq!(db.read(&engine, aid, iid, false), expected);
    }
}

#[test]
fn bed_presets_and_bridge_support_follow_the_actual_mapped_services() {
    let (bed, server) = fixture("test.bed.sd01", BED, [("2.2", json!(6))]);
    assert!(mapping::maps_to_home(&bed.state("77").unwrap()));
    let db = mapping::build(&bed, &mut Layout::default());
    assert_eq!(db.accessories.len(), 2);
    assert_eq!(db.bindings.len(), 6);
    for (&(aid, iid), binding) in &db.bindings {
        assert_eq!(binding.key, "2.2");
        assert_eq!(db.read(&bed, aid, iid, false), Ok(json!(false)));
    }
    let flat = db
        .bindings
        .values()
        .find(
            |binding| matches!(&binding.transform, Transform::Option(value) if value == &json!(4)),
        )
        .unwrap();
    flat.write(&bed, &json!(true)).unwrap();
    let commands = server.commands.lock().unwrap();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0]["params"][0]["piid"], 2);
    assert_eq!(commands[0]["params"][0]["value"], 4);
    drop(commands);
    bed.set_bridged("77", false).unwrap();
    assert!(mapping::maps_to_home(&bed.state("77").unwrap()));
    assert_eq!(
        mapping::build(&bed, &mut Layout::default())
            .accessories
            .len(),
        1
    );

    let mut vendor_only: Value = serde_json::from_str(BED).unwrap();
    vendor_only["services"]
        .as_array_mut()
        .unwrap()
        .retain(|service| service["iid"] != 2);
    let engine = Arc::new(engine(
        "test.bed.vendor-only",
        &vendor_only.to_string(),
        54321,
    ));
    let state = engine.state("77").unwrap();
    assert!(state.spec.properties.iter().any(|p| p.writable));
    assert!(!mapping::maps_to_home(&state));
    assert_eq!(
        mapping::build(&engine, &mut Layout::default())
            .accessories
            .len(),
        1
    );
    let bridge = HomeKit::new(engine.clone());
    let report = diagnostics::report(
        &engine,
        &bridge,
        &ApplicationInfo::default(),
        SystemTime::UNIX_EPOCH,
    );
    assert_eq!(report["devices"][0]["homeKitSupported"], false);
    assert_eq!(report["devices"][0]["homeIncluded"], true);
}
