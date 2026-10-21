//! Without the `online` feature (phone apps, until online fits their size budget): nothing reaches friends over the
//! Internet, and the service is nearby only. The same names as `online.rs`, so the rest of the service is unchanged.

use std::sync::mpsc::Sender;

use szfriends_core::identity::Identity;
use szfriends_core::store::Store;

use super::{Input, State};

pub const ENV_TEST_HOST_LIST: &str = "SZFRIENDS_TEST_HOST_LIST";
pub const ENV_TEST_HOST_KEYS: &str = "SZFRIENDS_TEST_HOST_KEYS";
pub const BLOCK_DIRECT_FILE: &str = "online-block-direct";

/// Never made: there is no online here.
#[derive(Debug)]
pub enum OnlineRoutes {}

impl OnlineRoutes {
    pub fn from_environment(_identity: &Identity, _store: &mut Store, _input: Sender<Input>) -> Option<Self> {
        None
    }

    pub fn network_changed(&self) {
        match *self {}
    }
}

impl State {
    pub(crate) fn reach_online(&mut self) {}

    /// No host holds this identity.
    pub(crate) fn release_identity_for_reset(&mut self) -> bool {
        false
    }

    /// No host connection, so no attestation of our own to show.
    pub(crate) fn attestation_for_our_answer(&self) -> Option<Vec<u8>> {
        None
    }

    /// No signed host list to check one against: every answer is unattested.
    pub(crate) fn judge_answer(
        &self,
        _presented: Option<&[u8]>,
        _requested: Option<&str>,
        _key: &[u8; 32],
    ) -> super::nearby::AnswerAttestation {
        super::nearby::AnswerAttestation::Unattested
    }
}
