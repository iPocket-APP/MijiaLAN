//! Capability vocabulary and disambiguation shared by the panel and HomeKit.
use crate::{Specification, spec::urn_name};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::OnceLock,
};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Name {
    pub zh: String,
    pub en: String,
}
impl Name {
    pub fn get(&self, english: bool) -> &str {
        if english { &self.en } else { &self.zh }
    }
}
fn vocabulary() -> &'static Value {
    static WORDS: OnceLock<Value> = OnceLock::new();
    WORDS.get_or_init(|| {
        serde_json::from_str(include_str!("../../../resources/capability-names.json"))
            .expect("checked-in capability vocabulary")
    })
}
pub fn first_line(text: &str) -> Option<&str> {
    let line = text.lines().find(|line| !line.trim().is_empty())?.trim();
    (!line.eq_ignore_ascii_case("null")).then_some(line)
}
fn chinese(c: char) -> bool {
    ('\u{4e00}'..='\u{9fff}').contains(&c)
}
pub fn comment(text: &str) -> Option<String> {
    let mut name = first_line(text)?.to_owned();
    if let Some((i, _)) = name.char_indices().find(|(i, c)| {
        "（(【[：:，,。".contains(*c)
            || "；;".contains(*c) && {
                let rest = &name[i + c.len_utf8()..];
                rest.chars().all(char::is_whitespace)
                    || rest.chars().any(|c| c.is_numeric() || "：:".contains(c))
            }
    }) && name[..i].chars().any(char::is_alphabetic)
    {
        name.truncate(i);
    }
    if let Some((i, _)) = name
        .char_indices()
        .find(|(i, c)| *c == ' ' && name[..*i].chars().filter(|c| chinese(*c)).count() >= 2)
    {
        name.truncate(i);
    }
    let values: Vec<_> = name
        .char_indices()
        .filter(|(i, c)| {
            c.is_ascii_digit() && name[i + c.len_utf8()..].chars().next().is_some_and(chinese)
        })
        .map(|(i, _)| i)
        .collect();
    if values.len() >= 2
        && name[..values[0]].chars().count() >= 4
        && name[..values[0]].chars().all(chinese)
    {
        name.truncate(values[0]);
    }
    first_line(&name).map(str::to_owned)
}
fn generic(text: &str) -> bool {
    [
        "开关",
        "电源",
        "开关状态",
        "状态",
        "switch",
        "switch status",
        "status",
        "on",
        "power",
    ]
    .contains(&text.to_lowercase().as_str())
}
fn service_part(service: &str, description: &str, english: bool) -> Option<String> {
    let description = description.trim();
    let label = description.strip_suffix(" Service").unwrap_or(description);
    if english {
        return (!label.is_empty()).then(|| label.into());
    }
    let words: Vec<_> = description
        .split_whitespace()
        .map(str::to_lowercase)
        .collect();
    if words.get(1).is_some_and(|w| w == "switch") {
        let key = match words.first()?.as_str() {
            "left" => "左键",
            "middle" => "中键",
            "right" => "右键",
            "first" => "一键",
            "second" => "二键",
            "third" => "三键",
            "fourth" => "四键",
            _ => "",
        };
        if !key.is_empty() {
            return Some(format!(
                "{key}{}",
                if words.last().is_some_and(|w| w == "sensor") {
                    "按键"
                } else {
                    ""
                }
            ));
        }
    }
    let part = match description.to_lowercase().as_str() {
        "air fresh fan control" => "新风",
        "refrigerating chamber" => "冷藏室",
        "freezing chamber" => "冷冻室",
        "change chamber" => "变温室",
        "upper basket" => "上锅",
        "lower basket" => "下锅",
        "main cleaning brush" => "主",
        "side cleaning brush" => "边",
        "light top" => "上灯",
        "light bottom" => "下灯",
        "left curtain" => "左窗帘",
        "right curtain" => "右窗帘",
        "left induction cooker" => "左灶",
        "right induction cooker" => "右灶",
        "usb switch status" => "USB",
        _ => "",
    };
    if !part.is_empty() {
        return Some(part.into());
    }
    if let Some(kind) = label.strip_suffix(" Filter") {
        if !kind.is_empty()
            && kind
                .chars()
                .all(|c| c.is_uppercase() || c.is_numeric() || c == ' ')
        {
            return Some(kind.replace(' ', ""));
        }
        let part = match kind.to_lowercase().as_str() {
            "fresh air" => "新风",
            "formaldehyde removal" => "除醛",
            "humidify" => "加湿",
            "air purifier" => "净化",
            "ifd electrostatic" => "静电",
            "high efficiency" => "高效",
            "medium efficiency" => "中效",
            "composite" => "复合",
            "mosquito repellent" => "驱蚊",
            _ => "",
        };
        if !part.is_empty() {
            return Some(part.into());
        }
    }
    Some(
        match service {
            "light" => "照明",
            "night-light" => "夜灯",
            "ambient-light" => "氛围灯",
            "fan" => "风扇",
            "heater" => "加热",
            "air-fresh" => "新风",
            "air-conditioner" => "空调",
            "ice-maker" => "制冰",
            "sterilization" => "杀菌",
            "focus-mode" => "专注模式",
            "environment" => "环境",
            "electric-blanket" => "电热毯",
            "curtain" => "窗帘",
            "screen" => "屏幕",
            "indicator-light" => "指示灯",
            "clean" => "清洁",
            "descale" => "除垢",
            "maintenance" => "维护",
            "air-purifier-favorite" | "air-fresh-favorite" => "最爱",
            "water-use-details" => "用水",
            "ptc-bath-heater" => "浴霸",
            _ => return None,
        }
        .into(),
    )
}
fn property_title(service: &str, name: &str, fallback: &str, english: bool) -> String {
    let language = if english { "en" } else { "zh" };
    let pair = |zh: &str, en: &str| {
        if english {
            en.to_owned()
        } else {
            zh.to_owned()
        }
    };
    let words = vocabulary();
    let prefix = words["services"][service][language].as_str();
    if name == "on" {
        return prefix
            .map(str::to_owned)
            .unwrap_or_else(|| pair("电源", "Power"));
    }
    if name == "temperature" && ["switch", "on-off-count"].contains(&service) {
        return pair("设备温度", "Device Temperature");
    }
    if name == "mode" && service == "indicator-light" {
        return pair("指示灯勿扰模式", "Indicator Do Not Disturb");
    }
    if let Some(prefix) = prefix {
        let suffix = match name {
            "power" | "power-ext" => Some(pair("功率阈值", "Power Threshold")),
            "protect-time" => Some(pair("保护时长", "Protection Duration")),
            "duration" => Some(pair("时长", "Duration")),
            "start-time" => Some(pair("开始时间", "Start Time")),
            "end-time" => Some(pair("结束时间", "End Time")),
            _ => None,
        };
        if let Some(suffix) = suffix {
            return format!("{prefix}{}{suffix}", if english { " " } else { "" });
        }
    }
    if name == "brightness" {
        return match service {
            "light" => pair("亮度", "Brightness"),
            "indicator-light" => pair("指示灯亮度", "Indicator Brightness"),
            _ => pair("屏幕亮度", "Display Brightness"),
        };
    }
    words["properties"][name][language]
        .as_str()
        .unwrap_or(fallback)
        .into()
}
struct Row {
    id: String,
    siid: u32,
    name: String,
    title: String,
    specific: Option<String>,
}

/// Assign stable, unique labels using the same rules as the native capability catalog.
pub(crate) fn apply(spec: &mut Specification, document: &Value, reviewed: bool) {
    let mut labels: BTreeMap<String, Name> = BTreeMap::new();
    for english in [false, true] {
        let mut rows = Vec::new();
        let mut seen = BTreeSet::new();
        let mut qualifiers = BTreeMap::new();
        for service in document["services"].as_array().into_iter().flatten() {
            let Some(siid) = service["iid"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
                continue;
            };
            let kind = urn_name(&service["type"]);
            qualifiers.entry(siid).or_insert_with(|| {
                service_part(
                    &kind,
                    service["description"].as_str().unwrap_or(""),
                    english,
                )
            });
            for (items, action) in [("properties", false), ("actions", true)] {
                for raw in service[items].as_array().into_iter().flatten() {
                    // A malformed action declaration must not rename valid executable controls.
                    if action && !raw["in"].is_array() {
                        continue;
                    }
                    let Some(iid) = raw["iid"].as_u64().and_then(|n| u32::try_from(n).ok()) else {
                        continue;
                    };
                    let id = format!("{}:{siid}:{iid}", if action { "a" } else { "p" });
                    if !seen.insert(id.clone()) {
                        continue;
                    }
                    let name = urn_name(&raw["type"]);
                    let description =
                        first_line(raw["description"].as_str().unwrap_or(&name)).unwrap_or(&name);
                    let specific = comment(
                        raw[if english { "description" } else { "comment" }]
                            .as_str()
                            .unwrap_or(""),
                    );
                    let fallback = specific.as_deref().unwrap_or(description);
                    let mut title = if action {
                        crate::spec::action_label(&name, english)
                            .unwrap_or(fallback)
                            .to_owned()
                    } else {
                        property_title(&kind, &name, fallback, english)
                    };
                    let main = kind == spec.kind || spec.kind == "outlet" && kind == "switch";
                    if !action
                        && name == "on"
                        && !main
                        && title == if english { "Power" } else { "电源" }
                        && let Some(part) = specific
                            .as_ref()
                            .filter(|s| !generic(s))
                            .or_else(|| qualifiers.get(&siid).and_then(Option::as_ref))
                    {
                        title = part.clone();
                    }
                    rows.push(Row {
                        id,
                        siid,
                        name,
                        title,
                        specific,
                    });
                }
            }
        }
        fn repeated(rows: &[Row]) -> Vec<Vec<usize>> {
            let mut groups: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
            for (i, r) in rows.iter().enumerate() {
                if !r.title.is_empty() {
                    groups.entry(&r.title).or_default().push(i);
                }
            }
            groups.into_values().filter(|g| g.len() > 1).collect()
        }
        if !reviewed {
            for group in repeated(&rows) {
                let title = rows[group[0]].title.clone();
                let specific: Vec<_> = group
                    .iter()
                    .map(|i| {
                        rows[*i]
                            .specific
                            .clone()
                            .filter(|s| s != &title && !generic(s))
                    })
                    .collect();
                for (n, i) in group.iter().enumerate() {
                    if let Some(name) = &specific[n]
                        && specific.iter().filter(|s| *s == &specific[n]).count() == 1
                    {
                        rows[*i].title = name.clone();
                    }
                }
            }
            for group in repeated(&rows) {
                let parts: Vec<_> = group
                    .iter()
                    .map(|i| qualifiers.get(&rows[*i].siid).cloned().flatten())
                    .collect();
                let all = parts.iter().all(Option::is_some)
                    && parts.iter().collect::<BTreeSet<_>>().len() > 1;
                for (n, i) in group.iter().enumerate() {
                    let Some(part) = parts[n].as_deref() else {
                        continue;
                    };
                    if !all && !(n > 0 && parts[n] != parts[0]) {
                        continue;
                    }
                    let r = &mut rows[*i];
                    if r.name == "on" && r.title == if english { "Power" } else { "电源" } {
                        r.title = part.into();
                    } else if !r.title.starts_with(part) {
                        r.title = if english {
                            format!("{part} {}", r.title)
                        } else if let Some(rest) = r.title.strip_prefix("重置") {
                            format!("重置{part}{rest}")
                        } else {
                            format!("{part}{}", r.title)
                        };
                    }
                }
            }
        }
        let mut used: BTreeSet<_> = rows.iter().map(|r| r.title.clone()).collect();
        for group in repeated(&rows) {
            let title = rows[group[0]].title.clone();
            let mut suffix = 2;
            for i in group.into_iter().skip(1) {
                while used.contains(&format!("{title} {suffix}")) {
                    suffix += 1;
                }
                rows[i].title = format!("{title} {suffix}");
                used.insert(rows[i].title.clone());
                suffix += 1;
            }
        }
        for row in rows {
            let label = labels.entry(row.id).or_default();
            if english {
                label.en = row.title;
            } else {
                label.zh = row.title;
            }
        }
    }
    for p in &mut spec.properties {
        p.title = labels.get(&format!("p:{}:{}", p.siid, p.piid)).cloned();
    }
    for a in &mut spec.actions {
        a.title = labels.get(&format!("a:{}:{}", a.siid, a.aiid)).cloned();
        for p in &mut a.inputs {
            p.title = labels.get(&format!("p:{}:{}", p.siid, p.piid)).cloned();
        }
    }
    for c in &mut spec.compatibility {
        c.label = labels.get(&c.id).cloned();
    }
}
