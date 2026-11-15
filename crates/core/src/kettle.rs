//! The reviewed MIoT controls for the Xiaomi multifunction health kettle.
use crate::{DeviceState, Error, Result};
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub const MODEL: &str = "chunmi.health_pot.a1";
pub const STATUS: &str = "2.1";
pub const MENU_ID: &str = "5.1";
pub const RECIPE_TYPE: &str = "5.9";
pub(crate) const READINGS: [(u32, u32); 3] = [(2, 1), (5, 1), (5, 9)];

#[derive(Clone, Copy)]
pub struct Reading {
    status: u64,
    recipe_type: Option<u64>,
    menu: Option<u8>,
}

impl Reading {
    pub fn from_state(state: &DeviceState) -> Option<Self> {
        let value = |key: &str| {
            (!state.errors.contains_key(key))
                .then(|| state.values.get(key))
                .flatten()
                .and_then(Value::as_u64)
        };
        Self::new(value(STATUS), value(MENU_ID), value(RECIPE_TYPE))
    }

    pub(crate) fn from_values(values: &BTreeMap<String, Value>) -> Option<Self> {
        let value = |key: &str| values.get(key).and_then(Value::as_u64);
        Self::new(value(STATUS), value(MENU_ID), value(RECIPE_TYPE))
    }

    fn new(status: Option<u64>, id: Option<u64>, recipe_type: Option<u64>) -> Option<Self> {
        Some(Self {
            status: status.filter(|status| (1..=11).contains(status))?,
            recipe_type,
            menu: id
                .filter(|id| (1..=6).contains(id))
                .map(|id| (id - 1) as u8),
        })
    }

    pub fn active(self) -> bool {
        matches!(self.status, 2..=4 | 6..=8)
    }

    pub fn can_start(self) -> bool {
        matches!(self.status, 1 | 11)
    }

    pub fn stopped(self) -> bool {
        matches!(self.status, 1 | 5 | 11)
    }

    pub fn can_cancel(self) -> bool {
        self.active() || self.status == 9
    }

    pub fn active_menu(self) -> Option<u8> {
        (self.active() && self.recipe_type == Some(0))
            .then_some(self.menu)
            .flatten()
    }
}

#[derive(Clone, Copy)]
pub(crate) enum Command {
    Start(u8),
    Stop(Option<u8>),
}

impl Command {
    pub(crate) fn action(self) -> (u32, Vec<(u32, Value)>) {
        match self {
            Self::Start(menu) => (1, vec![(3, json!(menu))]),
            Self::Stop(_) => (2, vec![]),
        }
    }

    pub(crate) fn needed(self, reading: Reading) -> Result<bool> {
        match self {
            Self::Start(menu) if reading.active_menu() == Some(menu) => Ok(false),
            Self::Start(_) if reading.can_start() => Ok(true),
            Self::Start(_) => Err(Error::Validation("养生壶当前无法启动".into())),
            Self::Stop(Some(_))
                if !reading.active() || reading.recipe_type.is_some_and(|recipe| recipe != 0) =>
            {
                Ok(false)
            }
            Self::Stop(Some(menu)) => {
                let active = reading
                    .active_menu()
                    .ok_or_else(|| Error::Response("无法确认养生壶正在运行的菜单".into()))?;
                Ok(active == menu)
            }
            Self::Stop(None) => Ok(reading.can_cancel()),
        }
    }

    pub(crate) fn confirmed(self, reading: Reading) -> bool {
        match self {
            Self::Start(menu) => reading.active_menu() == Some(menu),
            Self::Stop(_) => reading.stopped(),
        }
    }
}
