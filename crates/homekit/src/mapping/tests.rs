use super::*;
use mijialan_core::{Specification, spec::Choice};

fn property(name: &str, format: &str, writable: bool, range: Option<[f64; 3]>) -> Property {
    Property {
        siid: 2,
        piid: 1,
        service: String::new(),
        name: name.into(),
        description: name.into(),
        description_en: name.into(),
        format: format.into(),
        readable: true,
        writable,
        unit: String::new(),
        range,
        choices: vec![],
    }
}

fn fixture(kind: &str, properties: Vec<(Property, Value)>) -> (Engine, DeviceState) {
    let engine = Engine::demo();
    let mut state = engine.state("1").unwrap();
    state.device.model = "audit.fixture".into();
    state.spec = Specification {
        kind: kind.into(),
        ..Default::default()
    };
    state.values.clear();
    for (index, (mut property, value)) in properties.into_iter().enumerate() {
        property.service = kind.into();
        property.piid = index as u32 + 1;
        state.values.insert(property.key(), value);
        state.spec.properties.push(property);
    }
    (engine, state)
}

fn snapshot(engine: &Engine, state: DeviceState) -> Database {
    build_states(engine, &mut Layout::default(), vec![state])
}

fn characteristic<'a>(database: &'a Database, service: &str, characteristic: &str) -> &'a Value {
    database.accessories[1]["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["type"] == service)
        .unwrap()["characteristics"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["type"] == characteristic)
        .unwrap()
}

#[test]
fn invalid_device_readings_are_unavailable_instead_of_invalid_hap_values() {
    let (engine, state) = fixture(
        "light",
        vec![
            (property("on", "bool", true, None), json!("on")),
            (
                property("brightness", "uint8", true, Some([1., 100., 1.])),
                json!(255),
            ),
            (
                property(
                    "color-temperature",
                    "uint32",
                    true,
                    Some([2700., 6500., 1.]),
                ),
                json!(1),
            ),
        ],
    );
    let database = snapshot(&engine, state);
    for kind in ["25", "8", "CE"] {
        assert!(
            characteristic(&database, "43", kind)["value"].is_null(),
            "invalid reading leaked through {kind}"
        );
    }
}

#[test]
fn curtain_position_is_an_integral_percentage_of_the_actual_reading() {
    let (engine, state) = fixture(
        "curtain",
        vec![
            (
                property("target-position", "uint8", true, Some([0., 255., 1.])),
                json!(73),
            ),
            (
                property("current-position", "uint8", false, Some([0., 255., 1.])),
                json!(73),
            ),
        ],
    );
    let database = snapshot(&engine, state);
    for kind in ["7C", "6D"] {
        assert_eq!(
            characteristic(&database, "8C", kind)["value"].as_u64(),
            Some(29)
        );
    }
}

#[test]
fn humidifier_without_a_writable_threshold_uses_generic_controls() {
    for kind in ["humidifier", "dehumidifier"] {
        for target in [None, Some(false), Some(true)] {
            let mut props = vec![
                (property("on", "bool", true, None), json!(true)),
                (
                    property("relative-humidity", "float", false, Some([0., 100., 1.])),
                    json!(45),
                ),
            ];
            if let Some(writable) = target {
                props.push((
                    property("target-humidity", "uint8", writable, Some([30., 80., 1.])),
                    json!(55),
                ));
            }
            let (engine, state) = fixture(kind, props);
            let database = snapshot(&engine, state);
            let native = database.accessories[1]["services"]
                .as_array()
                .unwrap()
                .iter()
                .any(|s| s["type"] == "BD");
            assert_eq!(native, target == Some(true), "{kind}: target {target:?}");
            if native {
                let threshold = if kind == "humidifier" { "CA" } else { "C9" };
                assert_eq!(
                    characteristic(&database, "BD", threshold)["value"].as_f64(),
                    Some(55.)
                );
                assert_eq!(
                    characteristic(&database, "BD", "B4")["valid-values"],
                    json!([if kind == "humidifier" { 1 } else { 2 }])
                );
            }
        }
    }
}

#[test]
fn heating_and_cooling_modes_only_advertise_supported_values() {
    for (kind, modes, expected) in [
        ("heater", vec![], vec![1]),
        ("air-conditioner", vec!["Cool"], vec![2]),
        (
            "air-conditioner",
            vec!["Cool", "Auto", "Heat"],
            vec![0, 1, 2],
        ),
    ] {
        let mut props = vec![
            (property("on", "bool", true, None), json!(true)),
            (
                property("target-temperature", "float", true, Some([16., 30., 1.])),
                json!(22),
            ),
            (
                property("temperature", "float", false, Some([-40., 100., 0.1])),
                json!(21.5),
            ),
        ];
        if !modes.is_empty() {
            let mut mode = property("mode", "uint8", true, None);
            mode.choices = modes
                .into_iter()
                .enumerate()
                .map(|(n, description)| Choice {
                    value: json!(n),
                    description: description.into(),
                    description_en: description.into(),
                })
                .collect();
            props.push((mode, json!(0)));
        }
        let (engine, state) = fixture(kind, props);
        let database = snapshot(&engine, state);
        assert_eq!(
            characteristic(&database, "BC", "B2")["valid-values"],
            json!(expected)
        );
        if expected.contains(&0) || expected.contains(&1) {
            characteristic(&database, "BC", "12");
        }
        if expected.contains(&0) || expected.contains(&2) {
            characteristic(&database, "BC", "D");
        }
    }
}

#[test]
fn large_specs_are_bounded_to_one_hundred_services_with_stable_identifiers() {
    let mut mode = property("mode", "uint16", true, None);
    mode.choices = (0..150)
        .map(|n| Choice {
            value: json!(n),
            description: format!("Mode {n}"),
            description_en: format!("Mode {n}"),
        })
        .collect();
    let (engine, state) = fixture(
        "outlet",
        vec![
            (property("on", "bool", true, None), json!(true)),
            (mode, json!(0)),
        ],
    );
    let mut layout = Layout::default();
    let first = build_states(&engine, &mut layout, vec![state.clone()]);
    assert_eq!(
        first.accessories[1]["services"].as_array().unwrap().len(),
        100
    );
    let second = build_states(&engine, &mut layout, vec![state]);
    assert_eq!(first.accessories, second.accessories);
    assert_eq!(
        first.warnings.len(),
        1,
        "partial bridge coverage must be reported"
    );
    let exposed: BTreeSet<_> = first
        .accessories
        .iter()
        .flat_map(|a| {
            a["services"]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|s| s["characteristics"].as_array().unwrap())
                .map(move |c| (a["aid"].as_u64().unwrap(), c["iid"].as_u64().unwrap()))
        })
        .collect();
    assert!(first.bindings.keys().all(|id| exposed.contains(id)));
}

#[test]
fn duplicate_properties_do_not_duplicate_hap_instance_ids() {
    let (engine, mut state) = fixture(
        "light",
        vec![
            (property("on", "bool", true, None), json!(true)),
            (
                property("brightness", "uint8", true, Some([1., 100., 1.])),
                json!(50),
            ),
        ],
    );
    state.spec.properties.push(state.spec.properties[1].clone());
    let database = snapshot(&engine, state);
    let mut iids = BTreeSet::new();
    for service in database.accessories[1]["services"].as_array().unwrap() {
        assert!(iids.insert(service["iid"].as_u64().unwrap()));
        for c in service["characteristics"].as_array().unwrap() {
            assert!(
                iids.insert(c["iid"].as_u64().unwrap()),
                "duplicate characteristic IID"
            );
        }
    }
}
