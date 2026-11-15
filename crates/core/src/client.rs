use crate::packet::{self, Error, Result, Token};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    net::{Ipv4Addr, SocketAddrV4, UdpSocket},
    time::{Duration, Instant, SystemTime},
};

type PropertyId = (u32, u32);
const PROPERTIES_PER_REQUEST: usize = 15;
const USER_ACK_TIMEOUT: i64 = -9999;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PropertyFallback {
    pub requested: usize,
    pub rejected_batch_size: usize,
    pub single_attempts: usize,
    pub single_replies: usize,
}

#[derive(Clone, Debug)]
pub struct ClientDiagnostics {
    pub last_hello: Option<SystemTime>,
    pub last_authenticated_reply: Option<SystemTime>,
    pub batch_limit: usize,
    pub suppressed_properties: usize,
    pub read_backoff_seconds: u64,
    pub last_fallback: Option<PropertyFallback>,
}

#[derive(Default)]
pub(crate) struct PropertyBatch {
    pub items: Vec<Value>,
    pub failures: BTreeMap<PropertyId, String>,
}

/// Mutable ownership serializes requests to one device. Never execute this blocking client on the UI thread.
pub struct MiioClient {
    endpoint: SocketAddrV4,
    token: Token,
    timeout: Duration,
    clock: Option<(packet::Header, Instant)>,
    next_id: u32,
    last_hello: Option<SystemTime>,
    last_authenticated_reply: Option<SystemTime>,
    batch_limit: usize,
    unanswered: BTreeMap<PropertyId, Instant>,
    property_retry_at: Option<Instant>,
    last_fallback: Option<PropertyFallback>,
}

impl MiioClient {
    pub fn new(host: Ipv4Addr, token: Token) -> Self {
        Self::with_port(host, packet::PORT, token)
    }
    pub fn with_port(host: Ipv4Addr, port: u16, token: Token) -> Self {
        Self {
            endpoint: SocketAddrV4::new(host, port),
            token,
            timeout: Duration::from_secs(2),
            clock: None,
            next_id: 100,
            last_hello: None,
            last_authenticated_reply: None,
            batch_limit: PROPERTIES_PER_REQUEST,
            unanswered: BTreeMap::new(),
            property_retry_at: None,
            last_fallback: None,
        }
    }
    pub fn set_timeout(&mut self, timeout: Duration) {
        self.timeout = timeout;
    }

    pub fn diagnostics(&self) -> ClientDiagnostics {
        let now = Instant::now();
        ClientDiagnostics {
            last_hello: self.last_hello,
            last_authenticated_reply: self.last_authenticated_reply,
            batch_limit: self.batch_limit,
            suppressed_properties: self
                .unanswered
                .values()
                .filter(|until| **until > now)
                .count(),
            read_backoff_seconds: self
                .property_retry_at
                .map_or(0, |until| until.saturating_duration_since(now).as_secs()),
            last_fallback: self.last_fallback.clone(),
        }
    }

    pub(crate) fn reset_read_backoff(&mut self) {
        self.batch_limit = PROPERTIES_PER_REQUEST;
        self.unanswered.clear();
        self.property_retry_at = None;
    }

    fn socket(&self) -> Result<UdpSocket> {
        let socket = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
        socket.set_write_timeout(Some(self.timeout))?;
        socket.connect(self.endpoint)?;
        Ok(socket)
    }

    pub fn handshake(&mut self) -> Result<packet::Header> {
        let socket = self.socket()?;
        socket.send(&packet::HELLO)?;
        let deadline = Instant::now() + self.timeout;
        let mut buffer = [0u8; 65535];
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(Error::Timeout);
            }
            socket.set_read_timeout(Some(remaining))?;
            let len = socket.recv(&mut buffer).map_err(network_error)?;
            if len != packet::HEADER_LEN {
                continue;
            }
            if let Ok(header) = packet::header(&buffer[..len]) {
                if header.device_id == 0 || header.device_id == u32::MAX {
                    continue;
                }
                self.clock = Some((header, Instant::now()));
                self.last_hello = Some(SystemTime::now());
                return Ok(header);
            }
        }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        // Read retries are safe. Ambiguous writes/actions are surfaced rather than executed twice.
        let attempts = if matches!(
            method,
            "miIO.info" | "get_properties" | "get_prop" | "get_status"
        ) {
            2
        } else {
            1
        };
        self.call_with_attempts(method, params, attempts)
    }

    pub(crate) fn call_with_attempts(
        &mut self,
        method: &str,
        params: Value,
        attempts: usize,
    ) -> Result<Value> {
        let mut hello_answered = false;
        for attempt in 0..attempts {
            if self
                .clock
                .is_none_or(|(_, at)| at.elapsed() > Duration::from_secs(120))
            {
                self.handshake()?;
                hello_answered = true;
            }
            match self.send(method, params.clone()) {
                Err(Error::Timeout) => {
                    self.clock = None;
                    if attempt + 1 == attempts {
                        return Err(if hello_answered {
                            Error::NoEncryptedReply
                        } else {
                            Error::Timeout
                        });
                    }
                }
                result => return result,
            }
        }
        Err(Error::Timeout)
    }

    fn send(&mut self, method: &str, params: Value) -> Result<Value> {
        let (clock, at) = self.clock.ok_or(Error::Timeout)?;
        self.next_id = self.next_id % 9999 + 1;
        let id = self.next_id;
        let mut body = serde_json::to_vec(&json!({"id": id, "method": method, "params": params}))
            .map_err(|_| Error::Response("无法编码请求".into()))?;
        body.push(0);
        let stamp = clock
            .stamp
            .wrapping_add(at.elapsed().as_secs() as u32)
            .wrapping_add(1);
        let request = packet::encode(&body, &self.token, clock.device_id, stamp)?;
        let socket = self.socket()?;
        socket.send(&request)?;
        let deadline = Instant::now() + self.timeout;
        let mut buffer = [0u8; 65535];
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(Error::Timeout);
            }
            socket.set_read_timeout(Some(remaining))?;
            let length = socket.recv(&mut buffer).map_err(network_error)?;
            if length <= packet::HEADER_LEN {
                continue;
            }
            let (header, payload) = packet::decode(&buffer[..length], &self.token)?;
            if header.device_id != clock.device_id {
                continue;
            }
            let json = parse_json(&payload)?;
            if json["id"].as_u64() != Some(id as u64) {
                continue;
            }
            self.clock = Some((header, Instant::now()));
            self.last_authenticated_reply = Some(SystemTime::now());
            if let Some(error) = json.get("error") {
                return Err(Error::Device {
                    code: error["code"].as_i64().unwrap_or(-1),
                    message: error["message"].as_str().unwrap_or("未知设备错误").into(),
                });
            }
            return json
                .get("result")
                .cloned()
                .ok_or_else(|| Error::Response("响应缺少 result".into()));
        }
    }

    pub fn info(&mut self) -> Result<Value> {
        self.call("miIO.info", json!([]))
    }

    pub fn get_properties(&mut self, did: &str, properties: &[(u32, u32)]) -> Result<Vec<Value>> {
        Ok(self.read_properties(did, properties)?.items)
    }

    pub(crate) fn read_properties(
        &mut self,
        did: &str,
        properties: &[PropertyId],
    ) -> Result<PropertyBatch> {
        let mut batch = PropertyBatch::default();
        if properties.is_empty() {
            return Ok(batch);
        }
        let now = Instant::now();
        let backing_off = || Error::Response("属性读取正在退避，请稍后重试".into());
        if self.property_retry_at.is_some_and(|until| until > now) {
            return Err(backing_off());
        }
        self.property_retry_at = None;
        self.unanswered.retain(|_, until| *until > now);
        let mut requested = Vec::new();
        for &property in properties {
            if self.unanswered.contains_key(&property) {
                batch
                    .failures
                    .insert(property, "设备未应答此属性（-9999）".into());
            } else {
                requested.push(property);
            }
        }
        if requested.is_empty() {
            return Err(backing_off());
        }
        let mut fallback = None;
        let mut first_failure = None;
        let mut unanswered = Vec::new();
        let mut answered = false;
        let mut start = 0;
        while start < requested.len() {
            let end = (start + self.batch_limit).min(requested.len());
            let chunk = &requested[start..end];
            start = end;
            let error = match self.read_chunk(did, chunk, 2) {
                Ok(items) => {
                    answered = true;
                    batch.items.extend(items);
                    continue;
                }
                Err(error) => error,
            };
            let ack_timeout = matches!(
                error,
                Error::Device {
                    code: USER_ACK_TIMEOUT,
                    ..
                }
            );
            let transport_failure = matches!(
                error,
                Error::Timeout | Error::NoEncryptedReply | Error::Io(_) | Error::Checksum
            );
            for &property in chunk {
                batch.failures.insert(property, error.to_string());
            }
            first_failure.get_or_insert(error);
            if transport_failure {
                break;
            }
            if !ack_timeout {
                continue;
            }
            let (deadline, stats) = fallback.get_or_insert_with(|| {
                (
                    Instant::now() + Duration::from_millis(1500),
                    PropertyFallback {
                        requested: properties.len(),
                        rejected_batch_size: chunk.len(),
                        single_attempts: 0,
                        single_replies: 0,
                    },
                )
            });
            if let [property] = chunk {
                unanswered.push(*property);
                continue;
            }
            let original_timeout = self.timeout;
            let mut replies = 0;
            for &property in chunk {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() || stats.single_attempts >= PROPERTIES_PER_REQUEST {
                    break;
                }
                stats.single_attempts += 1;
                self.set_timeout(
                    original_timeout
                        .min(remaining)
                        .min(Duration::from_millis(300)),
                );
                match self.read_chunk(did, &[property], 1) {
                    Ok(items) => {
                        replies += 1;
                        stats.single_replies += 1;
                        answered = true;
                        batch.failures.remove(&property);
                        batch.items.extend(items);
                    }
                    Err(Error::Device {
                        code: USER_ACK_TIMEOUT,
                        ..
                    }) => unanswered.push(property),
                    Err(_) => break,
                }
            }
            self.timeout = original_timeout;
            if replies > 0 {
                self.batch_limit = self.batch_limit.min((chunk.len() / 2).max(1));
            }
        }
        if let Some((_, stats)) = fallback {
            self.last_fallback = Some(stats);
        }
        if answered {
            let deadline = Instant::now() + Duration::from_secs(600);
            self.unanswered
                .extend(unanswered.into_iter().map(|p| (p, deadline)));
            return Ok(batch);
        }
        let error = first_failure.unwrap_or_else(backing_off);
        if matches!(
            error,
            Error::Device {
                code: USER_ACK_TIMEOUT,
                ..
            }
        ) {
            self.property_retry_at = Some(Instant::now() + Duration::from_secs(60));
        }
        Err(error)
    }

    fn read_chunk(
        &mut self,
        did: &str,
        properties: &[PropertyId],
        attempts: usize,
    ) -> Result<Vec<Value>> {
        let params: Vec<_> = properties
            .iter()
            .map(|(siid, piid)| json!({"did": did, "siid": siid, "piid": piid}))
            .collect();
        let response = self.call_with_attempts("get_properties", json!(params), attempts)?;
        let Value::Array(mut items) = response else {
            return Err(Error::Response("属性结果不是数组".into()));
        };
        items.retain(|item| {
            let siid = item["siid"].as_u64().and_then(|id| u32::try_from(id).ok());
            let piid = item["piid"].as_u64().and_then(|id| u32::try_from(id).ok());
            siid.zip(piid).is_some_and(|id| properties.contains(&id))
        });
        Ok(items)
    }

    pub(crate) fn action(
        &mut self,
        did: &str,
        siid: u32,
        aiid: u32,
        inputs: &[(u32, Value)],
    ) -> Result<()> {
        let arguments: Vec<_> = inputs
            .iter()
            .map(|(piid, value)| json!({"piid":piid,"value":value}))
            .collect();
        let result = self.call(
            "action",
            json!({"did":did,"siid":siid,"aiid":aiid,"in":arguments}),
        )?;
        match result["code"].as_i64() {
            Some(0 | 1) => Ok(()),
            Some(code) => Err(Error::Device {
                code,
                message: "设备拒绝动作".into(),
            }),
            None => Err(Error::Response("动作响应缺少返回码".into())),
        }
    }

    pub fn set_property(&mut self, did: &str, siid: u32, piid: u32, value: Value) -> Result<()> {
        let response = self.call(
            "set_properties",
            json!([{"did": did, "siid": siid, "piid": piid, "value": value}]),
        )?;
        let items = response
            .as_array()
            .filter(|v| v.len() == 1)
            .ok_or_else(|| Error::Response("写入返回结果数量不符".into()))?;
        if items[0]["siid"].as_u64() != Some(siid as u64)
            || items[0]["piid"].as_u64() != Some(piid as u64)
        {
            return Err(Error::Response("写入结果与请求属性不匹配".into()));
        }
        match items[0]["code"].as_i64() {
            Some(0 | 1) => Ok(()),
            Some(code) => Err(Error::Device {
                code,
                message: "设备拒绝写入".into(),
            }),
            None => Err(Error::Response("写入响应缺少返回码".into())),
        }
    }
}

fn network_error(error: std::io::Error) -> Error {
    if matches!(
        error.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    ) {
        Error::Timeout
    } else {
        Error::Io(error)
    }
}

pub fn parse_json(payload: &[u8]) -> Result<Value> {
    let end = payload
        .iter()
        .position(|b| *b == 0)
        .unwrap_or(payload.len());
    let text = String::from_utf8_lossy(&payload[..end]);
    let repaired = text
        .replace(",,\"otu_stat\"", ",\"otu_stat\"")
        .replace("\"value\":00", "\"value\":0");
    let value: Value = serde_json::from_str(&text)
        .or_else(|_| serde_json::from_str(&repaired))
        .map_err(|_| Error::Response("设备返回了无效 JSON".into()))?;
    if !value.is_object() {
        return Err(Error::Response("设备响应不是对象".into()));
    }
    Ok(value)
}
