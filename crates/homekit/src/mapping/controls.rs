//! Native Home controls, including the bounded auxiliary switch policy.
use super::*;

fn reading<'a>(state: &'a DeviceState, key: &str) -> Result<&'a Value, i32> {
    if state.errors.contains_key(key) {
        return Err(-70402);
    }
    state.values.get(key).ok_or(-70402)
}
pub(super) fn read(
    t: &Transform,
    property: &Property,
    value: &Value,
    state: &DeviceState,
) -> Result<Option<Value>, i32> {
    Ok(Some(match t {
        Transform::FanSpeed { power } => {
            json!(if as_bool(reading(state, power)?).map_err(|_| -70402)? {
                value.as_f64().ok_or(-70402)?
            } else {
                0.
            })
        }
        Transform::FanLevel { levels, power, .. } => {
            let i = levels
                .iter()
                .position(|v| equivalent(v, value))
                .ok_or(-70402)?;
            json!(if as_bool(reading(state, power)?).map_err(|_| -70402)? {
                (i + 1) as f64 * 100. / levels.len() as f64
            } else {
                0.
            })
        }
        Transform::Gear { levels, auto } => {
            if auto.as_ref().is_some_and(|v| equivalent(v, value)) {
                json!(0.)
            } else {
                json!(
                    (levels
                        .iter()
                        .position(|v| equivalent(v, value))
                        .ok_or(-70402)?
                        + 1) as f64
                        * 100.
                        / levels.len() as f64
                )
            }
        }
        Transform::FanAuto { auto, .. } | Transform::PurifierMode { auto, .. } => {
            json!(u8::from(equivalent(value, auto)))
        }
        Transform::Toggle { on, .. } => json!(equivalent(value, on)),
        Transform::Mode {
            selected, state, ..
        } => json!(if equivalent(value, selected) {
            *state
        } else {
            0
        }),
        Transform::ClimateTarget { modes, .. } => {
            if !listed_option(property, value) {
                return Err(-70402);
            }
            json!(
                modes
                    .iter()
                    .find(|(_, v)| equivalent(v, value))
                    .or_else(|| modes.iter().find(|(n, _)| *n == 0))
                    .or_else(|| modes.first())
                    .ok_or(-70402)?
                    .0
            )
        }
        Transform::ClimateCurrent { mode, heat, cool } => {
            if !as_bool(value).map_err(|_| -70402)? {
                json!(0)
            } else {
                let mode_property = state
                    .spec
                    .properties
                    .iter()
                    .find(|p| p.key() == *mode)
                    .ok_or(-70402)?;
                let mode = reading(state, mode)?;
                if !valid_option_reading(mode_property, mode) || !listed_option(mode_property, mode)
                {
                    return Err(-70402);
                }
                json!(if heat.as_ref().is_some_and(|v| equivalent(v, mode)) {
                    2
                } else if cool.as_ref().is_some_and(|v| equivalent(v, mode)) {
                    3
                } else {
                    1
                })
            }
        }
        Transform::Position { opening, closing } => {
            json!(if opening.as_ref().is_some_and(|v| equivalent(v, value)) {
                1
            } else if closing.as_ref().is_some_and(|v| equivalent(v, value)) {
                0
            } else {
                2
            })
        }
        Transform::Running { rpm } => {
            if !as_bool(value).map_err(|_| -70402)? {
                json!(0)
            } else if let Some(key) = rpm {
                json!(if reading(state, key)?.as_f64().ok_or(-70402)? > 0. {
                    2
                } else {
                    1
                })
            } else {
                json!(2)
            }
        }
        _ => return Ok(None),
    }))
}

type Writes = Vec<(String, Value)>;
pub(super) fn writes(
    t: &Transform,
    p: &Property,
    state: &DeviceState,
    value: &Value,
) -> Result<Option<Writes>, i32> {
    fn gear(levels: &[Value], speed: f64) -> Result<Value, i32> {
        if levels.is_empty() {
            return Err(-70410);
        }
        let i = (speed * levels.len() as f64 / 100. - 1e-6).ceil().max(1.) as usize - 1;
        Ok(levels[i.min(levels.len() - 1)].clone())
    }
    let n = || {
        value
            .as_f64()
            .filter(|v| v.is_finite() && (0. ..=100.).contains(v))
            .ok_or(-70410)
    };
    let set = |v| (p.key(), v);
    Ok(Some(match t {
        Transform::FanSpeed { power } => {
            if n()? == 0. {
                vec![(power.clone(), json!(false))]
            } else {
                vec![
                    set(numeric(n()?.round(), &p.format)),
                    (power.clone(), json!(true)),
                ]
            }
        }
        Transform::FanLevel {
            levels,
            power,
            mode,
        } => {
            if n()? == 0. {
                vec![(power.clone(), json!(false))]
            } else {
                let mut w = vec![set(gear(levels, n()?)?)];
                if let Some(mode) = mode {
                    w.push(mode.clone());
                }
                w.push((power.clone(), json!(true)));
                w
            }
        }
        Transform::Gear { levels, auto } => {
            if n()? == 0. {
                auto.iter().cloned().map(set).collect()
            } else {
                vec![set(gear(levels, n()?)?)]
            }
        }
        Transform::PurifierMode { auto, manual } => match value.as_u64() {
            Some(1) => vec![set(auto.clone())],
            Some(0) => vec![set(manual.clone())],
            _ => return Err(-70410),
        },
        Transform::FanAuto { auto, manual } => match value.as_u64() {
            Some(1) => vec![set(auto.clone())],
            Some(0) if equivalent(reading(state, &p.key())?, auto) => vec![set(manual.clone())],
            Some(0) => vec![],
            _ => return Err(-70410),
        },
        Transform::Toggle { off, on } => vec![set(if as_bool(value)? {
            on.clone()
        } else {
            off.clone()
        })],
        Transform::Mode { selected, off, .. } => match value.as_u64() {
            Some(1) => vec![set(selected.clone())],
            Some(0) if equivalent(reading(state, &p.key())?, selected) => {
                vec![set(off.clone())]
            }
            Some(0) => vec![],
            _ => return Err(-70410),
        },
        Transform::ClimateTarget { modes, power } => vec![
            set(modes
                .iter()
                .find(|(n, _)| Some(*n as u64) == value.as_u64())
                .ok_or(-70410)?
                .1
                .clone()),
            (power.clone(), json!(true)),
        ],
        _ => return Ok(None),
    }))
}

pub(super) fn option(p: &Property, names: &[&str]) -> Option<Value> {
    p.choices
        .iter()
        .find(|c| {
            names.contains(
                &c.description_en
                    .to_lowercase()
                    .chars()
                    .filter(|c| c.is_alphabetic())
                    .collect::<String>()
                    .as_str(),
            )
        })
        .map(|c| c.value.clone())
}
fn gears(p: &Property) -> Option<(Vec<Value>, Option<Value>)> {
    if !p.readable || !p.writable {
        return None;
    }
    let auto = option(p, &["auto", "automatic", "smart", "smartwind"]);
    let levels: Vec<_> = p
        .choices
        .iter()
        .filter(|c| Some(&c.value) != auto.as_ref())
        .collect();
    if !(2..=10).contains(&levels.len())
        || !levels.iter().all(|c| {
            [
                "level", "", "low", "medium", "middle", "high", "strong", "turbo", "silent",
                "quiet",
            ]
            .contains(
                &c.description_en
                    .to_lowercase()
                    .chars()
                    .filter(|c| c.is_alphabetic())
                    .collect::<String>()
                    .as_str(),
            )
        })
        || !levels.windows(2).all(|v| {
            v[0].value
                .as_i64()
                .zip(v[1].value.as_i64())
                .is_some_and(|(a, b)| a < b)
        })
    {
        return None;
    }
    Some((levels.iter().map(|c| c.value.clone()).collect(), auto))
}
pub(super) fn power(state: &DeviceState) -> Option<&Property> {
    state
        .spec
        .primary_power()
        .filter(|p| p.readable && p.writable && p.format == "bool")
}
pub(super) fn child_lock(b: &mut Builder<'_>, service: usize) {
    if let Some(p) = b.device.spec.properties.iter().find(|p| {
        p.name == "physical-controls-locked" && p.format == "bool" && p.readable && p.writable
    }) {
        b.characteristic(
            service,
            "native:child-lock",
            "A7",
            "uint8",
            Some(p),
            Transform::Active,
            true,
            Some([0., 1., 1.]),
        );
    }
}
pub(super) fn fan(b: &mut Builder<'_>, s: usize, state: &DeviceState, power: &Property) {
    let props = &state.spec.properties;
    let levels = props
        .iter()
        .filter(|p| p.service == state.spec.kind && p.name == "fan-level")
        .find_map(|p| {
            gears(p)
                .filter(|(_, auto)| auto.is_none())
                .map(|(values, _)| (p, values))
        });
    let mut speeds: Vec<_> = props
        .iter()
        .filter(|p| {
            ["speed-level", "fan-level"].contains(&p.name.as_str())
                && p.readable
                && p.writable
                && p.choices.is_empty()
                && p.range.is_some_and(|[lo, hi, step]| {
                    (lo == 0. || lo == 1.) && hi == 100. && step == 1.
                })
        })
        .collect();
    speeds.sort_by_key(|p| p.service != state.spec.kind);
    if let Some(speed) = speeds.first() {
        b.characteristic(
            s,
            "primary:speed",
            "29",
            "float",
            Some(speed),
            Transform::FanSpeed { power: power.key() },
            true,
            Some([0., 100., 1.]),
        );
        if let Some((p, _)) = &levels {
            b.consumed.insert(p.key());
        }
    } else if let Some((p, levels)) = levels {
        let step = 100. / levels.len() as f64;
        b.characteristic(
            s,
            "primary:speed",
            "29",
            "float",
            Some(p),
            Transform::FanLevel {
                levels,
                power: power.key(),
                mode: None,
            },
            true,
            Some([0., 100., step]),
        );
    }
    if let Some(swing) = props.iter().find(|p| {
        p.service == "fan" && p.name == "horizontal-swing" && p.format == "bool" && p.writable
    }) {
        b.characteristic(
            s,
            "primary:swing",
            "B6",
            "uint8",
            Some(swing),
            Transform::Active,
            true,
            Some([0., 1., 1.]),
        );
    }
    if let Some(mode) = props
        .iter()
        .find(|p| p.service == "fan" && p.name == "mode" && p.readable && p.writable)
        && let Some(auto) = option(mode, &["auto", "automatic", "smart", "smartwind"])
        && let Some(manual) = mode.choices.iter().find(|c| c.value != auto)
    {
        b.characteristic(
            s,
            "primary:target",
            "BF",
            "uint8",
            Some(mode),
            Transform::FanAuto {
                auto: auto.clone(),
                manual: manual.value.clone(),
            },
            true,
            Some([0., 1., 1.]),
        );
        b.consumed.remove(&mode.key());
        b.consumed.insert(format!("{}={auto}", mode.key()));
    }
    child_lock(b, s);
}
pub(super) fn purifier(b: &mut Builder<'_>, s: usize, state: &DeviceState, power: &Property) {
    let props = &state.spec.properties;
    let mode = props
        .iter()
        .find(|p| p.service == "air-purifier" && p.name == "mode" && p.readable && p.writable);
    b.characteristic(
        s,
        "primary:current",
        "A9",
        "uint8",
        Some(power),
        Transform::Running {
            rpm: props
                .iter()
                .find(|p| p.name == "moto-speed-rpm" && p.readable)
                .map(Property::key),
        },
        false,
        Some([0., 2., 1.]),
    );
    if let Some(mode) = mode
        && let Some(auto) = option(mode, &["auto", "automatic"])
        && let Some(manual) = option(mode, &["favorite"]).or_else(|| {
            mode.choices
                .iter()
                .find(|c| c.value != auto)
                .map(|c| c.value.clone())
        })
    {
        b.characteristic(
            s,
            "primary:target",
            "A8",
            "uint8",
            Some(mode),
            Transform::PurifierMode { auto, manual },
            true,
            Some([0., 1., 1.]),
        );
        b.consumed.remove(&mode.key());
    } else {
        b.characteristic(
            s,
            "primary:target",
            "A8",
            "uint8",
            None,
            Transform::Fixed(json!(0)),
            true,
            Some([0., 1., 1.]),
        );
    }
    for p in props.iter().filter(|p| {
        p.readable
            && p.writable
            && (["favorite-level", "favorite-fan-level"].contains(&p.name.as_str())
                || p.service == "air-purifier-favorite" && p.name == "fan-level")
    }) {
        let levels = if (2..=20).contains(&p.choices.len())
            && p.choices.windows(2).all(|w| {
                w[0].value
                    .as_i64()
                    .zip(w[1].value.as_i64())
                    .is_some_and(|(a, b)| a < b)
            }) {
            p.choices
                .iter()
                .map(|c| c.value.clone())
                .collect::<Vec<_>>()
        } else if let Some([lo, hi, 1.]) = p.range
            && lo.fract() == 0.
            && hi.fract() == 0.
            && (1. ..=19.).contains(&(hi - lo))
            && lo >= i32::MIN as f64
            && hi <= i32::MAX as f64
        {
            (lo as i64..=hi as i64).map(|n| json!(n)).collect()
        } else {
            continue;
        };
        let step = 100. / levels.len() as f64;
        let mode = mode.and_then(|m| option(m, &["favorite"]).map(|v| (m.key(), v)));
        b.characteristic(
            s,
            "primary:speed",
            "29",
            "float",
            Some(p),
            Transform::FanLevel {
                levels,
                power: power.key(),
                mode,
            },
            true,
            Some([0., 100., step]),
        );
        break;
    }
    child_lock(b, s);
}
pub(super) fn climate_fan(b: &mut Builder<'_>, s: usize, state: &DeviceState) {
    let props = &state.spec.properties;
    if let Some(p) = props.iter().find(|p| {
        p.service == "fan-control"
            && ["vertical-swing", "horizontal-swing"].contains(&p.name.as_str())
            && p.writable
            && p.format == "bool"
    }) {
        b.characteristic(
            s,
            "native:swing",
            "B6",
            "uint8",
            Some(p),
            Transform::Active,
            true,
            Some([0., 1., 1.]),
        );
    }
    if let Some(p) = props
        .iter()
        .find(|p| p.service == "fan-control" && p.name == "fan-level")
        && let Some((levels, auto)) = gears(p)
    {
        let step = 100. / levels.len() as f64;
        b.characteristic(
            s,
            "native:speed",
            "29",
            "float",
            Some(p),
            Transform::Gear {
                levels: levels.clone(),
                auto,
            },
            true,
            Some([0., 100., step]),
        );
        b.consumed.remove(&p.key());
        for value in levels {
            b.consumed.insert(format!("{}={value}", p.key()));
        }
    }
    child_lock(b, s);
}

fn daily(service: &str, name: &str) -> bool {
    ![
        "alarm",
        "indicator-light",
        "screen",
        "display",
        "physical-controls-locked",
        "delay",
        "no-disturb",
        "panel-service",
        "remote-control-management",
        "iot-linkage",
        "detect-nobody-save-energy",
        "switch-sensor",
        "occupancy-sensor",
        "speaker",
        "camera-control",
    ]
    .contains(&service)
        && !service.ends_with("-dev-mode")
        && ![
            "position",
            "direction",
            "angle",
            "sensitivity",
            "distance",
            "effect",
            "linkage",
            "power-on-state",
            "screen",
            "volume",
            "language",
            "alarm",
            "indicator",
            "reset",
            "display-unit",
            "room-size",
        ]
        .iter()
        .any(|w| name.contains(w))
}
fn off_on(p: &Property, state: &DeviceState) -> Option<(Value, Value)> {
    if !p.readable
        || p.choices.len() != 2
        || state
            .spec
            .actions
            .iter()
            .any(|a| a.inputs.iter().any(|i| i.key() == p.key()))
    {
        return None;
    }
    let off: Vec<_> = p
        .choices
        .iter()
        .filter(|c| {
            ["off", "close", "closed", "disable", "disabled", "disenable"].contains(
                &c.description_en
                    .to_lowercase()
                    .chars()
                    .filter(|c| c.is_alphabetic())
                    .collect::<String>()
                    .as_str(),
            ) || ["关", "关闭"].contains(&c.description.trim())
        })
        .collect();
    if off.len() != 1 {
        return None;
    }
    Some((
        off[0].value.clone(),
        p.choices
            .iter()
            .find(|c| c.value != off[0].value)?
            .value
            .clone(),
    ))
}
fn presets(model: &str, p: &Property) -> Vec<Value> {
    let values: &[i64] = match (model, p.siid, p.piid) {
        ("dmaker.fan.p28", 3, 1) => &[0, 30, 60, 120, 240],
        ("zhimi.airpurifier.rma1", 9, 2) => &[0, 4, 9, 14],
        ("careli.fryer.maf07c", 2, 3) => &[10, 20, 30, 60],
        ("careli.fryer.maf07c", 2, 4) => &[80, 160, 180, 200],
        ("cuco.plug.v3", 8, 2) => &[30, 60, 120, 240],
        ("cuco.plug.v3", 9, 2) => &[1500, 2000, 2500],
        ("cuco.plug.v3", 15, 1) => &[300, 1000, 1500, 2500],
        _ => &[],
    };
    values
        .iter()
        .map(|v| json!(v))
        .filter(|v| p.validate(v).is_ok())
        .collect()
}
pub(super) fn extras(b: &mut Builder<'_>, state: &DeviceState, reviewed: bool) {
    enum Control<'a> {
        Property(&'a Property),
        Action(&'a mijialan_core::spec::Action),
    }
    let mut candidates: Vec<_> = state
        .spec
        .properties
        .iter()
        .filter(|p| p.writable && (reviewed || !p.vendor_defined && daily(&p.service, &p.name)))
        .enumerate()
        .map(|(i, p)| {
            let rank = if p.service == state.spec.kind && p.name == "mode" {
                1
            } else if p.name.contains("swing") {
                2
            } else if p.service == state.spec.kind {
                3
            } else {
                4
            };
            (if reviewed { 0 } else { rank }, i, Control::Property(p))
        })
        .collect();
    for (i, a) in state.spec.actions.iter().enumerate().filter(|(_, a)| {
        a.inputs.is_empty() && (reviewed || !a.vendor_defined && daily(&a.service, &a.name))
    }) {
        candidates.push((0, state.spec.properties.len() + i, Control::Action(a)));
    }
    candidates.sort_by_key(|(rank, i, _)| (*rank, *i));
    let mut budget = if reviewed { usize::MAX } else { 10 };
    for (_, _, control) in candidates {
        match control {
            Control::Action(a) => {
                let key = format!("action:{}.{}", a.siid, a.aiid);
                if budget == 0 || b.consumed.contains(&key) {
                    continue;
                }
                let Some(s) = b.service(&key, "49", a.label()) else {
                    continue;
                };
                b.characteristic(
                    s,
                    &format!("{key}:on"),
                    "25",
                    "bool",
                    None,
                    Transform::Action(a.siid, a.aiid),
                    true,
                    None,
                );
                budget -= 1;
            }
            Control::Property(p) => {
                if b.consumed.contains(&p.key()) {
                    continue;
                }
                let mut switches = Vec::new();
                if p.format == "bool" {
                    switches.push(("toggle".into(), p.label().to_owned(), Transform::Direct));
                } else if !p.choices.is_empty() {
                    if p.name.contains("swing-included-angle") {
                        continue;
                    }
                    if let Some((off, on)) = off_on(p, state)
                        && !b.consumed.contains(&format!("{}={off}", p.key()))
                        && !b.consumed.contains(&format!("{}={on}", p.key()))
                    {
                        switches.push((
                            "toggle".into(),
                            p.label().to_owned(),
                            Transform::Toggle { off, on },
                        ));
                    } else {
                        let mut titles = BTreeSet::new();
                        for (index, c) in p.choices.iter().enumerate() {
                            let title = c.label(mijialan_core::localization::english());
                            let placeholder = !reviewed
                                && ["none", "null"].contains(
                                    &c.description_en
                                        .to_lowercase()
                                        .chars()
                                        .filter(|c| c.is_alphabetic())
                                        .collect::<String>()
                                        .as_str(),
                                );
                            if b.consumed.contains(&format!("{}={}", p.key(), c.value))
                                || placeholder
                                || !titles.insert(title)
                            {
                                continue;
                            }
                            switches.push((
                                format!("option:{index}"),
                                format!("{} · {title}", p.label()),
                                Transform::Option(c.value.clone()),
                            ));
                        }
                        if !reviewed && switches.len() > 6 {
                            continue;
                        }
                    }
                } else {
                    for value in presets(&state.device.model, p) {
                        switches.push((
                            format!("preset:{value}"),
                            format!("{} {}", p.label(), p.display(&value)),
                            Transform::Option(value),
                        ));
                    }
                }
                if switches.len() > budget {
                    continue;
                }
                budget -= switches.len();
                for (suffix, title, transform) in switches {
                    b.named(p, &suffix, &title, transform);
                }
            }
        }
    }
}

pub(super) fn bath_heater(b: &mut Builder<'_>, state: &DeviceState) -> bool {
    let find = |name: &str| {
        state
            .spec
            .properties
            .iter()
            .find(|p| p.service == "ptc-bath-heater" && p.name == name && p.readable)
    };
    let heating = find("heating").filter(|p| p.writable && p.format == "bool");
    let mode = find("mode").filter(|p| p.writable && !p.choices.is_empty());
    let target = find("target-temperature").filter(|p| {
        p.writable
            && p.range.is_some_and(|[lo, hi, step]| {
                lo.is_finite() && hi.is_finite() && lo <= hi && step.is_finite() && step > 0.
            })
    });
    let temperature = find("temperature")
        .or_else(|| {
            state
                .spec
                .properties
                .iter()
                .find(|p| p.service == "environment" && p.name == "temperature" && p.readable)
        })
        .or(target);
    let mode_values = mode.and_then(|m| Some((m, option(m, &["heat"])?, option(m, &["idle"])?)));
    let mut built = false;
    if let Some(temperature) = temperature
        && (heating.is_some() || mode_values.is_some())
    {
        let Some(s) = b.service("native", "BC", &state.device.name) else {
            return false;
        };
        b.primary(s);
        let (p, active, current) = if let Some(p) = heating {
            (p, Transform::Active, Transform::Working(2))
        } else {
            let (p, heat, idle) = mode_values.as_ref().unwrap();
            (
                *p,
                Transform::Mode {
                    selected: heat.clone(),
                    off: idle.clone(),
                    state: 1,
                },
                Transform::Mode {
                    selected: heat.clone(),
                    off: idle.clone(),
                    state: 2,
                },
            )
        };
        b.characteristic(
            s,
            "native:power",
            "B0",
            "uint8",
            Some(p),
            active,
            true,
            Some([0., 1., 1.]),
        );
        b.characteristic(
            s,
            "native:current",
            "B1",
            "uint8",
            Some(p),
            current,
            false,
            Some([0., 3., 1.]),
        );
        if heating.is_none()
            && let Some((p, heat, idle)) = &mode_values
        {
            b.consumed.remove(&p.key());
            for value in [heat, idle] {
                b.consumed.insert(format!("{}={value}", p.key()));
            }
        }
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
            "native:temperature",
            "11",
            "float",
            Some(temperature),
            Transform::Direct,
            false,
            Some([-40., 100., 0.1]),
        );
        if let Some(p) = target
            && p.range.is_some_and(|r| r[0] >= 0. && r[1] <= 38.)
        {
            b.characteristic(
                s,
                "native:heating",
                "12",
                "float",
                Some(p),
                Transform::Direct,
                true,
                p.range,
            );
        }
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
        child_lock(b, s);
        built = true;
    } else if let Some(p) = heating {
        let key = format!("{}:toggle", p.key());
        if let Some(s) = b.service(&key, "49", p.label()) {
            b.primary(s);
            b.characteristic(
                s,
                &format!("{key}:on"),
                "25",
                "bool",
                Some(p),
                Transform::Direct,
                true,
                None,
            );
            built = true;
        }
    }
    if let Some(on) = state.spec.properties.iter().find(|p| {
        p.service == "light" && p.name == "on" && p.format == "bool" && p.readable && p.writable
    }) && let Some(s) = b.service(&format!("light:{}", on.key()), "43", on.label())
    {
        if !built {
            b.primary(s);
        }
        b.characteristic(
            s,
            "bath:light:on",
            "25",
            "bool",
            Some(on),
            Transform::Direct,
            true,
            None,
        );
        if let Some(p) = state.spec.properties.iter().find(|p| {
            p.service == "light"
                && p.name == "brightness"
                && p.writable
                && p.range.is_some_and(|r| r[0] >= 0. && r[1] == 100.)
        }) {
            b.brightness(s, "bath:light:brightness", p, on);
        }
        built = true;
    }
    built
}
