//! Client mode on Windows and Linux: the Rust helper, one per person, shared by every app that hosts Friends
//! (ADR 0015 § 3). The app spawns it from the versioned per-user copy of the helper it carries (§ 14), never from
//! its own install; every check of the socket or pipe runs before a byte is sent (§ 8, `szfriends-helper`).

use std::path::PathBuf;
use std::time::Duration;

use szfriends_helper::client::{connect, connect_or_spawn, ClientConnection, ConnectError};
use szfriends_helper::copy::EmbeddedHelper;
use szfriends_helper::stamp::Stamp;
use szfriends_helper::state::StateDir;

use super::{Connector, NotConnected};

/// How long one connection attempt spawns and waits for a helper before the link backs off and tries again.
const PATIENCE: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub struct HelperConnector {
    state: StateDir,
    /// The helper this app carries; None never spawns (a helper another app started still serves).
    embedded: Option<EmbeddedHelper>,
}

impl HelperConnector {
    /// The person's Friends home, or `home` (a development or test run's own, `Config::state_dir`), and the helper
    /// binary at `helper` when it is one. `$SZFRIENDS_STATE_DIR` is never read here.
    pub fn new(helper: Option<PathBuf>, home: Option<PathBuf>) -> Option<Self> {
        let state = home.map(StateDir::new).or_else(StateDir::platform)?;
        let embedded = helper.and_then(|path| match EmbeddedHelper::inspect(&path) {
            Ok(embedded) => Some(embedded),
            Err(error) => {
                super::log(&format!("no helper at {}: {error}", path.display()));
                None
            }
        });
        Some(Self { state, embedded })
    }

    pub fn state_dir(&self) -> &std::path::Path {
        &self.state.path
    }
}

impl Connector for HelperConnector {
    fn connect(&self) -> Result<ClientConnection, NotConnected> {
        let connected = match &self.embedded {
            Some(embedded) => connect_or_spawn(&self.state, embedded, PATIENCE),
            None => connect(&self.state),
        };
        connected.map_err(|error| match error {
            ConnectError::NoHelper => NotConnected("no helper is running".into()),
            other => NotConnected(other.to_string()),
        })
    }

    fn embedded(&self) -> Option<Stamp> {
        self.embedded.as_ref().map(|e| e.stamp.clone())
    }
}
