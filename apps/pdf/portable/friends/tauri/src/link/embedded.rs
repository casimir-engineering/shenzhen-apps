//! Embedded mode on phones: the core runs in the app's own process, on its own threads (ADR 0015 § 3), because a
//! phone neither shares a process between apps nor keeps one running in the background. The page still speaks the
//! same JSON frames, carried by an in-memory channel to the same protocol server the desktop helper runs, so the
//! bridge and the panel do not know the difference. Each app has its own state directory, so its own identity: a
//! device of the person's profile (§ 3). What runs behind the server, its key store and its lifecycle are
//! [`crate::phone`]'s.

use std::path::PathBuf;
use std::sync::mpsc::channel;
use std::sync::{Arc, OnceLock};

use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::PROTOCOL;
use szfriends_core::store::ReceivedDefaults;
use szfriends_helper::client::ClientConnection;
use szfriends_helper::server::Server;
use szfriends_helper::transport::{memory_pair, PeerInfo};

use super::{Connector, NotConnected};
use crate::phone::{Keys, PhoneNotify, PhoneService, GRACE};

pub struct EmbeddedConnector {
    state_dir: PathBuf,
    keys: Keys,
    /// Where received files go on this phone (`crate::phone::received`).
    received: ReceivedDefaults,
    /// The phone's notifier (`crate::phone::notify`), when the platform half answers.
    notify: Option<Arc<dyn PhoneNotify>>,
    /// Started on the first connection, which comes from the page's first `join()`, after its first paint.
    server: OnceLock<(Server, Arc<PhoneService>)>,
}

impl std::fmt::Debug for EmbeddedConnector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EmbeddedConnector").field("state_dir", &self.state_dir).finish()
    }
}

impl EmbeddedConnector {
    pub fn new(state_dir: PathBuf, keys: Keys, received: ReceivedDefaults) -> Self {
        Self { state_dir, keys, received, notify: None, server: OnceLock::new() }
    }

    /// With the phone's notifier, which every service this starts posts with.
    #[cfg_attr(not(any(target_os = "android", target_os = "ios")), allow(dead_code))]
    pub fn with_notify(mut self, notify: Arc<dyn PhoneNotify>) -> Self {
        self.notify = Some(notify);
        self
    }

    fn server(&self) -> &(Server, Arc<PhoneService>) {
        self.server.get_or_init(|| {
            let own = szfriends_helper::stamp::own();
            let facts = HelperFacts {
                version: own.version,
                build_number: own.build,
                protocol: PROTOCOL,
                pid: std::process::id(),
            };
            // No lifecycle here: the core lives as long as the app. Its events have no listener.
            let (events, _) = channel();
            let service = PhoneService::with_notify(
                self.state_dir.clone(),
                self.keys.clone(),
                self.received.clone(),
                GRACE,
                self.notify.clone(),
            );
            let server = Server::new(service.clone(), facts, events, Box::new(|_, _| false));
            (server, service)
        })
    }
}

impl Connector for EmbeddedConnector {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let (ours, theirs) = memory_pair();
        self.server().0.add(theirs, PeerInfo { pid: Some(std::process::id()), executable: None });
        Ok(ClientConnection::new(ours))
    }

    fn foreground(&self, in_front: bool) {
        let Some((_, service)) = self.server.get() else { return };
        if in_front {
            service.resumed();
        } else {
            service.suspended();
        }
    }
}
