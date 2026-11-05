use mijialan_core::{DeviceState, Engine, Property, engine::numeric};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

mod controls;
mod value;
pub(crate) use value::validate_write;

const MAX_SERVICES: usize = 100;

fn action_error(error: mijialan_core::Error) -> i32 {
    // Keep the underlying failure observable instead of reporting only HAP's
    // generic communication status; do not log request bodies or credentials.
    eprintln!("HomeKit action failed: {error}");
    -70402
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Layout {
    pub aids: BTreeMap<String, u64>,
    pub iids: BTreeMap<String, u64>,
    pub version: u64,
    pub signature: String,
}
impl Layout {
    fn aid(&mut self, did: &str) -> u64 {
        let next = self.aids.values().copied().max().unwrap_or(1) + 1;
        *self.aids.entry(did.into()).or_insert(next)
    }
    fn iid(&mut self, did: &str, key: &str) -> u64 {
        let prefix = format!("{did}:");
        let next = self
            .iids
            .iter()
            .filter(|(k, _)| k.starts_with(&prefix))
            .map(|(_, v)| *v)
            .max()
            .unwrap_or(7)
            + 1;
        *self.iids.entry(format!("{prefix}{key}")).or_insert(next)
    }
}

#[derive(Clone)]
pub enum Transform {
    Direct,
    Active,
    Working(u8),
    Percent,
    Mired,
    Option(Value),
    FanSpeed {
        power: String,
    },
    FanLevel {
        levels: Vec<Value>,
        power: String,
        mode: Option<(String, Value)>,
    },
    Gear {
        levels: Vec<Value>,
        auto: Option<Value>,
    },
    FanAuto {
        auto: Value,
        manual: Value,
    },
    PurifierMode {
        auto: Value,
        manual: Value,
    },
    Toggle {
        off: Value,
        on: Value,
    },
    Mode {
        selected: Value,
        off: Value,
        state: u8,
    },
    ClimateTarget {
        modes: Vec<(u8, Value)>,
        power: String,
    },
    ClimateCurrent {
        mode: String,
        heat: Option<Value>,
        cool: Option<Value>,
    },
    Position {
        opening: Option<Value>,
        closing: Option<Value>,
    },
    Running {
        rpm: Option<String>,
    },
    Fixed(Value),
    Action(u32, u32),
    Cleaning {
        start: (u32, u32),
        dock: (u32, u32),
    },
    Mapped(Vec<(u8, Value)>),
    FilterChange,
}
#[derive(Clone)]
pub struct Binding {
    pub did: String,
    pub key: String,
    pub transform: Transform,
    pub readable: bool,
    pub writable: bool,
}

impl Binding {
    pub fn read(&self, engine: &Engine, stale: bool) -> Result<Value, i32> {
        match &self.transform {
            Transform::Fixed(value) => return Ok(value.clone()),
            Transform::Action(_, _) => return Ok(json!(false)),
            _ => {}
        }
        let state = engine.state(&self.did).ok_or(-70402)?;
        self.read_state(&state, stale)
    }
    fn read_state(&self, state: &DeviceState, stale: bool) -> Result<Value, i32> {
        match &self.transform {
            Transform::Fixed(value) => return Ok(value.clone()),
            Transform::Action(_, _) => return Ok(json!(false)),
            _ => {}
        }
        if !stale && !state.online {
            return Err(-70402);
        }
        if matches!(self.transform, Transform::Cleaning { .. }) && !state.online {
            return Err(-70402);
        }
        let value = state.values.get(&self.key).ok_or(-70402)?;
        let property = state
            .spec
            .properties
            .iter()
            .find(|p| p.key() == self.key)
            .ok_or(-70402)?;
        if state.errors.contains_key(&self.key) {
            return Err(-70402);
        }
        if let Some(result) = controls::read(&self.transform, value, state)? {
            return Ok(result);
        }
        Ok(match &self.transform {
            Transform::Cleaning { .. } => json!(mijialan_core::vacuum::is_cleaning(
                mijialan_core::vacuum::status_description(property, value).ok_or(-70402)?
            )),
            Transform::Direct => value.clone(),
            Transform::Active => json!(if as_bool(value).map_err(|_| -70402)? {
                1
            } else {
                0
            }),
            Transform::Working(active) => json!(if as_bool(value).map_err(|_| -70402)? {
                *active
            } else {
                0
            }),
            Transform::Option(option) => json!(equivalent(value, option)),
            Transform::Mapped(options) => json!(
                options
                    .iter()
                    .find(|(_, v)| equivalent(value, v))
                    .map(|(n, _)| *n)
                    .ok_or(-70402)?
            ),
            Transform::FilterChange => json!(if value.as_f64().ok_or(-70402)? <= 0. {
                1
            } else {
                0
            }),
            Transform::Percent => {
                let [min, max, _] = property.range.ok_or(-70402)?;
                let raw = value.as_f64().filter(|v| v.is_finite()).ok_or(-70402)?;
                if !min.is_finite() || !max.is_finite() || max <= min || raw < min || raw > max {
                    return Err(-70402);
                }
                json!((raw - min) / (max - min) * 100.)
            }
            Transform::Mired => {
                let mired = (1_000_000.
                    / value
                        .as_f64()
                        .filter(|v| v.is_finite() && *v > 0.)
                        .ok_or(-70402)?)
                .round();
                if !mired.is_finite() || !(0. ..=u32::MAX as f64).contains(&mired) {
                    return Err(-70402);
                }
                json!(mired as u64)
            }
            _ => unreachable!(),
        })
    }
    pub fn write(&self, engine: &Engine, value: &Value) -> Result<(), i32> {
        if !self.writable {
            return Err(-70404);
        }
        match &self.transform {
            Transform::Fixed(fixed) => {
                return if equivalent(fixed, value) {
                    Ok(())
                } else {
                    Err(-70410)
                };
            }
            Transform::Action(siid, aiid) => {
                return if as_bool(value)? {
                    engine
                        .action(&self.did, *siid, *aiid, vec![])
                        .map_err(action_error)
                } else {
                    Ok(())
                };
            }
            _ => {}
        }
        let state = engine.state(&self.did).ok_or(-70402)?;
        if !state.online {
            return Err(-70402);
        }
        let property = state
            .spec
            .properties
            .iter()
            .find(|p| p.key() == self.key)
            .ok_or(-70402)?;
        if let Transform::Cleaning { start, dock } = &self.transform {
            let on = as_bool(value)?;
            let current = state
                .values
                .get(&self.key)
                .and_then(|v| mijialan_core::vacuum::status_description(property, v));
            if current.is_some_and(|description| {
                if on {
                    mijialan_core::vacuum::is_cleaning(description)
                } else {
                    mijialan_core::vacuum::is_docking(description)
                }
            }) {
                return Ok(());
            }
            let (siid, aiid) = if on { start } else { dock };
            return engine
                .action(&self.did, *siid, *aiid, vec![])
                .map_err(action_error);
        }
        if let Some(writes) = controls::writes(&self.transform, property, &state, value)? {
            // Validate the complete plan before any command reaches the device.
            for (key, value) in &writes {
                state
                    .spec
                    .properties
                    .iter()
                    .find(|p| p.key() == *key)
                    .ok_or(-70402)?
                    .validate(value)
                    .map_err(|_| -70410)?;
            }
            for (key, value) in writes {
                engine.write(&self.did, &key, value).map_err(|_| -70402)?;
            }
            return Ok(());
        }
        let output = match &self.transform {
            Transform::Direct => {
                if property.format == "bool" {
                    json!(as_bool(value)?)
                } else if let Some(number) = value.as_f64() {
                    numeric(number, &property.format)
                } else {
                    value.clone()
                }
            }
            Transform::Active => json!(match value.as_u64() {
                Some(0) => false,
                Some(1) => true,
                _ => return Err(-70410),
            }),
            Transform::Mapped(options) => options
                .iter()
                .find(|(n, _)| Some(*n as u64) == value.as_u64())
                .map(|(_, v)| v.clone())
                .ok_or(-70410)?,
            Transform::Option(option) => {
                if as_bool(value)? {
                    option.clone()
                } else {
                    return Ok(());
                }
            }
            Transform::Percent | Transform::Mired => {
                let number = value.as_f64().filter(|n| n.is_finite()).ok_or(-70410)?;
                let [min, max, step] = property.range.ok_or(-70410)?;
                if ![min, max, step].iter().all(|v| v.is_finite()) || min > max || step <= 0. {
                    return Err(-70410);
                }
                let raw = if matches!(self.transform, Transform::Percent) {
                    if !(0. ..=100.).contains(&number) {
                        return Err(-70410);
                    }
                    min + number * (max - min) / 100.
                } else {
                    if number <= 0. {
                        return Err(-70410);
                    }
                    1_000_000. / number
                };
                numeric(
                    (min + ((raw - min) / step).round() * step).clamp(min, max),
                    &property.format,
                )
            }
            _ => return Err(-70404),
        };
        property.validate(&output).map_err(|_| -70410)?;
        engine
            .write(&self.did, &self.key, output)
            .map_err(|_| -70402)
    }
}
fn as_bool(value: &Value) -> Result<bool, i32> {
    value
        .as_bool()
        .or_else(|| match value.as_u64() {
            Some(0) => Some(false),
            Some(1) => Some(true),
            _ => None,
        })
        .ok_or(-70410)
}
fn equivalent(a: &Value, b: &Value) -> bool {
    a == b || a.as_f64().zip(b.as_f64()).is_some_and(|(a, b)| a == b)
}

pub struct Database {
    pub accessories: Vec<Value>,
    pub bindings: BTreeMap<(u64, u64), Binding>,
    pub names: BTreeMap<(u64, u64), String>,
    pub warnings: Vec<String>,
}
impl Database {
    pub fn attribute(&self, aid: u64, iid: u64) -> Option<&Value> {
        self.accessories
            .iter()
            .find(|a| a["aid"].as_u64() == Some(aid))?["services"]
            .as_array()?
            .iter()
            .flat_map(|s| s["characteristics"].as_array().into_iter().flatten())
            .find(|c| c["iid"].as_u64() == Some(iid))
    }
    pub fn json(&self, engine: &Engine) -> Value {
        let mut accessories = self.accessories.clone();
        for accessory in &mut accessories {
            let aid = accessory["aid"].as_u64().unwrap();
            for service in accessory["services"].as_array_mut().unwrap() {
                for characteristic in service["characteristics"].as_array_mut().unwrap() {
                    let iid = characteristic["iid"].as_u64().unwrap();
                    if let Some(binding) = self.bindings.get(&(aid, iid)).filter(|b| b.readable) {
                        characteristic["value"] = binding
                            .read(engine, true)
                            .and_then(|raw| value::normalize_read(characteristic, raw))
                            .unwrap_or(Value::Null);
                    }
                }
            }
        }
        json!({"accessories":accessories})
    }
    /// All read paths use the same wire constraints, including events.
    pub fn read(&self, engine: &Engine, aid: u64, iid: u64, stale: bool) -> Result<Value, i32> {
        let attribute = self.attribute(aid, iid).ok_or(-70409)?;
        if !attribute["perms"]
            .as_array()
            .is_some_and(|p| p.iter().any(|p| p == "pr"))
        {
            return Err(-70405);
        }
        let raw = if let Some(binding) = self.bindings.get(&(aid, iid)) {
            binding.read(engine, stale)?
        } else {
            attribute.get("value").cloned().ok_or(-70402)?
        };
        value::normalize_read(attribute, raw)
    }
}

struct Builder<'a> {
    engine: &'a Engine,
    layout: &'a mut Layout,
    device: &'a DeviceState,
    aid: u64,
    services: Vec<Value>,
    bindings: BTreeMap<(u64, u64), Binding>,
    names: BTreeMap<(u64, u64), String>,
    consumed: BTreeSet<String>,
    service_indices: BTreeMap<String, usize>,
    omitted_services: usize,
}
impl Builder<'_> {
    fn primary(&mut self, service: usize) {
        for s in &mut self.services {
            s.as_object_mut().unwrap().remove("primary");
        }
        self.services[service]["primary"] = json!(true);
    }
    fn service(&mut self, key: &str, kind: &str, name: &str) -> Option<usize> {
        if let Some(index) = self.service_indices.get(key) {
            return Some(*index);
        }
        if self.services.len() >= MAX_SERVICES {
            self.omitted_services += 1;
            return None;
        }
        let iid = self
            .layout
            .iid(&self.device.device.did, &format!("service:{key}"));
        let name_iid = self
            .layout
            .iid(&self.device.device.did, &format!("{key}:name"));
        let configured_iid = self
            .layout
            .iid(&self.device.device.did, &format!("{key}:configured-name"));
        let name_key = format!("{}:{key}", self.device.device.did);
        let configured_name = self
            .engine
            .store
            .config()
            .homekit_names
            .get(&name_key)
            .cloned()
            .unwrap_or(name.into());
        self.names.insert((self.aid, configured_iid), name_key);
        self.services.push(json!({"iid":iid,"type":kind,"characteristics":[{"iid":name_iid,"type":"23","perms":["pr"],"format":"string","value":hap_string(name)},{"iid":configured_iid,"type":"E3","perms":["pr","pw","ev"],"format":"string","value":hap_string(&configured_name)}]}));
        let index = self.services.len() - 1;
        self.service_indices.insert(key.into(), index);
        Some(index)
    }
    #[allow(
        clippy::too_many_arguments,
        reason = "Keep each HAP field visible together in the declarative mapping table"
    )]
    fn characteristic(
        &mut self,
        service: usize,
        key: &str,
        kind: &str,
        format: &str,
        property: Option<&Property>,
        transform: Transform,
        writable: bool,
        range: Option<[f64; 3]>,
    ) {
        if self.services[service]["characteristics"]
            .as_array()
            .unwrap()
            .iter()
            .any(|c| c["type"] == kind)
        {
            return;
        }
        let iid = self.layout.iid(&self.device.device.did, key);
        let mut perms = vec!["pr", "ev"];
        if writable {
            perms.push("pw");
        }
        let binding = Binding {
            did: self.device.device.did.clone(),
            key: property.map(Property::key).unwrap_or_default(),
            transform,
            readable: true,
            writable,
        };
        let mut value = json!({"iid":iid,"type":kind,"format":format,"perms":perms});
        if let Some([min, max, step]) = range {
            value["minValue"] = json!(min);
            value["maxValue"] = json!(max);
            value["minStep"] = json!(step);
        }
        if format == "uint8" {
            let valid: Option<BTreeSet<u8>> = match &binding.transform {
                Transform::Fixed(v) => v
                    .as_u64()
                    .and_then(|v| u8::try_from(v).ok())
                    .map(|v| [v].into()),
                Transform::Mapped(v) => Some(v.iter().map(|(n, _)| *n).collect()),
                Transform::ClimateTarget { modes, .. } => {
                    Some(modes.iter().map(|(n, _)| *n).collect())
                }
                Transform::Working(state) | Transform::Mode { state, .. } if *state > 1 => {
                    Some([0, 1, *state].into())
                }
                _ => None,
            };
            if let Some(valid) = valid {
                value["valid-values"] = json!(valid);
            }
        }
        value["value"] = binding
            .read_state(self.device, true)
            .and_then(|raw| value::normalize_read(&value, raw))
            .unwrap_or(Value::Null);
        self.services[service]["characteristics"]
            .as_array_mut()
            .unwrap()
            .push(value);
        self.bindings.insert((self.aid, iid), binding);
        if let Some(property) = property {
            self.consumed.insert(property.key());
        }
    }
    fn named(&mut self, property: &Property, suffix: &str, title: &str, transform: Transform) {
        let key = format!("{}:{suffix}", property.key());
        let Some(service) = self.service(&key, "49", title) else {
            return;
        };
        self.characteristic(
            service,
            &format!("{key}:on"),
            "25",
            "bool",
            Some(property),
            transform,
            true,
            None,
        );
    }
}

pub fn build(engine: &Engine, layout: &mut Layout) -> Database {
    build_states(engine, layout, engine.states())
}

fn build_states(engine: &Engine, layout: &mut Layout, states: Vec<DeviceState>) -> Database {
    let mut database = Database {
        accessories: vec![json!({"aid":1,"services":[
            information("MijiaLAN Rust Bridge","MijiaLAN-Rust","bridge"),
            // HAP IP 1.1 requires protocol information on the primary
            // accessory only. IIDs 1–7 remain the existing identity.
            {"iid":8,"type":"A2","characteristics":[
                {"iid":9,"type":"37","format":"string","perms":["pr"],"value":"1.1.0"}
            ]}
        ]})],
        bindings: BTreeMap::new(),
        names: BTreeMap::new(),
        warnings: Vec::new(),
    };
    let included: BTreeSet<_> = engine
        .store
        .config()
        .devices
        .iter()
        .filter(|d| d.bridged)
        .map(|d| d.did.clone())
        .collect();
    for state in states
        .into_iter()
        .filter(|s| included.contains(&s.device.did) && !s.spec.properties.is_empty())
        .take(149)
    {
        let aid = layout.aid(&state.device.did);
        let mut builder = Builder {
            engine,
            layout,
            device: &state,
            aid,
            services: vec![information(
                &state.device.name,
                &state.device.model,
                &state.device.did,
            )],
            bindings: BTreeMap::new(),
            names: BTreeMap::new(),
            consumed: BTreeSet::new(),
            service_indices: BTreeMap::new(),
            omitted_services: 0,
        };
        let props = &state.spec.properties;
        let power = controls::power(&state);
        let native = native(&mut builder, &state);
        if let Some(power) = power.filter(|_| !native) {
            let kind = state.spec.kind.as_str();
            let service_type = match kind {
                "light" => "43",
                "fan" => "B7",
                "air-purifier" => "BB",
                _ => "47",
            };
            let s = builder
                .service("primary", service_type, &state.device.name)
                .expect("primary service is added before optional services");
            builder.primary(s);
            let active = ["fan", "air-purifier"].contains(&kind);
            builder.characteristic(
                s,
                "primary:power",
                if active { "B0" } else { "25" },
                if active { "uint8" } else { "bool" },
                Some(power),
                if active {
                    Transform::Active
                } else {
                    Transform::Direct
                },
                true,
                if active { Some([0., 1., 1.]) } else { None },
            );
            if kind == "air-purifier" {
                controls::purifier(&mut builder, s, &state, power);
            } else if kind == "fan" {
                controls::fan(&mut builder, s, &state, power);
            } else if service_type == "47" {
                builder.characteristic(
                    s,
                    "primary:in-use",
                    "26",
                    "bool",
                    Some(power),
                    Transform::Direct,
                    false,
                    None,
                );
            }
            for p in props {
                if !p.writable {
                    continue;
                }
                if kind == "light" && p.name == "brightness" {
                    builder.characteristic(
                        s,
                        "primary:brightness",
                        "8",
                        "int",
                        Some(p),
                        Transform::Direct,
                        true,
                        Some([0., 100., 1.]),
                    );
                }
                if kind == "light"
                    && p.name == "color-temperature"
                    && let Some([min, max, _]) = p.range.filter(|r| r[0] > 0.)
                {
                    builder.characteristic(
                        s,
                        "primary:ct",
                        "CE",
                        "uint32",
                        Some(p),
                        Transform::Mired,
                        true,
                        Some([(1_000_000. / max).round(), (1_000_000. / min).round(), 1.]),
                    );
                }
            }
        }
        let reviewed = mijialan_core::Specification::bundled(&state.device.model).is_some();
        for p in props
            .iter()
            .filter(|p| p.readable && !p.writable && (reviewed || !p.vendor_defined))
        {
            if builder.consumed.contains(&p.key()) {
                continue;
            }
            let (service, characteristic, range) = match p.name.as_str() {
                "temperature" => ("8A", "11", [-40., 100., 0.1]),
                "relative-humidity" => ("82", "10", [0., 100., 1.]),
                "pm2.5-density" => ("8D", "C6", [0., 1000., 1.]),
                "filter-life-level" => ("BA", "AB", [0., 100., 1.]),
                _ => continue,
            };
            let Some(s) = builder.service(&format!("sensor:{}", p.key()), service, p.label())
            else {
                continue;
            };
            if service == "8D" {
                builder.characteristic(
                    s,
                    &format!("sensor:{}:quality", p.key()),
                    "95",
                    "uint8",
                    None,
                    Transform::Fixed(json!(0)),
                    false,
                    Some([0., 5., 1.]),
                );
            }
            if service == "BA" {
                builder.characteristic(
                    s,
                    &format!("sensor:{}:change", p.key()),
                    "AC",
                    "uint8",
                    Some(p),
                    Transform::FilterChange,
                    false,
                    Some([0., 1., 1.]),
                );
            }
            builder.characteristic(
                s,
                &format!("sensor:{}:value", p.key()),
                characteristic,
                "float",
                Some(p),
                Transform::Direct,
                false,
                Some(range),
            );
        }
        controls::extras(&mut builder, &state, reviewed);
        if builder.omitted_services > 0 {
            database.warnings.push(if mijialan_core::localization::english() {
                format!("Some extra Home controls for {} exceed the bridge limit; use the client for those controls.", state.device.name)
            } else {
                format!("「{}」的部分附加功能超出家庭桥接上限，仍可在客户端使用。", state.device.name)
            });
        }
        database
            .accessories
            .push(json!({"aid":aid,"services":builder.services}));
        database.bindings.extend(builder.bindings);
        database.names.extend(builder.names);
    }
    database
}

fn information(name: &str, model: &str, serial: &str) -> Value {
    json!({"iid":1,"type":"3E","characteristics":[
        {"iid":2,"type":"14","format":"bool","perms":["pw"]},
        {"iid":3,"type":"20","format":"string","perms":["pr"],"value":"iPocket"},
        {"iid":4,"type":"21","format":"string","perms":["pr"],"value":hap_string(model)},
        {"iid":5,"type":"23","format":"string","perms":["pr"],"value":hap_string(name)},
        {"iid":6,"type":"30","format":"string","perms":["pr"],"value":hap_string(&format!("mijia-{serial}"))},
        {"iid":7,"type":"52","format":"string","perms":["pr"],"value":"0.1.0"}
    ]})
}

/// The default HAP string limit is 64 UTF-8 bytes, not 64 characters.
/// Bound wire values without modifying the user's original device/config name.
fn hap_string(value: &str) -> &str {
    let mut end = value.len().min(64);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

fn native(b: &mut Builder<'_>, state: &DeviceState) -> bool {
    let props = &state.spec.properties;
    let power = controls::power(state);
    let find = |names: &[&str]| props.iter().find(|p| names.contains(&p.name.as_str()));
    let kind = state.spec.kind.as_str();
    if kind == "bath-heater" {
        return controls::bath_heater(b, state);
    }
    if kind == "vacuum" {
        let action = |service: &str, name: &str| {
            state
                .spec
                .actions
                .iter()
                .find(|a| a.service == service && a.name == name && a.inputs.is_empty())
        };
        let (Some(status), Some(start), Some(dock)) = (
            mijialan_core::vacuum::status_property(&state.spec),
            action("vacuum", "start-sweep"),
            action("battery", "start-charge").or_else(|| action("vacuum", "start-charge")),
        ) else {
            return false;
        };
        let Some(service) = b.service("native", "49", &state.device.name) else {
            return false;
        };
        b.primary(service);
        b.characteristic(
            service,
            "native:cleaning",
            "25",
            "bool",
            Some(status),
            Transform::Cleaning {
                start: (start.siid, start.aiid),
                dock: (dock.siid, dock.aiid),
            },
            true,
            None,
        );
        b.consumed
            .insert(format!("action:{}.{}", start.siid, start.aiid));
        b.consumed
            .insert(format!("action:{}.{}", dock.siid, dock.aiid));
        return true;
    }
    if kind == "curtain" || kind == "window-covering" {
        let Some(target) = find(&["target-position"]).filter(|p| p.writable && p.range.is_some())
        else {
            return false;
        };
        let Some(current) = find(&["current-position"]).filter(|p| p.readable && p.range.is_some())
        else {
            return false;
        };
        let Some(s) = b.service("native", "8C", &state.device.name) else {
            return false;
        };
        b.primary(s);
        b.characteristic(
            s,
            "native:target",
            "7C",
            "uint8",
            Some(target),
            Transform::Percent,
            true,
            Some([0., 100., 1.]),
        );
        b.characteristic(
            s,
            "native:current",
            "6D",
            "uint8",
            Some(current),
            Transform::Percent,
            false,
            Some([0., 100., 1.]),
        );
        if let Some(status) = find(&["status"]).filter(|p| p.readable) {
            b.characteristic(
                s,
                "native:state",
                "72",
                "uint8",
                Some(status),
                Transform::Position {
                    opening: controls::option(status, &["opening"]),
                    closing: controls::option(status, &["closing"]),
                },
                false,
                Some([0., 2., 1.]),
            );
        } else {
            b.characteristic(
                s,
                "native:state",
                "72",
                "uint8",
                None,
                Transform::Fixed(json!(2)),
                false,
                Some([0., 2., 1.]),
            );
        }
        return true;
    }
    if kind == "humidifier" || kind == "dehumidifier" {
        let (Some(power), Some(humidity), Some(target)) = (
            power,
            find(&["relative-humidity"]).filter(|p| p.readable),
            find(&["target-humidity"]).filter(|p| p.writable && p.range.is_some()),
        ) else {
            return false;
        };
        let Some([lo, hi, step]) = target.range.filter(|r| r[0].max(0.) <= r[1].min(100.)) else {
            return false;
        };
        let humidifying = kind == "humidifier";
        let Some(s) = b.service("native", "BD", &state.device.name) else {
            return false;
        };
        b.primary(s);
        b.characteristic(
            s,
            "native:power",
            "B0",
            "uint8",
            Some(power),
            Transform::Active,
            true,
            Some([0., 1., 1.]),
        );
        b.characteristic(
            s,
            "native:current",
            "B3",
            "uint8",
            Some(power),
            Transform::Working(if humidifying { 2 } else { 3 }),
            false,
            Some([0., 3., 1.]),
        );
        b.characteristic(
            s,
            "native:target",
            "B4",
            "uint8",
            None,
            Transform::Fixed(json!(if humidifying { 1 } else { 2 })),
            true,
            Some([0., 2., 1.]),
        );
        b.characteristic(
            s,
            "native:humidity",
            "10",
            "float",
            Some(humidity),
            Transform::Direct,
            false,
            Some([0., 100., 1.]),
        );
        b.characteristic(
            s,
            "native:threshold",
            if humidifying { "CA" } else { "C9" },
            "float",
            Some(target),
            Transform::Direct,
            true,
            Some([lo.max(0.), hi.min(100.), step]),
        );
        if let Some(water) =
            find(&["water-level"]).filter(|p| p.readable && p.range.is_some_and(|r| r[0] < r[1]))
        {
            b.characteristic(
                s,
                "native:water",
                "B5",
                "float",
                Some(water),
                Transform::Percent,
                false,
                Some([0., 100., 1.]),
            );
        }
        controls::child_lock(b, s);
        return true;
    }
    if kind == "heater" || kind == "air-conditioner" {
        let (Some(power), Some(target)) = (
            power,
            find(&["target-temperature"]).filter(|p| p.writable && p.range.is_some()),
        ) else {
            return false;
        };
        let modes = if kind == "air-conditioner" {
            let Some(mode) = find(&["mode"]).filter(|p| p.writable) else {
                return false;
            };
            let values: Vec<_> = [
                (0, &["auto", "automatic"][..]),
                (1, &["heat", "heating"][..]),
                (2, &["cool", "cooling"][..]),
            ]
            .into_iter()
            .filter_map(|(n, names)| controls::option(mode, names).map(|v| (n, v)))
            .collect();
            if values.is_empty() {
                return false;
            }
            Some((mode, values))
        } else {
            None
        };
        let Some([lo, hi, step]) = target.range.filter(|r| r[0].max(0.) <= r[1].min(38.)) else {
            return false;
        };
        let climate_range = Some([lo.max(0.), hi.min(38.), step]);
        let temperature = find(&["temperature", "indoor-temperature"])
            .filter(|p| p.readable)
            .unwrap_or(target);
        let Some(s) = b.service("native", "BC", &state.device.name) else {
            return false;
        };
        b.primary(s);
        b.characteristic(
            s,
            "native:power",
            "B0",
            "uint8",
            Some(power),
            Transform::Active,
            true,
            Some([0., 1., 1.]),
        );
        let current = modes
            .as_ref()
            .map_or(Transform::Working(2), |(mode, values)| {
                Transform::ClimateCurrent {
                    mode: mode.key(),
                    heat: values.iter().find(|(n, _)| *n == 1).map(|(_, v)| v.clone()),
                    cool: values.iter().find(|(n, _)| *n == 2).map(|(_, v)| v.clone()),
                }
            });
        b.characteristic(
            s,
            "native:current",
            "B1",
            "uint8",
            Some(power),
            current,
            false,
            Some([0., 3., 1.]),
        );
        if let Some((mode, values)) = modes {
            let states: Vec<_> = values.iter().map(|(n, _)| *n).collect();
            b.characteristic(
                s,
                "native:target-mode",
                "B2",
                "uint8",
                Some(mode),
                Transform::ClimateTarget {
                    modes: values,
                    power: power.key(),
                },
                true,
                Some([0., 2., 1.]),
            );
            if states.contains(&0) || states.contains(&2) {
                b.characteristic(
                    s,
                    "native:cooling",
                    "D",
                    "float",
                    Some(target),
                    Transform::Direct,
                    true,
                    climate_range,
                );
            }
            if states.contains(&0) || states.contains(&1) {
                b.characteristic(
                    s,
                    "native:heating",
                    "12",
                    "float",
                    Some(target),
                    Transform::Direct,
                    true,
                    climate_range,
                );
            }
            for (index, choice) in mode.choices.iter().enumerate() {
                if [
                    controls::option(mode, &["auto", "automatic"]),
                    controls::option(mode, &["heat", "heating"]),
                    controls::option(mode, &["cool", "cooling"]),
                    controls::option(mode, &["off", "none"]),
                ]
                .iter()
                .flatten()
                .any(|v| equivalent(v, &choice.value))
                {
                    continue;
                }
                let title = if mijialan_core::localization::english() {
                    &choice.description_en
                } else {
                    &choice.description
                };
                b.named(
                    mode,
                    &format!("option:{index}"),
                    &format!("{} · {title}", mode.label()),
                    Transform::Option(choice.value.clone()),
                );
            }
        } else {
            b.characteristic(
                s,
                "native:target-mode",
                "B2",
                "uint8",
                None,
                Transform::Fixed(json!(1)),
                true,
                Some([0., 2., 1.]),
            );
            b.characteristic(
                s,
                "native:heating",
                "12",
                "float",
                Some(target),
                Transform::Direct,
                true,
                climate_range,
            );
        }
        b.characteristic(
            s,
            "native:temperature",
            "11",
            "float",
            Some(temperature),
            Transform::Direct,
            false,
            Some([-40., 100., 0.1]),
        );
        b.characteristic(
            s,
            "native:units",
            "36",
            "uint8",
            None,
            Transform::Fixed(json!(0)),
            true,
            Some([0., 1., 1.]),
        );
        controls::climate_fan(b, s, state);
        return true;
    }
    false
}

#[cfg(test)]
mod tests;
