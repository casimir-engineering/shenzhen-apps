//! `szfriends-helper`: the desktop helper for Windows and Linux (ADR 0015 § 3).
//!
//! - no argument: serve the person's Friends until the last app leaves (apps spawn it from their per-user copy);
//! - `--handover`: ask a running older helper to step aside for this build, wait for it to leave, exit (installers
//!   and an AppImage's first start, ADR 0015 § 14);
//! - `--version`: the version line.

// A release helper is a background process: no console window, even when an installer runs `--handover`.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::ExitCode;

use szfriends_helper::stamp;

fn main() -> ExitCode {
    // A panic ends the helper (release builds abort): its log says where, since a Windows helper has no console.
    std::panic::set_hook(Box::new(|info| szfriends_helper::log!("panic: {info}")));
    let own = stamp::own();
    let argument = std::env::args().nth(1);
    if argument.as_deref() == Some("--version") {
        let minor = szfriends_core::wire::consts::SESSION_MINOR;
        println!("szfriends-helper {} build {} (session 1.{minor}, client protocol 1.0)", own.version, own.build);
        return ExitCode::SUCCESS;
    }
    run(argument.as_deref(), &own)
}

#[cfg(any(target_os = "linux", windows))]
fn run(argument: Option<&str>, own: &stamp::Stamp) -> ExitCode {
    use szfriends_helper::client::{hand_over, Handover};
    use szfriends_helper::run::{policy_from_environment, serve, Outcome};
    use szfriends_helper::state::StateDir;

    let Some(state) = StateDir::from_environment() else {
        eprintln!("szfriends-helper: no state directory on this system");
        return ExitCode::from(69);
    };
    match argument {
        None => match serve(&state, presentation(&state), policy_from_environment()) {
            Ok(Outcome::AlreadyRunning | Outcome::Exited(_)) => ExitCode::SUCCESS,
            Err(error) => {
                szfriends_helper::log!("cannot serve: {error}");
                ExitCode::FAILURE
            }
        },
        Some("--handover") => match hand_over(&state, own) {
            Ok(Handover::NoHelper | Handover::NotNeeded | Handover::Done) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("szfriends-helper --handover: {error}");
                ExitCode::FAILURE
            }
        },
        Some(other) => {
            eprintln!("szfriends-helper: unknown argument {other:?} (--handover, --version)");
            ExitCode::from(64)
        }
    }
}

/// The Friends service for the person's state directory, which Reset Friends replaces with a new identity's; the
/// stub, which serves an empty badge, when the identity or the store cannot be opened (the log says why).
#[cfg(any(target_os = "linux", windows))]
fn presentation(
    state: &szfriends_helper::state::StateDir,
) -> std::sync::Arc<dyn szfriends_helper::presentation::Presentation> {
    use szfriends_helper::presentation::StubPresentation;
    use szfriends_helper::service::reset::Resettable;
    if let Err(error) = state.prepare() {
        szfriends_helper::log!("no state directory: {error}");
        return std::sync::Arc::new(StubPresentation::default());
    }
    let home = state.clone();
    let keys = std::sync::Arc::new(move || szfriends_helper::key_store(&home));
    Resettable::start(state.path.clone(), keys, state.received_defaults())
}

/// On a Mac the Objective-C helper serves Friends (ADR 0015 § 2); nothing Rust runs there as a helper.
#[cfg(not(any(target_os = "linux", windows)))]
fn run(_argument: Option<&str>, _own: &stamp::Stamp) -> ExitCode {
    eprintln!("szfriends-helper runs on Windows and Linux");
    ExitCode::from(69)
}
