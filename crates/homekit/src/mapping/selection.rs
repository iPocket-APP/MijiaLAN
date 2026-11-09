use super::{Layout, plan_device};
use mijialan_core::{DeviceState, Engine, Error, Result, localization, store::Config};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// One service the device can publish, including services the user has turned off.
pub struct HomeService {
    pub key: String,
    name: String,
    default_name: String,
    kind: String,
    primary: bool,
}

impl HomeService {
    pub fn advanced_for(&self, model: &str) -> bool {
        model == "cuco.plug.v3" && !self.primary && self.kind == "49"
    }

    pub fn title(&self) -> &str {
        if self.has_numbered_switch_name() {
            &self.default_name
        } else {
            &self.name
        }
    }

    pub fn detail(&self) -> String {
        let en = localization::english();
        let (chinese, english) = match self.kind.as_str() {
            "47" => ("插座", "Outlet"),
            "43" => ("灯", "Light"),
            "40" | "B7" => ("风扇", "Fan"),
            "BB" => ("空气净化器", "Air Purifier"),
            "BC" => ("冷暖控制", "Climate Control"),
            "BD" => ("加湿/除湿器", "Humidifier/Dehumidifier"),
            "8C" => ("窗帘", "Window Covering"),
            "49" => ("开关", "Switch"),
            "8A" => ("温度传感器", "Temperature Sensor"),
            "82" => ("湿度传感器", "Humidity Sensor"),
            "8D" => ("空气质量传感器", "Air Quality Sensor"),
            "BA" => ("滤芯", "Filter"),
            _ => ("其他", "Other"),
        };
        let kind = if en { english } else { chinese };
        if self.primary {
            let label = if en { "Main control" } else { "主控件" };
            format!("{label} · {kind}")
        } else if self.has_numbered_switch_name() {
            let label = if en {
                "Home name"
            } else {
                "「家庭」名称"
            };
            format!("{label} · {}", self.name)
        } else {
            kind.into()
        }
    }

    fn has_numbered_switch_name(&self) -> bool {
        self.kind == "49"
            && self.name != self.default_name
            && self
                .name
                .rsplit_once(char::is_whitespace)
                .is_some_and(|(prefix, number)| {
                    let prefix = prefix.trim_end();
                    (prefix.eq_ignore_ascii_case("switch") || prefix == "开关")
                        && !number.is_empty()
                        && number.bytes().all(|byte| byte.is_ascii_digit())
                })
    }
}

pub fn home_services(state: &DeviceState, names: &BTreeMap<String, String>) -> Vec<HomeService> {
    let mut layout = Layout::default();
    let plan = plan_device(state, &mut layout, names);
    let mut options: Vec<_> = plan
        .service_indices
        .into_iter()
        .map(|(key, index)| {
            let service = &plan.services[index];
            let title = |kind: &str| {
                service["characteristics"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|characteristic| characteristic["type"] == kind)
                    .and_then(|characteristic| characteristic["value"].as_str())
                    .unwrap_or(&state.device.name)
                    .to_owned()
            };
            let option = HomeService {
                key,
                name: title("E3"),
                default_name: title("23"),
                kind: service["type"].as_str().unwrap().into(),
                primary: service["primary"] == Value::Bool(true),
            };
            (index, option)
        })
        .collect();
    options.sort_by_key(|(index, option)| (!option.primary, *index));
    options.into_iter().map(|(_, option)| option).collect()
}

fn available(engine: &Engine, did: &str) -> Result<BTreeSet<String>> {
    let state = engine
        .state(did)
        .ok_or_else(|| Error::Validation("设备不存在".into()))?;
    Ok(
        plan_device(&state, &mut Layout::default(), &BTreeMap::new())
            .service_indices
            .into_keys()
            .collect(),
    )
}

fn restore_if_empty(config: &mut Config, did: &str, keys: &BTreeSet<String>) {
    if config
        .homekit_excluded_services
        .get(did)
        .is_some_and(|excluded| keys.is_subset(excluded))
    {
        config.homekit_excluded_services.remove(did);
    }
}

pub fn select_device(engine: &Engine, did: &str, selected: bool) -> Result<()> {
    let keys = if selected {
        available(engine, did)?
    } else {
        BTreeSet::new()
    };
    engine.update_bridge_selection(|config| {
        if selected && !keys.is_empty() {
            restore_if_empty(config, did, &keys);
        }
        if let Some(device) = config.devices.iter_mut().find(|d| d.did == did) {
            device.bridged = selected;
        }
    })
}

pub fn select_service(engine: &Engine, did: &str, key: &str, selected: bool) -> Result<()> {
    let keys = available(engine, did)?;
    if !keys.contains(key) {
        return Err(Error::Validation(
            "设备的家庭控件已变更，请重新选择。".into(),
        ));
    }
    engine.update_bridge_selection(|config| {
        let Some(device) = config
            .devices
            .iter_mut()
            .find(|d| d.did == did && d.bridged)
        else {
            return;
        };
        let excluded = config
            .homekit_excluded_services
            .entry(did.into())
            .or_default();
        if selected {
            excluded.remove(key);
        } else {
            excluded.insert(key.into());
            if keys.is_subset(excluded) {
                device.bridged = false;
            }
        }
        if excluded.is_empty() {
            config.homekit_excluded_services.remove(did);
        }
    })
}

#[cfg(target_os = "linux")]
pub fn select_devices(
    engine: &Engine,
    selected: &BTreeSet<String>,
    services: &BTreeMap<String, BTreeSet<String>>,
) -> Result<()> {
    let mut plans = BTreeMap::new();
    for did in selected
        .iter()
        .chain(services.keys().filter(|did| !selected.contains(*did)))
    {
        let keys = available(engine, did)?;
        if keys.is_empty()
            || services.get(did).is_some_and(|chosen| {
                (selected.contains(did) && chosen.is_empty()) || !chosen.is_subset(&keys)
            })
        {
            return Err(Error::Validation(
                "设备的家庭控件已变更，请重新选择。".into(),
            ));
        }
        plans.insert(did, keys);
    }
    engine.update_bridge_selection(|config| {
        for device in &mut config.devices {
            device.bridged = selected.contains(&device.did);
        }
        for (did, keys) in plans {
            if let Some(chosen) = services.get(did) {
                let excluded = config
                    .homekit_excluded_services
                    .entry(did.clone())
                    .or_default();
                excluded.retain(|key| !keys.contains(key));
                excluded.extend(keys.difference(chosen).cloned());
                if excluded.is_empty() {
                    config.homekit_excluded_services.remove(did);
                }
            } else {
                restore_if_empty(config, did, &keys);
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plug_options_group_extra_switches_and_explain_numbered_home_names() {
        let engine = Engine::demo_control_center();
        let plug = engine.state("10").unwrap();
        let options = home_services(&plug, &BTreeMap::new());
        assert!(options[0].primary);
        assert!(
            options
                .iter()
                .any(|option| option.kind == "8A" && !option.advanced_for(&plug.device.model))
        );
        let advanced = options
            .iter()
            .find(|option| option.advanced_for(&plug.device.model))
            .unwrap();
        let names = [(format!("10:{}", advanced.key), "Switch 14".into())].into();
        let options = home_services(&plug, &names);
        let renamed = options
            .iter()
            .find(|option| option.key == advanced.key)
            .unwrap();
        assert_eq!(renamed.title(), advanced.title());
        assert!(renamed.detail().contains("Switch 14"));
    }
}
