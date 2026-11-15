use super::Shared;
use crate::mapping::{self, Binding, Database, Transform};
use serde_json::Value;
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{Arc, atomic::Ordering, mpsc},
};

type Address = (u64, u64);
type Completion = mpsc::Sender<Result<(), i32>>;

struct Write {
    id: u64,
    address: Address,
    binding: Binding,
    value: Value,
    completion: Option<Completion>,
}

fn can_coalesce(binding: &Binding, value: &Value) -> bool {
    match binding.transform {
        Transform::Brightness { .. } | Transform::FanSpeed { .. } | Transform::FanLevel { .. } => {
            // Zero turns the device off. Keep it in order with the following power-on write.
            value.as_f64().is_some_and(|value| value > 0.)
        }
        Transform::Direct | Transform::Mired | Transform::Percent => value.is_number(),
        _ => false,
    }
}

#[derive(Default)]
pub(super) struct Pending {
    next_id: u64,
    queues: BTreeMap<String, VecDeque<Write>>,
    visible_values: BTreeMap<Address, (u64, Value)>,
}

impl Shared {
    pub(super) fn read(&self, database: &Database, aid: u64, iid: u64) -> Result<Value, i32> {
        if database.bindings.contains_key(&(aid, iid))
            && let Some((_, value)) = self.writes.lock().unwrap().visible_values.get(&(aid, iid))
        {
            return Ok(value.clone());
        }
        database.read(&self.engine, aid, iid, false)
    }

    /// Actions return their outcome. Property writes can acknowledge once queued so Apple Home
    /// can continue a slider gesture while the device is still confirming the previous position.
    pub(super) fn accept_write(
        self: &Arc<Self>,
        address: Address,
        binding: Binding,
        value: Value,
    ) -> Result<Option<Value>, i32> {
        if !binding.writable {
            return Err(-70404);
        }
        let dimmed_off =
            matches!(binding.transform, Transform::Brightness { .. }) && value.as_f64() == Some(0.);
        let current = || {
            let database = self.database.read().unwrap();
            self.read(&database, address.0, address.1).ok()
        };
        let shown = || current().filter(|actual| dimmed_off || mapping::equivalent(actual, &value));
        if matches!(binding.transform, Transform::Fixed(_)) || self.engine.is_demo() {
            binding.write(&self.engine, &value)?;
            return Ok(shown());
        }
        if !self.engine.is_online(&binding.did) {
            return Err(-70402);
        }
        let synchronous = matches!(
            binding.transform,
            Transform::Action(..) | Transform::Cleaning { .. } | Transform::KettleMenu(_)
        );
        let (send, recv) = mpsc::channel();
        let optimistic = if synchronous || dimmed_off {
            None
        } else {
            Some(value.clone())
        };
        let did = binding.did.clone();
        {
            let mut pending = self.writes.lock().unwrap();
            if self.stop.load(Ordering::Relaxed) {
                return Err(-70402);
            }
            let start_worker = !pending.queues.contains_key(&did);
            let id = pending.next_id;
            pending.next_id = id.wrapping_add(1);
            let queue = pending.queues.entry(did.clone()).or_default();
            if can_coalesce(&binding, &value)
                && queue.back().is_some_and(|last| {
                    last.address == address
                        && last.completion.is_none()
                        && can_coalesce(&last.binding, &last.value)
                })
            {
                queue.pop_back();
            }
            if queue.len() >= 64 {
                return Err(-70403);
            }
            queue.push_back(Write {
                id,
                address,
                binding,
                value: value.clone(),
                completion: synchronous.then_some(send),
            });
            if let Some(value) = &optimistic {
                pending.visible_values.insert(address, (id, value.clone()));
            } else if dimmed_off {
                pending.visible_values.remove(&address);
            }
            if start_worker {
                let worker = self.clone();
                let device = did.clone();
                if std::thread::Builder::new()
                    .name("mijia-homekit-write".into())
                    .spawn(move || worker.settle_writes(&device))
                    .is_err()
                {
                    pending.queues.remove(&did);
                    pending.visible_values.remove(&address);
                    return Err(-70402);
                }
            }
        }
        if synchronous {
            recv.recv().map_err(|_| -70402)??;
            Ok(shown())
        } else if dimmed_off {
            Ok(current())
        } else {
            Ok(optimistic)
        }
    }

    fn settle_writes(&self, did: &str) {
        loop {
            let write = {
                let mut pending = self.writes.lock().unwrap();
                let queue = pending.queues.get_mut(did).unwrap();
                let Some(write) = queue.pop_front() else {
                    pending.queues.remove(did);
                    return;
                };
                write
            };
            let result = if self.stop.load(Ordering::Relaxed)
                || !self
                    .database
                    .read()
                    .unwrap()
                    .bindings
                    .contains_key(&write.address)
            {
                Err(-70402)
            } else {
                write.binding.write(&self.engine, &write.value)
            };
            let mut pending = self.writes.lock().unwrap();
            if pending
                .visible_values
                .get(&write.address)
                .is_some_and(|(id, _)| *id == write.id)
            {
                pending.visible_values.remove(&write.address);
            }
            drop(pending);
            if let Some(completion) = write.completion {
                let _ = completion.send(result);
            }
        }
    }
}
