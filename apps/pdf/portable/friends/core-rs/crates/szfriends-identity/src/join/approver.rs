//! The side of joining on the person's computers (`SZFriendsJoinApprover.m`): requests become rows, at most three at
//! once and six new ones an hour; Approve draws a code that lives 5 minutes and three attempts; a confirmed run signs
//! the add link. At three rows the newest request takes the place of the waiting row repeated least recently, without
//! counting as a new row; a row the person denied, or that another computer added meanwhile, gives its slot back.

use std::collections::HashMap;
use std::sync::Arc;

use szfriends_crypto::cpace::CPace;
use zeroize::Zeroizing;

use super::{
    approver_ad, channel_identifier, decode, encode, field, key32, new_code, tag, tags_equal, text, verified_request,
    EndReason, Fields, MessageKind, ATTEMPTS_MAX, CLOCK_SKEW_MAX, CODE_LIFETIME, INITIATOR_TAG_DOMAIN,
    NEW_REQUESTS_PER_HOUR, OPEN_REQUESTS_MAX, PART_MAX, REQUEST_LIFETIME, RESPONDER_TAG_DOMAIN, WELCOME_TAG_DOMAIN,
};
use crate::chain::{verify_device_consent, DeviceChain};
use crate::identity::Identity;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Receipt {
    /// Not for us, unverifiable, stale, our own or a device the chain knows.
    Ignored,
    Added,
    Refreshed,
    Limited,
    /// A request this device ended: answer with its reason's Ended message.
    Ended(EndReason),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestState {
    Waiting,
    Approved,
}

/// A request as one of the person's devices holds it.
#[derive(Clone, Debug, PartialEq)]
pub struct WaitingRequest {
    pub request_id: [u8; 16],
    pub device_key: [u8; 32],
    pub static_key: [u8; 32],
    pub name: String,
    pub system: String,
    pub friends_id: String,
    pub sent_at: f64,
    pub received_at: f64,
    pub state: RequestState,
    pub code: Option<String>,
    pub code_expires_at: Option<f64>,
    pub attempts: u32,
    last_heard_at: f64,
}

/// The approving device's side of one run, made from a Code message.
pub struct Approval {
    pub request_id: [u8; 16],
    /// Send at once.
    pub reply_message: Vec<u8>,
    isk: Option<Zeroizing<[u8; 64]>>,
    root_key: [u8; 32],
}

impl std::fmt::Debug for Approval {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Approval")
    }
}

/// What a correct Confirm produced: the chain to store first, then the Parts to send.
#[derive(Debug)]
pub struct Welcome {
    pub chain: DeviceChain,
    pub parts: Vec<Vec<u8>>,
}

struct Ending {
    reason: EndReason,
    until: f64,
}

pub struct Approver {
    device: Arc<Identity>,
    requests: HashMap<[u8; 16], WaitingRequest>,
    endings: HashMap<[u8; 16], Ending>,
    denied_devices: HashMap<[u8; 32], f64>,
    /// When each row of the last hour came, with a serial so a slot is found by identity.
    new_rows: Vec<(u64, f64)>,
    slots: HashMap<[u8; 16], u64>,
    next_slot: u64,
}

impl std::fmt::Debug for Approver {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Approver").field("requests", &self.requests.len()).finish_non_exhaustive()
    }
}

impl Approver {
    pub fn new(device: Arc<Identity>) -> Self {
        Self {
            device,
            requests: HashMap::new(),
            endings: HashMap::new(),
            denied_devices: HashMap::new(),
            new_rows: Vec::new(),
            slots: HashMap::new(),
            next_slot: 0,
        }
    }

    /// Reset Friends, or this device left the profile.
    pub fn forget_everything(&mut self) {
        *self = Self::new(self.device.clone());
    }

    fn free_slot(&mut self, key: &[u8; 16]) {
        if let Some(slot) = self.slots.remove(key) {
            self.new_rows.retain(|(serial, _)| *serial != slot);
        }
    }

    fn end(&mut self, key: [u8; 16], reason: EndReason, now: f64) {
        self.requests.remove(&key);
        self.endings.insert(key, Ending { reason, until: now + REQUEST_LIFETIME });
    }

    fn prune(&mut self, now: f64) {
        let keys: Vec<[u8; 16]> = self.requests.keys().copied().collect();
        for key in keys {
            let request = &self.requests[&key];
            if request.state == RequestState::Approved {
                if request.code_expires_at.is_some_and(|at| at <= now) {
                    self.end(key, EndReason::Expired, now);
                }
            } else if now - request.last_heard_at >= REQUEST_LIFETIME {
                self.requests.remove(&key);
            }
        }
        self.endings.retain(|_, ending| ending.until > now);
        self.denied_devices.retain(|_, until| *until > now);
        self.new_rows.retain(|(_, when)| !(now - when >= 3600.0 || when - now > 0.0));
    }

    /// A Request message for `own_friends_id`, judged against our chain.
    pub fn receive_request(
        &mut self,
        message: &[u8],
        own_friends_id: Option<&str>,
        chain: Option<&DeviceChain>,
        now: f64,
    ) -> Receipt {
        let Some(fields) = verified_request(message) else { return Receipt::Ignored };
        let Some(own) = own_friends_id.filter(|id| !id.is_empty()) else { return Receipt::Ignored };
        let millis = u64::from_be_bytes(fields[&field::TIME].as_slice().try_into().expect("8"));
        let incoming = WaitingRequest {
            request_id: fields[&field::REQUEST_ID].as_slice().try_into().expect("16"),
            device_key: key32(&fields, field::DEVICE_KEY),
            static_key: key32(&fields, field::STATIC_KEY),
            name: text(&fields, field::NAME),
            system: text(&fields, field::SYSTEM),
            friends_id: text(&fields, field::FRIENDS_ID),
            sent_at: millis as f64 / 1000.0,
            received_at: now,
            state: RequestState::Waiting,
            code: None,
            code_expires_at: None,
            attempts: 0,
            last_heard_at: now,
        };
        if incoming.friends_id != own || (incoming.sent_at - now).abs() > CLOCK_SKEW_MAX {
            return Receipt::Ignored;
        }
        let device_key = incoming.device_key;
        let known_device = chain.is_some_and(|c| c.authorizes(&device_key) || c.revokes(&device_key));
        if device_key == self.device.public_key() || known_device {
            return Receipt::Ignored;
        }
        self.prune(now);
        let key = incoming.request_id;
        let mut ended = self.endings.get(&key).map(|e| e.reason);
        if ended.is_none() && self.denied_devices.contains_key(&device_key) {
            ended = Some(EndReason::Denied);
        }
        if let Some(reason) = ended {
            return Receipt::Ended(reason);
        }
        if let Some(known) = self.requests.get_mut(&key) {
            if known.device_key != device_key || known.static_key != incoming.static_key {
                return Receipt::Ignored;
            }
            known.last_heard_at = now;
            return Receipt::Refreshed;
        }
        let same_device = self.requests.values().find(|o| o.device_key == device_key).map(|o| (o.request_id, o.state));
        if let Some((other, state)) = same_device {
            if state == RequestState::Approved {
                return Receipt::Ignored;
            }
            self.requests.remove(&other);
            self.requests.insert(key, incoming);
            if let Some(slot) = self.slots.remove(&other) {
                self.slots.insert(key, slot);
            }
            return Receipt::Added;
        }
        if self.requests.len() >= OPEN_REQUESTS_MAX {
            let mut stalest: Option<&WaitingRequest> = None;
            for other in self.requests.values().filter(|o| o.state == RequestState::Waiting) {
                let replace = match stalest {
                    None => true,
                    Some(s) => {
                        other.last_heard_at < s.last_heard_at
                            || (other.last_heard_at == s.last_heard_at && other.received_at < s.received_at)
                    }
                };
                if replace {
                    stalest = Some(other);
                }
            }
            let Some(stalest) = stalest.map(|s| s.request_id) else { return Receipt::Limited };
            self.requests.remove(&stalest);
            if let Some(slot) = self.slots.remove(&stalest) {
                self.slots.insert(key, slot);
            }
            self.requests.insert(key, incoming);
            return Receipt::Added;
        }
        if self.new_rows.len() >= NEW_REQUESTS_PER_HOUR {
            return Receipt::Limited;
        }
        self.requests.insert(key, incoming);
        let serial = self.next_slot;
        self.next_slot += 1;
        self.new_rows.push((serial, now));
        self.slots.insert(key, serial);
        Receipt::Added
    }

    /// Rows to show, oldest first: unexpired, not ended, and not a device `chain` already holds.
    pub fn open_requests(&mut self, chain: Option<&DeviceChain>, now: f64) -> Vec<WaitingRequest> {
        self.prune(now);
        let added: Vec<[u8; 16]> = self
            .requests
            .values()
            .filter(|r| chain.is_some_and(|c| c.authorizes(&r.device_key)))
            .map(|r| r.request_id)
            .collect();
        for key in added {
            self.requests.remove(&key);
            self.free_slot(&key);
        }
        let mut rows: Vec<WaitingRequest> = self.requests.values().cloned().collect();
        szfriends_wire::order::sort_by(&mut rows, |a, b| {
            a.received_at.total_cmp(&b.received_at).then(a.request_id.cmp(&b.request_id))
        });
        rows
    }

    /// When the rows may next change with no new message, or `None`.
    pub fn next_change_after(&self, now: f64) -> Option<f64> {
        self.requests
            .values()
            .filter_map(|r| match r.state {
                RequestState::Approved => r.code_expires_at,
                RequestState::Waiting => Some(r.last_heard_at + REQUEST_LIFETIME),
            })
            .filter(|when| *when > now)
            .min_by(f64::total_cmp)
    }

    /// Approve shows a fresh code; pressed again on an approved request, the same code.
    pub fn approve(&mut self, request_id: &[u8; 16], now: f64) -> Option<String> {
        self.prune(now);
        let request = self.requests.get_mut(request_id)?;
        if request.state == RequestState::Approved {
            return request.code.clone();
        }
        request.state = RequestState::Approved;
        request.code = Some(new_code());
        request.code_expires_at = Some(now + CODE_LIFETIME);
        request.attempts = 0;
        request.code.clone()
    }

    /// Approve with a given code: golden vectors and tests only.
    #[doc(hidden)]
    pub fn approve_with_code(&mut self, request_id: &[u8; 16], code: &str, now: f64) -> bool {
        let approved = self.approve(request_id, now).is_some();
        if let Some(request) = self.requests.get_mut(request_id) {
            request.code = Some(code.to_owned());
        }
        approved
    }

    pub fn deny(&mut self, request_id: &[u8; 16], now: f64) -> bool {
        self.prune(now);
        let Some(device_key) = self.requests.get(request_id).map(|r| r.device_key) else { return false };
        self.denied_devices.insert(device_key, now + REQUEST_LIFETIME);
        self.free_slot(request_id);
        self.end(*request_id, EndReason::Denied, now);
        true
    }

    /// A Code message on a session with `handshake_hash`. `Err(None)`: not a request approved here (answer as any
    /// device does); `Err(Some(reason))`: answer with its Ended message. Each Code counts one attempt.
    /// `scalar` is for golden vectors.
    pub fn approval(
        &mut self,
        message: &[u8],
        handshake_hash: &[u8],
        root_key: &[u8; 32],
        now: f64,
        scalar: Option<[u8; 32]>,
    ) -> Result<Approval, Option<EndReason>> {
        let fields = decode(message, MessageKind::Code).ok_or(None)?;
        if handshake_hash.len() != 64 {
            return Err(None);
        }
        self.prune(now);
        let key: [u8; 16] = fields[&field::REQUEST_ID].as_slice().try_into().expect("16");
        if let Some(ending) = self.endings.get(&key) {
            return Err(Some(ending.reason));
        }
        let Some(request) = self.requests.get_mut(&key).filter(|r| r.state == RequestState::Approved) else {
            return Err(None);
        };
        if request.attempts >= ATTEMPTS_MAX {
            self.end(key, EndReason::TooManyAttempts, now);
            return Err(Some(EndReason::TooManyAttempts));
        }
        request.attempts += 1;
        let ci = channel_identifier(&request.request_id, &request.device_key, &request.static_key);
        let code = request.code.clone().unwrap_or_default();
        let device_key = request.device_key;
        let own_key = self.device.public_key();
        let cpace = CPace::new(code.as_bytes(), &ci, handshake_hash, scalar);
        let isk = cpace
            .as_ref()
            .and_then(|c| c.isk_as_responder(&approver_ad(&own_key, root_key), &fields[&field::SHARE], &device_key));
        let reply = match (&cpace, &isk) {
            (Some(cpace), Some(isk)) => encode(
                MessageKind::Reply,
                &Fields::from([
                    (field::SHARE, cpace.share().to_vec()),
                    (field::APPROVER_KEY, own_key.to_vec()),
                    (field::ROOT_KEY, root_key.to_vec()),
                    (field::TAG, tag(isk.as_ref(), RESPONDER_TAG_DOMAIN, &[]).to_vec()),
                ]),
            ),
            _ => None,
        };
        let Some(reply_message) = reply else {
            self.failed_attempt(key, now);
            return Err(None);
        };
        Ok(Approval { request_id: key, reply_message, isk, root_key: *root_key })
    }

    fn failed_attempt(&mut self, key: [u8; 16], now: f64) {
        if self.requests.get(&key).is_some_and(|r| r.attempts >= ATTEMPTS_MAX) {
            self.end(key, EndReason::TooManyAttempts, now);
        }
    }

    /// The Confirm of `approval`: the add link on `chain`, signed by this device, and the welcome.
    pub fn welcome(
        &mut self,
        message: &[u8],
        approval: &mut Approval,
        chain: &DeviceChain,
        profile: &[u8],
        friends_id_state: i64,
        now: f64,
    ) -> Option<Welcome> {
        self.welcome_with(message, approval, chain, friends_id_state, now, |_| Some(profile.to_vec()))
    }

    /// As `welcome`, with the profile part made once the Confirm checked out, from the chain that holds the new
    /// device (the caller stores it first, then says what the profile held up to then); None from `profile` sends
    /// nothing.
    pub fn welcome_with(
        &mut self,
        message: &[u8],
        approval: &mut Approval,
        chain: &DeviceChain,
        friends_id_state: i64,
        now: f64,
        profile: impl FnOnce(&DeviceChain) -> Option<Vec<u8>>,
    ) -> Option<Welcome> {
        let isk = approval.isk.take();
        self.prune(now);
        let key = approval.request_id;
        let fields = decode(message, MessageKind::Confirm);
        let request = self.requests.get(&key).filter(|r| r.state == RequestState::Approved)?.clone();
        let isk = isk?;
        let consent = fields.as_ref().and_then(|f| f.get(&field::CONSENT)).cloned();
        let expected = consent.as_ref().map(|c| tag(isk.as_ref(), INITIATOR_TAG_DOMAIN, c));
        let received = fields.as_ref().and_then(|f| f.get(&field::TAG));
        let tag_ok = matches!((expected, received), (Some(e), Some(r)) if tags_equal(&e, r));
        let consent_ok = consent
            .as_ref()
            .is_some_and(|c| verify_device_consent(c, &request.device_key, &request.static_key, &approval.root_key));
        if !tag_ok || chain.root_key() != &approval.root_key || !consent_ok {
            self.failed_attempt(key, now);
            return None;
        }
        let consent: [u8; 64] = consent.expect("checked").as_slice().try_into().ok()?;
        let added = chain
            .adding(
                &request.device_key,
                &request.static_key,
                &consent,
                &request.name,
                &request.system,
                &self.device,
                now,
            )
            .ok()?;
        let profile = profile(&added)?;
        let parts = welcome_parts(&added, &profile, friends_id_state, isk.as_ref())?;
        Some(Welcome { chain: added, parts })
    }

    /// The session carrying `approval` ended before a Confirm: that attempt failed.
    pub fn abandon(&mut self, approval: &mut Approval, now: f64) {
        if approval.isk.take().is_some() {
            self.failed_attempt(approval.request_id, now);
        }
    }

    /// The welcome was stored and sent.
    pub fn finish(&mut self, request_id: &[u8; 16]) {
        self.requests.remove(request_id);
    }
}

/// The welcome, tagged over itself with a placeholder where the tag goes, cut into Parts.
pub fn welcome_parts(chain: &DeviceChain, profile: &[u8], state: i64, isk: &[u8]) -> Option<Vec<Vec<u8>>> {
    let mut fields = Fields::from([
        (field::CHAIN, chain.encoded().to_vec()),
        (field::PROFILE, profile.to_vec()),
        (field::ID_STATE, vec![state.clamp(0, 255) as u8]),
        (field::TAG, vec![0; 32]),
    ]);
    let body = encode(MessageKind::Welcome, &fields)?;
    fields.insert(field::TAG, tag(isk, WELCOME_TAG_DOMAIN, &body).to_vec());
    let whole = encode(MessageKind::Welcome, &fields)?;
    let count = whole.len().div_ceil(PART_MAX);
    if count == 0 || count > 255 {
        return None;
    }
    whole
        .chunks(PART_MAX)
        .enumerate()
        .map(|(i, data)| {
            encode(
                MessageKind::Part,
                &Fields::from([
                    (field::PART_INDEX, vec![i as u8]),
                    (field::PART_COUNT, vec![count as u8]),
                    (field::PART_DATA, data.to_vec()),
                ]),
            )
        })
        .collect()
}
