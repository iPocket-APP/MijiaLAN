use super::{HomeKit, Request};
use crate::{crypto, diagnostics::timestamp};
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::{Deserialize, Serialize};
use std::{
    collections::VecDeque,
    sync::Arc,
    time::{Duration, Instant, SystemTime},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HomeResult {
    Added,
    AlreadyInAnotherHome,
    OtherError,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupAttempt {
    pub started_at: String,
    pub was_running: bool,
    pub was_paired: bool,
    pub home_result: Option<HomeResult>,
    pub home_result_at: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Handshake {
    at: String,
    phase: &'static str,
    request_step: Option<u8>,
    response_step: Option<u8>,
    outcome: &'static str,
    protocol_error: Option<u8>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingDiagnostics {
    pub setup_attempt: Option<SetupAttempt>,
    recent_handshakes: VecDeque<Handshake>,
    accepted_connections: u64,
    active_connections: usize,
    connection_errors: u64,
    bonjour_announcements: u64,
    bonjour_errors: u64,
    bonjour_observation: Discovery,
    findings: Vec<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Discovery {
    outcome: &'static str,
    address_count: usize,
    port_matches: Option<bool>,
    flags_match: Option<bool>,
    configuration_number: Option<u16>,
    state_number: Option<u16>,
}

impl Discovery {
    fn new(outcome: &'static str) -> Self {
        Self {
            outcome,
            address_count: 0,
            port_matches: None,
            flags_match: None,
            configuration_number: None,
            state_number: None,
        }
    }
}

#[derive(Default)]
pub(super) struct Trace {
    attempt: Option<SetupAttempt>,
    recent: VecDeque<Handshake>,
    accepted_connections: u64,
    connection_errors: u64,
    bonjour_announcements: u64,
    bonjour_errors: u64,
}

pub(super) fn exchange(request: &Request) -> Option<(&'static str, Option<u8>)> {
    let phase = match (request.method.as_str(), request.target.as_str()) {
        ("POST", "/pair-setup") => "setup",
        ("POST", "/pair-verify") => "verify",
        _ => return None,
    };
    let step = crypto::parse(&request.body)
        .ok()
        .and_then(|fields| crypto::field(&fields, 6).ok()?.first().copied());
    Some((phase, step))
}

impl Trace {
    pub(super) fn handshake(
        &mut self,
        phase: &'static str,
        step: Option<u8>,
        response: Option<&[u8]>,
    ) {
        let fields = response.and_then(|response| {
            let end = response.windows(4).position(|bytes| bytes == b"\r\n\r\n")?;
            crypto::parse(&response[end + 4..]).ok()
        });
        let byte = |tag| {
            fields
                .as_ref()
                .and_then(|fields| crypto::field(fields, tag).ok()?.first().copied())
        };
        let error = byte(7);
        let response_step = byte(6);
        if self.recent.len() == 48 {
            self.recent.pop_front();
        }
        self.recent.push_back(Handshake {
            at: timestamp(SystemTime::now()),
            phase,
            request_step: step,
            response_step,
            outcome: if error.is_some() || response_step.is_none() {
                "rejected"
            } else if (phase == "setup" && response_step == Some(6))
                || (phase == "verify" && response_step == Some(4))
            {
                "completed"
            } else {
                "accepted"
            },
            protocol_error: error,
        });
    }

    pub(super) fn connection_accepted(&mut self) {
        self.accepted_connections += 1;
    }
    pub(super) fn connection_error(&mut self) {
        self.connection_errors += 1;
    }
    pub(super) fn advertised(&mut self) {
        self.bonjour_announcements += 1;
    }
    pub(super) fn advertisement_error(&mut self) {
        self.bonjour_errors += 1;
    }
    pub(super) fn clear_advertisement(&mut self) {
        self.bonjour_announcements = 0;
        self.bonjour_errors = 0;
    }
}

impl HomeKit {
    pub fn begin_setup_diagnostics(&self) {
        let info = self.info();
        self.trace.lock().unwrap().attempt = Some(SetupAttempt {
            started_at: timestamp(SystemTime::now()),
            was_running: info.running,
            was_paired: info.paired,
            home_result: None,
            home_result_at: None,
        });
    }

    pub fn setup_attempt(&self) -> Option<SetupAttempt> {
        self.trace.lock().unwrap().attempt.clone()
    }

    pub fn record_home_result(&self, result: HomeResult) {
        if let Some(attempt) = &mut self.trace.lock().unwrap().attempt {
            attempt.home_result = Some(result);
            attempt.home_result_at = Some(timestamp(SystemTime::now()));
        }
    }

    pub fn pairing_diagnostics(&self, browse: bool) -> PairingDiagnostics {
        let running = self.running.lock().unwrap().clone();
        let observation = match &running {
            Some(shared) if browse && shared.announced => {
                let (device_id, port, paired) = {
                    let identity = shared.identity.lock().unwrap();
                    (
                        identity.device_id.clone(),
                        identity.port,
                        !identity.pairings.is_empty(),
                    )
                };
                let observed = observe(&device_id, port, paired);
                if self
                    .running
                    .lock()
                    .unwrap()
                    .as_ref()
                    .is_some_and(|current| Arc::ptr_eq(shared, current))
                {
                    observed
                } else {
                    Discovery::new("listenerChanged")
                }
            }
            Some(shared) if shared.announced => Discovery::new("notChecked"),
            Some(_) => Discovery::new("disabled"),
            None => Discovery::new("stopped"),
        };
        let active = running
            .as_ref()
            .map_or(0, |shared| shared.connections.lock().unwrap().len());
        let trace = self.trace.lock().unwrap();
        let mut findings = Vec::new();
        match observation.outcome {
            "notFound" => findings.push("bonjourNotObserved"),
            "browseFailed" => findings.push("bonjourBrowseFailed"),
            _ if observation.port_matches == Some(false)
                || observation.flags_match == Some(false) =>
            {
                findings.push("bonjourRecordDoesNotMatchListener");
            }
            _ => {}
        }
        if let Some(attempt) = &trace.attempt {
            let mut steps = trace
                .recent
                .iter()
                .filter(|event| event.phase == "setup" && event.at >= attempt.started_at);
            if let Some(last) = steps.next_back() {
                match last.outcome {
                    "completed" => findings.push("pairSetupCompleted"),
                    "rejected" => findings.push("pairSetupRejected"),
                    _ => findings.push("pairSetupIncomplete"),
                }
            } else {
                findings.push("noPairSetupObserved");
            }
        }
        PairingDiagnostics {
            setup_attempt: trace.attempt.clone(),
            recent_handshakes: trace.recent.clone(),
            accepted_connections: trace.accepted_connections,
            active_connections: active,
            connection_errors: trace.connection_errors,
            bonjour_announcements: trace.bonjour_announcements,
            bonjour_errors: trace.bonjour_errors,
            bonjour_observation: observation,
            findings,
        }
    }
}

fn observe(device_id: &str, port: u16, paired: bool) -> Discovery {
    const KIND: &str = "_hap._tcp.local.";
    let Ok(daemon) = ServiceDaemon::new() else {
        return Discovery::new("browseFailed");
    };
    let result = (|| {
        let Ok(events) = daemon.browse(KIND) else {
            return Discovery::new("browseFailed");
        };
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut last_match = None;
        while let Ok(event) = events.recv_deadline(deadline) {
            if let ServiceEvent::ServiceResolved(service) = event
                && service.get_property_val_str("id") == Some(device_id)
            {
                let port_matches = service.get_port() == port;
                let flags_match =
                    service.get_property_val_str("sf") == Some(if paired { "0" } else { "1" });
                let result = Discovery {
                    outcome: "observed",
                    address_count: service.get_addresses().len(),
                    port_matches: Some(port_matches),
                    flags_match: Some(flags_match),
                    configuration_number: service
                        .get_property_val_str("c#")
                        .and_then(|value| value.parse().ok()),
                    state_number: service
                        .get_property_val_str("s#")
                        .and_then(|value| value.parse().ok()),
                };
                if port_matches && flags_match {
                    return result;
                }
                last_match = Some(result);
            }
            if Instant::now() >= deadline {
                break;
            }
        }
        last_match.unwrap_or_else(|| Discovery::new("notFound"))
    })();
    let _ = daemon.shutdown();
    result
}
