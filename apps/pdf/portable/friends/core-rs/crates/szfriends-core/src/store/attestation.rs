//! Host attestations of Friends IDs (schema v3; `SZFriendsStoreAttestation.m`): the host's signature over a Friends
//! ID, an identity key and a day, which turns "someone answered my Add by ID" into "the holder of that ID answered".
//! The helper checks signatures against the signed host list; the store keeps what was checked, bound to the ID it
//! covers, so a later change of the ID voids it without anyone having to remember to clear it.

use rusqlite::{params, OptionalExtension};

use super::{Result, Store, StoreError};

/// The column's bound (`SZFriendsAttestationMaxLength`).
pub const ATTESTATION_MAX_LENGTH: usize = 1024;

/// Shapes only; the signature is the helper's to check. A day is written as the host writes it.
fn shape_is_valid(friends_id: &str, attestation: &[u8], day: &str) -> bool {
    let day_shape = day.len() == 10
        && day.bytes().enumerate().all(|(i, c)| if i == 4 || i == 7 { c == b'-' } else { c.is_ascii_digit() });
    (1..=64).contains(&friends_id.len()) && (1..=ATTESTATION_MAX_LENGTH).contains(&attestation.len()) && day_shape
}

impl Store {
    /// The host's word that a person's `friends_id` is theirs: the row shows that ID from now on, above what their
    /// own PROFILE claimed. Refused for a row that has met nobody yet, which has no key an attestation could name.
    pub fn confirm_friends_id(
        &mut self,
        conversation: &str,
        friends_id: &str,
        attestation: &[u8],
        day: &str,
    ) -> Result<()> {
        if !shape_is_valid(friends_id, attestation, day) {
            return Err(StoreError::Invalid("malformed Friends ID attestation"));
        }
        self.write(|conn| {
            let key: Option<Option<Vec<u8>>> = conn
                .query_row("SELECT identity_pk FROM friends WHERE conversation_id = ?1", [conversation], |r| r.get(0))
                .optional()?;
            match key {
                None => return Err(StoreError::NotFound),
                Some(None) => return Err(StoreError::Invalid("no identity key yet")),
                Some(Some(_)) => {}
            }
            conn.execute(
                "UPDATE friends SET friends_id = ?1, attested_friends_id = ?1, id_attestation = ?2, \
                 id_attestation_day = ?3 WHERE conversation_id = ?4",
                params![friends_id, attestation, day, conversation],
            )?;
            Ok(())
        })
    }

    /// Keeps this profile's own attestation, only while `friends_id` is the ID it has now (checked in the same
    /// transaction, so a rename committed meanwhile cannot slip between them).
    pub fn save_friends_id_attestation(&mut self, friends_id: &str, attestation: &[u8], day: &str) -> Result<()> {
        if !shape_is_valid(friends_id, attestation, day) {
            return Err(StoreError::Invalid("malformed Friends ID attestation"));
        }
        self.write(|conn| {
            let changed = conn.execute(
                "UPDATE profile SET attested_friends_id = ?1, id_attestation = ?2, id_attestation_day = ?3 \
                 WHERE id = 1 AND friends_id = ?1",
                params![friends_id, attestation, day],
            )?;
            if changed == 0 {
                return Err(StoreError::Stale);
            }
            Ok(())
        })
    }

    /// This profile's attestation, only while it covers the ID the profile has now.
    pub fn friends_id_attestation(&self) -> Option<Vec<u8>> {
        self.connection()
            .query_row(
                "SELECT id_attestation FROM profile WHERE id = 1 AND attested_friends_id = friends_id \
                 AND id_attestation IS NOT NULL",
                [],
                |r| r.get(0),
            )
            .ok()
    }
}
