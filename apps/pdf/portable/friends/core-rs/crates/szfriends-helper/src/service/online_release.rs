//! Reset Friends at the host (ADR 0005 step 6; `SZFriendsHostCheckIn.m`, `-releaseIdentityWithCompletion:`): once
//! the old key has left the key store and before the store goes, the host forgets this identity and frees its
//! Friends ID, so another person can have it. Bounded: offline, or with every host down, the reset goes ahead
//! unconfirmed, as it does on a Mac.

use std::sync::mpsc::channel;
use std::time::Duration;

use szfriends_core::store::devices;
use szfriends_identity::chain::DeviceState;

use super::super::State;
use crate::log;

/// How long the hosts have to answer (the Mac helper's release timeout).
const RELEASE_TIMEOUT: f64 = 5.0;

impl State {
    /// Whether a host confirmed the release; `false` without a host connection, when the ID stays with the person's
    /// other computers, or when no host answered in time.
    pub(crate) fn release_identity_for_reset(&mut self) -> bool {
        let Some(routes) = &self.online else { return false };
        if self.id_is_shared() {
            log!("Reset Friends on the profile's first computer: its ID stays with the other computers");
            routes.online.links(|_, host| host.stop());
            return false;
        }
        let (reply, answer) = channel();
        routes.online.links(move |_, host| host.release_for_reset(RELEASE_TIMEOUT, reply));
        let released = answer.recv_timeout(Duration::from_secs_f64(RELEASE_TIMEOUT + 1.0)).unwrap_or(false);
        log!("identity release {}", if released { "confirmed" } else { "not confirmed" });
        released
    }

    /// The person's first computer while the profile has others: its key is the person's, and so is the ID the
    /// others check in with (HOST-PROTOCOL.md § Devices), so Reset Friends here must not free it.
    fn id_is_shared(&self) -> bool {
        let conn = self.store.connection();
        let local = self.identity.public_key();
        if devices::root_for_device(conn, &local).ok().flatten() != Some(local) {
            return false;
        }
        let others = devices::devices_of_root(conn, &local).unwrap_or_default();
        others.iter().any(|d| d.state == DeviceState::Authorized && d.device_key != local)
    }
}
