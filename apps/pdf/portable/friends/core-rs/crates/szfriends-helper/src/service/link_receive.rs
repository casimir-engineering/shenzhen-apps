//! receive_link in the Rust helper (`SZFriendsLinkReceiver` in `SZFriendsLinkOpening.m`,
//! `SZFriendsIntentRouter+Links.m`; PROTOCOL.md § Links): the link opened from this helper (`link_open`), and what
//! arrives filed on the service's thread. The sender's identity must sign what the file is, so it lands with the person
//! who made the link, never with whoever a name points at; someone blocked here gets nothing through a link either. The
//! sender gets a row of their own if they have none (a link contact, relation Removed until they are added), the file
//! is an accepted incoming transfer from the first byte, checked against the BLAKE2b the sender signed, and the history
//! then says it came through a link.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;

use serde_json::json;
use szfriends_core::presentation::facts::event as event_kind;
use szfriends_core::presentation::{Audience, SnapshotBuilder};
use szfriends_core::store::{new_identifier, unix_now, Person, Relation};
use szfriends_online::links::wire::Metadata;

use super::link_open::{self, LinkMetadata, Outcome, SinkEvent};
use super::{Input, State};
use crate::server::Reply;

const SENDER_DOMAIN: &str = "SZFriends link sender v1";
/// Bytes handed to the service's thread and not yet written: past this the opening waits, so a slow disk holds back
/// the sender's credit instead of filling memory.
const UNWRITTEN_MAX: usize = 8 << 20;

/// One link being received.
pub struct Receipt {
    link_id: [u8; 16],
    reply: Option<(Reply, Audience)>,
    abort: Arc<AtomicBool>,
    unwritten: Arc<AtomicUsize>,
    transfer: Option<(String, String, String)>,
}

impl std::fmt::Debug for Receipt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Receipt").field("transfer", &self.transfer.as_ref().map(|t| &t.0)).finish()
    }
}

fn error_code(outcome: Outcome) -> &'static str {
    match outcome {
        Outcome::Ended => "not_found",
        Outcome::Changed => "link_changed",
        Outcome::Failed | Outcome::Done => "link_failed",
        Outcome::Unavailable => "link_offline",
    }
}

/// Whether the sender's identity signed this metadata, and its key.
fn signed_sender(link_id: &[u8; 16], metadata: &LinkMetadata) -> Option<[u8; 32]> {
    let (key, friends_id, blake2b, signature) = metadata.from.as_ref()?;
    let texts = [metadata.name.as_str(), friends_id.as_str(), metadata.sender_name.as_str()];
    let signed = Metadata::signed_bytes(link_id, &metadata.sha256, blake2b, metadata.size, texts);
    szfriends_identity::identity::verify(signature, &signed, SENDER_DOMAIN, key).then_some(*key)
}

impl State {
    /// receive_link: answered once the sender's metadata arrived and the transfer is recorded, or with why not.
    pub(crate) fn receive_link(&mut self, link_id: [u8; 16], secret: [u8; 32], audience: Audience, reply: Reply) {
        let host = self.online.as_ref().filter(|o| o.is_available()).and_then(|o| o.guest_host());
        let Some(host) = host else {
            return reply.error("link_offline", None, json!({}));
        };
        self.next_receipt += 1;
        let id = self.next_receipt;
        let abort = Arc::new(AtomicBool::new(false));
        let unwritten = Arc::new(AtomicUsize::new(0));
        let input = std::sync::Mutex::new(self.input.clone());
        let (waiting, stopped) = (unwritten.clone(), abort.clone());
        let sink: link_open::Sink = Box::new(move |event| {
            if let SinkEvent::Bytes { data, .. } = &event {
                waiting.fetch_add(data.len(), Ordering::SeqCst);
            }
            let work = move |state: &mut State| state.link_arrived(id, event);
            let _ = input.lock().unwrap_or_else(|e| e.into_inner()).send(Input::Deferred(Box::new(work)));
            // On the opening's thread: it reads no more from the sender until the service caught up.
            while waiting.load(Ordering::SeqCst) > UNWRITTEN_MAX && !stopped.load(Ordering::SeqCst) {
                std::thread::sleep(std::time::Duration::from_millis(5));
            }
        });
        let receipt =
            Receipt { link_id, reply: Some((reply, audience)), abort: abort.clone(), unwritten, transfer: None };
        self.link_receipts.insert(id, receipt);
        if !link_open::spawn(link_id, secret, host, sink, abort) {
            self.link_arrived(id, SinkEvent::Stopped(Outcome::Failed));
        }
    }

    fn link_arrived(&mut self, id: u64, event: SinkEvent) {
        let Some(link_id) = self.link_receipts.get(&id).map(|r| r.link_id) else { return };
        if let SinkEvent::Metadata(metadata) = &event {
            let filed = self.file_link_metadata(&link_id, metadata);
            let Some(receipt) = self.link_receipts.get_mut(&id) else { return };
            match filed {
                Some(filed) => {
                    if let Some((reply, audience)) = receipt.reply.take() {
                        let builder = SnapshotBuilder::new(audience, None);
                        let sender = Some(metadata.sender_name.as_str()).filter(|s| !s.is_empty());
                        let message = builder.link_receiving_message(&filed.2, sender);
                        reply.ok(json!({ "conversation_id": filed.1, "message": message }));
                    }
                    receipt.transfer = Some(filed);
                }
                // Not signed by who sent it, sent by someone blocked here, or not recorded: nothing is kept.
                None => receipt.abort.store(true, Ordering::SeqCst),
            }
            self.changed();
            return;
        }
        let Some(receipt) = self.link_receipts.get_mut(&id) else { return };
        match event {
            SinkEvent::Metadata(_) => {}
            SinkEvent::Bytes { offset, data } => {
                receipt.unwritten.fetch_sub(data.len(), Ordering::SeqCst);
                let Some((transfer, conversation, _)) = receipt.transfer.clone() else { return };
                if self.store.append_chunk(&transfer, offset, &data, &conversation).is_err() {
                    receipt.abort.store(true, Ordering::SeqCst);
                }
            }
            SinkEvent::Finished => {
                let receipt = self.link_receipts.remove(&id);
                let Some((transfer, conversation, name)) = receipt.and_then(|r| r.transfer) else { return };
                let digest = self.store.transfer(&transfer).ok().flatten().map(|t| t.digest);
                let published =
                    digest.is_some_and(|d| self.store.finish_transfer(&transfer, &d, &conversation).is_ok());
                if published {
                    let arguments = json!({ "file": name });
                    let _ = self.store.record_event_with(&conversation, event_kind::RECEIVED_LINK_FILE, &arguments);
                }
            }
            SinkEvent::Stopped(outcome) => {
                let Some(mut receipt) = self.link_receipts.remove(&id) else { return };
                if let Some((reply, _)) = receipt.reply.take() {
                    reply.error(error_code(outcome), None, json!({ "field": "payload" }));
                }
                if let Some((transfer, _, _)) = &receipt.transfer {
                    let receiving = self
                        .store
                        .transfer(transfer)
                        .ok()
                        .flatten()
                        .is_some_and(|t| t.state == szfriends_core::store::TransferState::Receiving);
                    if receiving {
                        let _ = self.store.fail_received_transfer(transfer);
                    }
                }
            }
        }
        self.changed();
    }

    /// The sender's row (made when they have none) and the accepted transfer: (transfer id, conversation, file name).
    fn file_link_metadata(&mut self, link_id: &[u8; 16], metadata: &LinkMetadata) -> Option<(String, String, String)> {
        let key = signed_sender(link_id, metadata).filter(|k| *k != self.identity.public_key())?;
        let (_, friends_id, blake2b, _) = metadata.from.clone()?;
        let person = match self.store.person_with_identity_key(&key).ok().flatten() {
            Some(person) if person.relation == Relation::Blocked => return None,
            Some(person) => person,
            None => {
                let mut person = Person::new(Relation::Removed);
                person.identity_key = Some(key);
                person.friends_id = Some(friends_id).filter(|id| !id.is_empty());
                person.name = Some(metadata.sender_name.clone()).filter(|n| !n.is_empty());
                person.last_interaction_at = unix_now();
                self.store.save_person(&person).ok()?;
                self.store.mark_link_contact(&person.conversation_id).ok()?;
                person
            }
        };
        let transfer = new_identifier();
        // The file's kind comes from its name here, as for any received file.
        let record = self
            .store
            .record_link_transfer(&transfer, &person.conversation_id, &metadata.name, None, metadata.size, &blake2b)
            .ok()?;
        Some((transfer, person.conversation_id, record.file_name))
    }
}
