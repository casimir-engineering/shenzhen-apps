//! Applies the lifecycle policy to the running helper (PROTOCOL.md § Lifecycle, `SZFriendsHelperLifecycle.m`): it
//! feeds `szfriends-contract::lifecycle` the live facts on every event and at the next deadline, and runs the exit
//! sequence once: stop accepting, goodbyes, a short flush, then the presentation's shutdown.

use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::Arc;
use std::time::{Duration, Instant};

use szfriends_contract::handshake::GoodbyeReason;
use szfriends_contract::lifecycle::{ExitReason, LifecycleFacts, LifecyclePolicy};

use crate::events::SystemEvent;
use crate::log;
use crate::server::Server;
use crate::transport::Listener;

/// How long goodbyes get to reach clients before the helper exits anyway.
const GOODBYE_FLUSH: Duration = Duration::from_secs(1);

/// What wakes the lifecycle.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// A connection was accepted (`None`) or closed (whether it had sent `disable`).
    Connections {
        closed_after_disable: Option<bool>,
    },
    /// A client sent `disable`.
    Disable,
    /// A client asked for a handover that was granted.
    Handover,
    /// A signal, logout or system shutdown.
    Shutdown,
    System(SystemEvent),
}

/// Why the helper left.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Exit {
    Policy(ExitReason),
    Shutdown,
}

/// Runs until the helper should exit, then says goodbye and returns why.
pub fn run(server: &Server, listener: &Arc<dyn Listener>, events: &Receiver<Event>, policy: LifecyclePolicy) -> Exit {
    let started = Instant::now();
    let mut ever_had_client = false;
    let mut last_active = 0usize;
    let mut last_client_left: Option<Instant> = None;
    let mut last_drop_was_disable = false;
    let mut disabled_by_last_app = false;
    let mut handover_requested: Option<Instant> = None;
    let mut timeout: Option<Duration> = Some(Duration::ZERO);
    loop {
        let event = match timeout {
            Some(wait) => match events.recv_timeout(wait) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => Some(Event::Shutdown),
            },
            None => Some(events.recv().unwrap_or(Event::Shutdown)),
        };
        match event {
            Some(Event::Shutdown) => {
                log!("shutting down");
                finish(server, listener, Some(GoodbyeReason::Shutdown));
                return Exit::Shutdown;
            }
            Some(Event::Connections { closed_after_disable: Some(false) }) => last_drop_was_disable = false,
            Some(Event::Disable) => last_drop_was_disable = true,
            Some(Event::Handover) if handover_requested.is_none() => {
                handover_requested = Some(Instant::now());
                if let Some(successor) = server.successor() {
                    log!("handing over to build {}", successor.build_number);
                }
                // No new clients from now on; those connected stay until their goodbye.
                listener.stop();
            }
            Some(Event::System(system)) => {
                log!("system event: {system:?}");
                server.presentation().system_event(system);
            }
            _ => {}
        }
        let now = Instant::now();
        let active = server.active_clients();
        if active > 0 {
            ever_had_client = true;
            last_client_left = None;
            disabled_by_last_app = false;
        } else if last_active > 0 {
            last_client_left = Some(now);
            disabled_by_last_app = last_drop_was_disable;
        }
        last_active = active;
        let busy = handover_requested.is_some() && server.presentation().work_in_flight();
        let facts = LifecycleFacts {
            clients: active,
            since_start: now - started,
            ever_had_client,
            since_last_client_left: last_client_left.map(|t| now - t),
            disabled_by_last_app,
            since_handover_requested: handover_requested.map(|t| now - t),
            work_in_flight: busy,
        };
        match policy.exit_reason(&facts) {
            ExitReason::Stay => {
                // A small floor, so a deadline due "now" by rounding fires rather than spins.
                timeout = policy.next_evaluation(&facts).map(|d| d.max(Duration::from_millis(5)));
            }
            reason => {
                log!("exiting: {reason:?}");
                let goodbye = match reason {
                    ExitReason::Handover => Some(GoodbyeReason::Handover),
                    // The connections left turned Friends off; they are on their way out anyway.
                    ExitReason::Disabled => Some(GoodbyeReason::Shutdown),
                    _ => None,
                };
                finish(server, listener, goodbye);
                return Exit::Policy(reason);
            }
        }
    }
}

fn finish(server: &Server, listener: &Arc<dyn Listener>, goodbye: Option<GoodbyeReason>) {
    listener.stop();
    if let Some(reason) = goodbye {
        let successor = if reason == GoodbyeReason::Handover { server.successor() } else { None };
        server.broadcast_goodbye(reason, successor.as_ref());
    }
    let deadline = Instant::now() + GOODBYE_FLUSH;
    while server.connection_count() > 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    // Progress durable and sessions closed, so friends resume from where this helper stopped.
    server.presentation().shutdown();
}
