//! What the check-in reports about this profile's Friends ID: its reservation, the release of the one a computer had
//! before joining a profile, and host attestations of Friends IDs (`SZFriendsCheckInClient+Attestation.m`,
//! `SZFriendsNearbyService+Attestation.m`; HOST-PROTOCOL.md § ID attestations): the one each reservation carries is
//! kept with the profile, shown beside our certificate when we answer someone's Add by ID, and the one an answer to
//! ours shows tells us the holder of the ID we asked for answered, so an accepted answer makes a friend at once
//! instead of a request to accept.

use szfriends_online::host::attestation::{judge_answer, Answer, Attestation, Verdict, MAX_BYTES};

use szfriends_core::store::{sync_log, unix_now};

use super::super::devices::PRE_JOIN_RELEASE;
use super::super::nearby::AnswerAttestation;
use super::super::State;
use crate::log;

impl State {
    /// The host reserved `id` for this person: the profile shows it from now on. Another ID than a reserved one shown
    /// before (a collision) keeps the old one as the previous ID, which the profile mentions until dismissed. The
    /// reservation's attestation, checked by the host connection already, is kept for that ID.
    pub(crate) fn friends_id_reserved(&mut self, id: &str, attestation: Option<Attestation>) {
        let conn = self.store.connection();
        let row: Option<(Option<String>, i64)> = conn
            .query_row("SELECT friends_id, friends_id_state FROM profile WHERE id = 1", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .ok();
        let (shown, state) = row.unwrap_or((None, 0));
        let changed = state != 0 && shown.as_deref().is_some_and(|s| s != id);
        let (state, previous) = if changed { (2, shown) } else { (1, None) };
        let written = conn.execute(
            "INSERT INTO profile (id, friends_id, friends_id_state) VALUES (1, ?1, ?2) ON CONFLICT(id) DO UPDATE SET \
             friends_id = ?1, friends_id_state = ?2, previous_friends_id = coalesce(?3, previous_friends_id)",
            rusqlite::params![id, state, previous],
        );
        if written.is_err() {
            return;
        }
        log!("online: the host reserved this profile's Friends ID");
        // An older host sends none: the one kept before stays, and is shown only while it covers this ID.
        if let Some(attestation) = attestation.filter(|a| a.friends_id == id) {
            if let Err(error) = self.store.save_friends_id_attestation(id, &attestation.encoded(), &attestation.day) {
                log!("online: could not keep the host's attestation: {error}");
            }
        }
        self.changed();
    }

    /// Our attestation to show when answering an Add by ID: only while it covers the ID the profile has now, names
    /// this computer's own key (a computer that joined a profile holds the person's ID, attested for the first
    /// computer's key, so it shows none) and still checks out.
    pub(crate) fn attestation_for_our_answer(&self) -> Option<Vec<u8>> {
        let attestation = Attestation::from_bytes(&self.store.friends_id_attestation()?)?;
        let own = self.identity.public_key();
        let list = &self.online.as_ref()?.list;
        let conn = self.store.connection();
        let id: String = conn.query_row("SELECT friends_id FROM profile WHERE id = 1", [], |r| r.get(0)).ok()?;
        let valid = attestation.check(list, &id, &own, unix_now()) == Verdict::Valid;
        let encoded = attestation.encoded();
        (valid && encoded.len() <= MAX_BYTES).then_some(encoded)
    }

    /// What the attestation `presented` on an answer from `key` to our Add by ID for `requested` says. Without a host
    /// list (online not set up), nothing can be checked, so every answer is unattested.
    pub(crate) fn judge_answer(
        &self,
        presented: Option<&[u8]>,
        requested: Option<&str>,
        key: &[u8; 32],
    ) -> AnswerAttestation {
        let (Some(online), Some(requested)) = (self.online.as_ref(), requested) else {
            return AnswerAttestation::Unattested;
        };
        match judge_answer(presented, &online.list, requested, key, unix_now()) {
            Answer::Unattested => AnswerAttestation::Unattested,
            Answer::Refused => AnswerAttestation::Refused,
            Answer::Attested(a) => {
                AnswerAttestation::Attested { friends_id: a.friends_id.clone(), encoded: a.encoded(), day: a.day }
            }
        }
    }

    /// A host answered the release of the ID this computer had before joining a profile; once one confirms it, it
    /// is owed no longer.
    pub(crate) fn pre_join_released(&mut self, released: bool) {
        log!("online: the ID from before joining: release {}", if released { "confirmed" } else { "not confirmed" });
        if !released {
            return;
        }
        let conn = self.store.connection();
        let _ = sync_log::set_state(conn, PRE_JOIN_RELEASE, rusqlite::types::Value::Null);
        if let Some(online) = self.online.as_ref() {
            online.directory.lock().unwrap_or_else(|e| e.into_inner()).release_owed = false;
        }
    }
}
