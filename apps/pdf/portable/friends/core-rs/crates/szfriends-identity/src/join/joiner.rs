//! The new computer's side (`SZFriendsJoiner.m`): its signed request, and one CPace run per session once the person
//! typed the code, ending with a chain that holds this computer, from the device that showed the code.

use std::collections::BTreeMap;

use szfriends_crypto::cpace::CPace;
use zeroize::Zeroizing;

use super::{
    approver_ad, channel_identifier, decode, encode, end_reason, field, key32, message_kind, normalized_code,
    request_message, tag, tags_equal, EndReason, Fields, MessageKind, INITIATOR_TAG_DOMAIN, RESPONDER_TAG_DOMAIN,
    WELCOME_TAG_DOMAIN,
};
use crate::chain::{device_consent, DeviceChain};
use crate::identity::Identity;

/// What one run on one session did with a message.
#[derive(Debug)]
pub enum Step {
    /// Send this, then wait for more.
    Send(Vec<u8>),
    /// A Part arrived; more follow.
    Wait,
    /// The chain (verified, authorizing this device) and the profile arrived.
    Joined {
        chain: DeviceChain,
        profile: Vec<u8>,
        friends_id_state: u8,
    },
    /// The other side's tag did not verify: a wrong code, or not the approving device.
    WrongCode,
    Ended(EndReason),
    /// Anything else: a malformed or out-of-order message, a chain that does not hold us.
    Failed,
}

#[derive(PartialEq)]
enum Phase {
    SentCode,
    Confirmed,
    Over,
}

/// One run of the code on one session.
pub struct Attempt {
    device_key: [u8; 32],
    static_key: [u8; 32],
    identity: std::sync::Arc<Identity>,
    cpace: CPace,
    phase: Phase,
    isk: Option<Zeroizing<[u8; 64]>>,
    root_key: [u8; 32],
    approver_key: [u8; 32],
    parts: BTreeMap<u8, Vec<u8>>,
    part_count: u8,
    code_message: Vec<u8>,
}

impl std::fmt::Debug for Attempt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Attempt")
    }
}

impl Attempt {
    /// Send first.
    pub fn code_message(&self) -> &[u8] {
        &self.code_message
    }

    fn over(&mut self, step: Step) -> Step {
        self.phase = Phase::Over;
        self.isk = None;
        step
    }

    pub fn receive(&mut self, message: &[u8]) -> Step {
        if self.phase == Phase::Over {
            return Step::Failed;
        }
        let kind = message_kind(message);
        if kind == Some(MessageKind::Ended) {
            self.phase = Phase::Over;
            return end_reason(message).map_or(Step::Failed, Step::Ended);
        }
        match (&self.phase, kind) {
            (Phase::SentCode, Some(MessageKind::Reply)) => self.receive_reply(message),
            (Phase::Confirmed, Some(MessageKind::Part)) => self.receive_part(message),
            _ => self.over(Step::Failed),
        }
    }

    fn receive_reply(&mut self, message: &[u8]) -> Step {
        let Some(fields) = decode(message, MessageKind::Reply) else { return self.over(Step::Failed) };
        let (approver, root) = (key32(&fields, field::APPROVER_KEY), key32(&fields, field::ROOT_KEY));
        if approver == self.device_key || root == self.device_key {
            return self.over(Step::Failed);
        }
        let isk = self.cpace.isk_as_initiator(&self.device_key, &fields[&field::SHARE], &approver_ad(&approver, &root));
        let Some(isk) = isk else { return self.over(Step::WrongCode) };
        if !tags_equal(&tag(isk.as_ref(), RESPONDER_TAG_DOMAIN, &[]), &fields[&field::TAG]) {
            return self.over(Step::WrongCode);
        }
        let consent = device_consent(&self.identity, &root);
        let confirm = Fields::from([
            (field::CONSENT, consent.to_vec()),
            (field::TAG, tag(isk.as_ref(), INITIATOR_TAG_DOMAIN, &consent).to_vec()),
        ]);
        let Some(confirm) = encode(MessageKind::Confirm, &confirm) else { return self.over(Step::Failed) };
        self.isk = Some(isk);
        self.root_key = root;
        self.approver_key = approver;
        self.phase = Phase::Confirmed;
        Step::Send(confirm)
    }

    fn receive_part(&mut self, message: &[u8]) -> Step {
        let Some(fields) = decode(message, MessageKind::Part) else { return self.over(Step::Failed) };
        let (index, count) = (fields[&field::PART_INDEX][0], fields[&field::PART_COUNT][0]);
        if (self.part_count != 0 && count != self.part_count) || index as usize != self.parts.len() || index >= count {
            return self.over(Step::Failed);
        }
        self.part_count = count;
        self.parts.insert(index, fields[&field::PART_DATA].clone());
        if self.parts.len() < count as usize {
            return Step::Wait;
        }
        let whole: Vec<u8> = self.parts.values().flatten().copied().collect();
        self.receive_welcome(&whole)
    }

    fn receive_welcome(&mut self, whole: &[u8]) -> Step {
        let Some(mut fields) = decode(whole, MessageKind::Welcome) else { return self.over(Step::Failed) };
        let received_tag = fields.insert(field::TAG, vec![0; 32]).expect("decoded");
        let Some(body) = encode(MessageKind::Welcome, &fields) else { return self.over(Step::Failed) };
        let isk = self.isk.as_ref().expect("confirmed");
        if !tags_equal(&tag(isk.as_ref(), WELCOME_TAG_DOMAIN, &body), &received_tag) {
            return self.over(Step::Failed);
        }
        let Ok(chain) = DeviceChain::decode(&fields[&field::CHAIN], Some(&self.root_key)) else {
            return self.over(Step::Failed);
        };
        let holds_us = chain.authorizes(&self.device_key)
            && chain.device(&self.device_key).is_some_and(|d| d.static_key == self.static_key);
        if !holds_us || !chain.authorizes(&self.approver_key) {
            return self.over(Step::Failed);
        }
        let profile = fields.remove(&field::PROFILE).expect("decoded");
        let friends_id_state = fields[&field::ID_STATE][0];
        self.over(Step::Joined { chain, profile, friends_id_state })
    }
}

/// The new computer's join: its request, and an attempt per session once the code is typed.
pub struct Joiner {
    identity: std::sync::Arc<Identity>,
    friends_id: String,
    name: String,
    system: String,
    request_id: [u8; 16],
}

impl std::fmt::Debug for Joiner {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Joiner").field("friends_id", &self.friends_id).finish_non_exhaustive()
    }
}

impl Joiner {
    /// `request_id` `None` draws one.
    pub fn new(
        identity: std::sync::Arc<Identity>,
        friends_id: &str,
        name: &str,
        system: &str,
        request_id: Option<[u8; 16]>,
    ) -> Self {
        let request_id = request_id.unwrap_or_else(|| {
            let mut id = [0u8; 16];
            szfriends_crypto::random_bytes(&mut id);
            id
        });
        Self {
            identity,
            friends_id: friends_id.to_owned(),
            name: name.to_owned(),
            system: system.to_owned(),
            request_id,
        }
    }

    pub fn request_id(&self) -> &[u8; 16] {
        &self.request_id
    }

    pub fn friends_id(&self) -> &str {
        &self.friends_id
    }

    pub fn request_message(&self, now: f64) -> Option<Vec<u8>> {
        request_message(&self.identity, &self.request_id, &self.friends_id, &self.name, &self.system, now)
    }

    /// `None` unless `code` is eight digits and the hash 64 bytes. `scalar` is for golden vectors.
    pub fn attempt(&self, code: &str, handshake_hash: &[u8], scalar: Option<[u8; 32]>) -> Option<Attempt> {
        let digits = normalized_code(code)?;
        if handshake_hash.len() != 64 {
            return None;
        }
        let device_key = self.identity.public_key();
        let static_key = self.identity.static_public_key();
        let ci = channel_identifier(&self.request_id, &device_key, &static_key);
        let cpace = CPace::new(digits.as_bytes(), &ci, handshake_hash, scalar)?;
        let code_message = encode(
            MessageKind::Code,
            &Fields::from([(field::REQUEST_ID, self.request_id.to_vec()), (field::SHARE, cpace.share().to_vec())]),
        )?;
        Some(Attempt {
            device_key,
            static_key,
            identity: self.identity.clone(),
            cpace,
            phase: Phase::SentCode,
            isk: None,
            root_key: [0; 32],
            approver_key: [0; 32],
            parts: BTreeMap::new(),
            part_count: 0,
            code_message,
        })
    }
}
