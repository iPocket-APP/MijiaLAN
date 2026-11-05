//! Expected native 0.1.4 behavior, using the same manufacturer specifications.
use super::*;

fn binding<'a>(db: &'a Database, service: &str, kind: &str) -> &'a Binding {
    let aid = db.accessories[1]["aid"].as_u64().unwrap();
    let iid = characteristic(db, service, kind)["iid"].as_u64().unwrap();
    db.bindings.get(&(aid, iid)).unwrap()
}
fn plan(b: &Binding, state: &DeviceState, value: Value) -> Vec<(String, Value)> {
    let p = state
        .spec
        .properties
        .iter()
        .find(|p| p.key() == b.key)
        .unwrap();
    controls::writes(&b.transform, p, state, &value)
        .unwrap()
        .unwrap()
}
#[test]
fn percentage_fan_speed_replaces_gears_and_zero_only_turns_power_off() {
    for (model, document) in [
        (
            "dmaker.fan.p28",
            Specification::bundled("dmaker.fan.p28").unwrap(),
        ),
        (
            "dmaker.fan.p220",
            include_str!("../../../core/tests/fixtures/dmaker-p220.json"),
        ),
    ] {
        let (engine, mut state) = vacuum_fixture(model, document);
        let power = controls::power(&state).unwrap().key();
        state.values.insert(power.clone(), json!(true));
        let speed = state
            .spec
            .properties
            .iter()
            .find(|p| p.name == "speed-level" && p.range.is_some_and(|r| r[1] == 100.))
            .unwrap()
            .key();
        state.values.insert(speed.clone(), json!(47));
        let db = snapshot(&engine, state.clone());
        let b = binding(&db, "B7", "29");
        assert_eq!(b.key, speed);
        assert_eq!(b.read_state(&state, false), Ok(json!(47.)));
        assert_eq!(plan(b, &state, json!(0)), [(power.clone(), json!(false))]);
        assert_eq!(
            plan(b, &state, json!(75)),
            [(speed, json!(75)), (power.clone(), json!(true))]
        );
        assert!(
            !db.bindings.values().any(|b| b.key == "2.2"),
            "coarse gears duplicated the native slider"
        );
        characteristic(&db, "B7", "A7");
        state.values.insert(power, json!(false));
        assert_eq!(b.read_state(&state, false), Ok(json!(0.)));
        let primary = db.accessories[1]["services"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|s| s["primary"] == true)
            .collect::<Vec<_>>();
        assert_eq!(primary.len(), 1);
        assert_eq!(primary[0]["type"], "B7");
    }
}
#[test]
fn fan_auto_is_native_and_leaving_auto_preserves_an_existing_manual_mode() {
    let (engine, mut state) = vacuum_fixture(
        "dmaker.fan.p28",
        Specification::bundled("dmaker.fan.p28").unwrap(),
    );
    let mode = state
        .spec
        .properties
        .iter()
        .find(|p| p.service == "fan" && p.name == "mode")
        .unwrap()
        .clone();
    let auto = controls::option(&mode, &["smart"]).unwrap();
    state.values.insert(mode.key(), auto.clone());
    let db = snapshot(&engine, state.clone());
    let b = binding(&db, "B7", "BF");
    assert_eq!(b.read_state(&state, false), Ok(json!(1)));
    assert_eq!(plan(b, &state, json!(1)), [(mode.key(), auto)]);
    assert_eq!(plan(b, &state, json!(0)).len(), 1);
    let natural = controls::option(&mode, &["naturalwind"]).unwrap();
    state.values.insert(mode.key(), natural);
    assert!(plan(b, &state, json!(0)).is_empty());
}
#[test]
fn gear_only_fan_uses_equal_speed_bands_and_covers_the_original_gear_choices() {
    let (engine, mut state) = vacuum_fixture(
        "dmaker.fan.p220",
        include_str!("../../../core/tests/fixtures/dmaker-p220.json"),
    );
    state.spec.properties.retain(|p| p.name != "speed-level");
    let power = controls::power(&state).unwrap().key();
    state.values.insert(power.clone(), json!(true));
    state.values.insert("2.2".into(), json!(2));
    let db = snapshot(&engine, state.clone());
    let b = binding(&db, "B7", "29");
    assert_eq!(b.read_state(&state, false), Ok(json!(50.)));
    for (speed, level) in [(1, 1), (25, 1), (26, 2), (50, 2), (51, 3), (100, 4)] {
        assert_eq!(
            plan(b, &state, json!(speed)),
            [("2.2".into(), json!(level)), (power.clone(), json!(true))]
        );
    }
}
#[test]
fn purifier_speed_selects_favorite_mode_and_power_in_order() {
    let (engine, mut state) = vacuum_fixture(
        "zhimi.airpurifier.rma1",
        Specification::bundled("zhimi.airpurifier.rma1").unwrap(),
    );
    let power = controls::power(&state).unwrap().key();
    state.values.insert(power.clone(), json!(true));
    let favorite = state
        .spec
        .properties
        .iter()
        .find(|p| p.name == "favorite-level")
        .unwrap()
        .key();
    let mode = state
        .spec
        .properties
        .iter()
        .find(|p| p.service == "air-purifier" && p.name == "mode")
        .unwrap()
        .clone();
    let value = controls::option(&mode, &["favorite"]).unwrap();
    state.values.insert(favorite.clone(), json!(14));
    let db = snapshot(&engine, state.clone());
    let b = binding(&db, "BB", "29");
    assert_eq!(b.read_state(&state, false), Ok(json!(100.)));
    assert_eq!(
        plan(b, &state, json!(100)),
        [
            (favorite, json!(14)),
            (mode.key(), value),
            (power.clone(), json!(true))
        ]
    );
    assert_eq!(plan(b, &state, json!(0)), [(power, json!(false))]);
    characteristic(&db, "BB", "A7");
}
#[test]
fn climate_gears_share_a_native_slider_and_writable_temperature_is_not_a_sensor() {
    let (engine, mut state) = vacuum_fixture(
        "lumi.acpartner.mcn02",
        Specification::bundled("lumi.acpartner.mcn02").unwrap(),
    );
    let level = state
        .spec
        .properties
        .iter()
        .find(|p| p.service == "fan-control" && p.name == "fan-level")
        .unwrap()
        .clone();
    state
        .values
        .insert(level.key(), controls::option(&level, &["auto"]).unwrap());
    let db = snapshot(&engine, state.clone());
    let speed = binding(&db, "BC", "29");
    assert_eq!(speed.read_state(&state, false), Ok(json!(0.)));
    assert_eq!(
        plan(speed, &state, json!(100)),
        [(level.key(), level.choices.last().unwrap().value.clone())]
    );
    let mode = binding(&db, "BC", "B2");
    let writes = plan(mode, &state, json!(2));
    assert_eq!(writes.last().unwrap().1, json!(true));
    let mut temperature = property("temperature", "float", true, Some([16., 30., 1.]));
    temperature.piid = 90;
    state.spec.properties.push(temperature.clone());
    state.values.insert(temperature.key(), json!(22));
    let db = snapshot(&engine, state);
    assert!(
        !db.accessories[1]["services"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["type"] == "8A")
    );
}
#[test]
fn bath_heaters_use_heating_or_heat_mode_and_keep_light_as_a_dimmable_bulb() {
    for (document, mode_power) in [
        (
            include_str!("../../../core/tests/fixtures/xiaomi-bhf-na1.json"),
            false,
        ),
        (
            include_str!("../../../core/tests/fixtures/xiaomi-bhf-na2.json"),
            true,
        ),
    ] {
        let (engine, mut state) = vacuum_fixture("xiaomi.bhf.fixture", document);
        let db = snapshot(&engine, state.clone());
        let b = binding(&db, "BC", "B0");
        if mode_power {
            assert_eq!(plan(b, &state, json!(1)), [("4.17".into(), json!(2))]);
        } else {
            assert_eq!(b.key, "4.6");
            assert!(matches!(b.transform, Transform::Active));
        }
        if mode_power {
            state.values.insert("4.17".into(), json!(3));
            assert!(
                plan(b, &state, json!(0)).is_empty(),
                "turning off heat cancelled Dry mode"
            );
            state.values.insert("4.17".into(), json!(2));
            assert_eq!(plan(b, &state, json!(0)), [("4.17".into(), json!(0))]);
        }
        characteristic(&db, "43", "25");
        characteristic(&db, "43", "8");
        characteristic(&db, "BC", "12");
        assert_eq!(
            db.accessories[1]["services"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|s| s["primary"] == true)
                .count(),
            1
        );
    }
    let (engine, state) = vacuum_fixture(
        "yeelink.bhf.v10",
        include_str!("../../../core/tests/fixtures/yeelink-bhf-v10.json"),
    );
    let db = snapshot(&engine, state);
    assert!(
        !db.accessories[1]["services"]
            .as_array()
            .unwrap()
            .iter()
            .any(|s| s["type"] == "BC")
    );
    assert_eq!(
        db.accessories[1]["services"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["primary"] == true)
            .unwrap()["type"],
        "49"
    );
}
#[test]
fn auxiliary_controls_are_daily_only_bounded_and_do_not_generate_numeric_extremes() {
    let mut props = vec![(property("on", "bool", true, None), json!(true))];
    for i in 0..20 {
        props.push((
            property(&format!("daily-{i}"), "bool", true, None),
            json!(false),
        ));
    }
    props.push((
        property("target-time", "uint32", true, Some([1., 9999., 1.])),
        json!(1),
    ));
    let (engine, mut state) = fixture("outlet", props);
    let mut private = property("vendor-on", "bool", true, None);
    private.piid = 100;
    private.vendor_defined = true;
    state.spec.properties.push(private);
    let mut settings = property("alarm", "bool", true, None);
    settings.piid = 101;
    settings.service = "alarm".into();
    state.spec.properties.push(settings);
    let db = snapshot(&engine, state);
    let switches: Vec<_> = db.accessories[1]["services"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|s| s["type"] == "49")
        .collect();
    assert_eq!(switches.len(), 10);
    assert!(
        !db.bindings
            .values()
            .any(|b| ["2.100", "2.101", "2.22"].contains(&b.key.as_str()))
    );
}
#[test]
fn off_on_choices_merge_and_duplicate_option_labels_do_not_create_repeated_tiles() {
    let mut c = property("ion-purification", "uint8", true, None);
    c.choices = vec![
        Choice {
            value: json!(0),
            description: "关闭".into(),
            description_en: "Off".into(),
        },
        Choice {
            value: json!(1),
            description: "打开".into(),
            description_en: "On".into(),
        },
    ];
    let (engine, state) = fixture(
        "outlet",
        vec![
            (property("on", "bool", true, None), json!(true)),
            (c, json!(0)),
        ],
    );
    let db = snapshot(&engine, state.clone());
    let b = db
        .bindings
        .values()
        .find(|b| matches!(b.transform, Transform::Toggle { .. }))
        .unwrap();
    assert_eq!(plan(b, &state, json!(false)), [("2.2".into(), json!(0))]);
    assert_eq!(plan(b, &state, json!(true)), [("2.2".into(), json!(1))]);
}
#[test]
fn main_service_iids_and_aids_survive_the_mapping_upgrade() {
    let (engine, state) = vacuum_fixture(
        "dmaker.fan.p28",
        Specification::bundled("dmaker.fan.p28").unwrap(),
    );
    let mut layout = Layout::default();
    layout.aids.insert("1".into(), 71);
    layout.iids.insert("1:service:primary".into(), 101);
    layout.iids.insert("1:primary:power".into(), 104);
    layout.iids.insert("1:retired:increase:on".into(), 999);
    let db = build_states(&engine, &mut layout, vec![state]);
    assert_eq!(db.accessories[1]["aid"], 71);
    let service = db.accessories[1]["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["type"] == "B7")
        .unwrap();
    assert_eq!(service["iid"], 101);
    assert_eq!(characteristic(&db, "B7", "B0")["iid"], 104);
    assert_eq!(layout.iids["1:retired:increase:on"], 999);
}
