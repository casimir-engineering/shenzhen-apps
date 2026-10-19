//! The helper's start, in the Mac helper's order (`SZFriendsHelperMain.m`): the lock before anything else, so a
//! duplicate spawn costs nothing and never disturbs the running helper's files; the log; then listen and serve;
//! events last. The lock is released after the socket or pipe is gone, so a successor never listens beside it.

use std::io;
use std::sync::mpsc::channel;
use std::sync::Arc;

use szfriends_contract::handshake::HelperFacts;
use szfriends_contract::lifecycle::{LifecyclePolicy, PROTOCOL};

use crate::lifecycle::{self, Exit};
use crate::presentation::Presentation;
use crate::server::Server;
use crate::state::{StateDir, ENV_STATE_DIR};
use crate::transport::Listener;
use crate::{copy, events, log, stamp};

/// How a helper run ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Another helper holds the lock: this one never started (exit status 0).
    AlreadyRunning,
    Exited(Exit),
}

/// The lifecycle's timings, shortened by `$SZFRIENDS_HELPER_TIME_SCALE` (0.01 to 1) only while
/// `$SZFRIENDS_STATE_DIR` names a test directory, as the Mac helper does.
pub fn policy_from_environment() -> LifecyclePolicy {
    let mut policy = LifecyclePolicy::default();
    if std::env::var_os(ENV_STATE_DIR).is_none() {
        return policy;
    }
    let scale: f64 = std::env::var("SZFRIENDS_HELPER_TIME_SCALE").ok().and_then(|s| s.parse().ok()).unwrap_or(1.0);
    if scale > 0.0 {
        let scale = scale.clamp(0.01, 1.0);
        policy.grace = policy.grace.mul_f64(scale);
        policy.first_client = policy.first_client.mul_f64(scale);
        policy.handover_deadline = policy.handover_deadline.mul_f64(scale);
    }
    policy
}

/// Runs the helper for `state` until the lifecycle says to leave.
pub fn serve(state: &StateDir, presentation: Arc<dyn Presentation>, policy: LifecyclePolicy) -> io::Result<Outcome> {
    state.prepare()?;
    #[cfg(target_os = "linux")]
    let lock = crate::linux::ipc::acquire_lock(state)?;
    #[cfg(windows)]
    let lock = crate::windows::ipc::acquire_lock(state)?;
    // Dropped last (locals drop in reverse order): the lock outlives the socket or pipe.
    let Some(_lock) = lock else { return Ok(Outcome::AlreadyRunning) };
    log::open(&state.path);

    let own = stamp::own();
    let helper = HelperFacts {
        version: own.version.clone(),
        build_number: own.build,
        protocol: PROTOCOL,
        pid: std::process::id(),
    };
    let (sender, receiver) = channel();
    let backs = Box::new(|peer: &crate::transport::PeerInfo, build: u64| {
        peer.executable.as_deref().is_some_and(|exe| copy::executable_carries_build(exe, build))
    });
    let server = Server::new(presentation, helper, sender.clone(), backs);

    #[cfg(target_os = "linux")]
    let listener: Arc<dyn Listener> = {
        let path = crate::linux::ipc::helper_socket(state)?;
        Arc::new(crate::linux::ipc::SocketListener::bind(&path)?)
    };
    #[cfg(windows)]
    let listener: Arc<dyn Listener> = Arc::new(crate::windows::ipc::PipeServer::listen(state)?);

    copy::prune_stale_copies(state);
    let accept = server.serve(listener.clone());
    let _watchers = events::start(sender.clone());
    #[cfg(target_os = "linux")]
    watch_signals(sender.clone());
    log!("serving build {} ({})", own.build, own.version);

    let exit = lifecycle::run(&server, &listener, &receiver, policy);
    let _ = accept.join();
    Ok(Outcome::Exited(exit))
}

/// SIGTERM, SIGINT and SIGHUP (logout, shutdown) end the helper with goodbye `shutdown` rather than silently.
#[cfg(target_os = "linux")]
fn watch_signals(sender: std::sync::mpsc::Sender<lifecycle::Event>) {
    use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM};
    match signal_hook::iterator::Signals::new([SIGTERM, SIGINT, SIGHUP]) {
        Ok(mut signals) => {
            let _ = std::thread::Builder::new().name("szfriends-signals".into()).spawn(move || {
                if let Some(signal) = signals.forever().next() {
                    log!("signal {signal}");
                    let _ = sender.send(lifecycle::Event::Shutdown);
                }
            });
        }
        Err(error) => log!("signals not watched: {error}"),
    }
}
