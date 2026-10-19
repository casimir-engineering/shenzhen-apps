//! The stack's handles over the life of the process, and its end.
//!
//! libdatachannel keeps its handles in C++ globals and runs threads of its own (the worker pool, libjuice's, usrsctp's
//! timers). When a process exits, the C runtime destroys those globals; if a handle is still being released then, or
//! the threads still run, two threads free the same memory (a double free on glibc, an access violation on Windows).
//! So the end is ordered here:
//!
//! 1. every handle the Rust side holds is counted, from its creation until its `rtcDelete*` call has returned;
//! 2. [`shutdown`] refuses new connections, waits until the count is zero, stops the release thread and joins it,
//!    then calls `rtcCleanup`, which joins the stack's own threads;
//! 3. the first connection registers an `atexit` handler that runs [`shutdown`]. Handlers run in the reverse order of
//!    their registration, and the stack's globals registered theirs before the program started, so this one runs
//!    while they are all still intact.
//!
//! Owners that stop their work before the process ends (the online thread joins on stop) leave nothing to wait for.

use std::ffi::c_int;
use std::sync::mpsc::{self, Sender};
use std::sync::{Condvar, Mutex, MutexGuard, OnceLock};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::ffi;

/// How long the exit handler waits for handles still being released.
const EXIT_WAIT: Duration = Duration::from_secs(5);

#[derive(Debug, Default)]
struct Live {
    /// Connections and channels created and not yet deleted.
    count: usize,
    /// A connection was created since the last cleanup: the stack's threads may run.
    started: bool,
    /// [`shutdown`] ran: nothing new is created.
    closed: bool,
    exit_handler: bool,
}

fn cell() -> (&'static Mutex<Live>, &'static Condvar) {
    static LIVE: OnceLock<(Mutex<Live>, Condvar)> = OnceLock::new();
    let (live, changed) = LIVE.get_or_init(|| (Mutex::new(Live::default()), Condvar::new()));
    (live, changed)
}

fn lock() -> MutexGuard<'static, Live> {
    cell().0.lock().unwrap_or_else(|e| e.into_inner())
}

extern "C" {
    fn atexit(handler: extern "C" fn()) -> c_int;
}

extern "C" fn at_exit() {
    shutdown(EXIT_WAIT);
}

/// Counts a connection about to be created. `false` once the stack has been shut down.
pub(crate) fn connection_starting() -> bool {
    let mut live = lock();
    if live.closed {
        return false;
    }
    if !std::mem::replace(&mut live.exit_handler, true) {
        // SAFETY: `at_exit` is a plain function that lives as long as the process.
        unsafe { atexit(at_exit) };
    }
    live.started = true;
    live.count += 1;
    true
}

/// Counts a channel handle the stack gave out (created here, or opened by the remote).
pub(crate) fn handle_acquired() {
    lock().count += 1;
}

/// A handle's `rtcDelete*` call returned (or creation failed after [`connection_starting`]).
pub(crate) fn handle_released() {
    let mut live = lock();
    live.count = live.count.saturating_sub(1);
    if live.count == 0 {
        cell().1.notify_all();
    }
}

/// The handles created and not yet deleted, process-wide.
pub fn live_handles() -> usize {
    lock().count
}

/// Waits, at most `timeout`, until every handle has been deleted. `true` when none is left.
pub fn wait_released(timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    let mut live = lock();
    while live.count > 0 {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        live = cell().1.wait_timeout(live, left).unwrap_or_else(|e| e.into_inner()).0;
    }
    true
}

/// Ends the stack for the rest of the process: no connection is created afterwards, the handles still held are
/// waited for (at most `timeout`), the release thread is joined and the stack's own threads are stopped. Returns
/// whether every handle had been deleted. Runs by itself at exit; calling it earlier, or twice, is harmless.
pub fn shutdown(timeout: Duration) -> bool {
    lock().closed = true;
    let clean = wait_released(timeout);
    let started = std::mem::take(&mut lock().started);
    // Joined only when nothing is left to release: a thread still inside a deletion would hold the join forever.
    stop_reaper(clean);
    if started {
        // SAFETY: no handle is being used or created any more (or the wait gave up on the ones still held, which the
        // stack then deletes itself); the stack's threads stop before this returns, or after its own 10 s limit.
        unsafe { ffi::rtcCleanup() };
    }
    clean
}

// --- The release thread ---------------------------------------------------------------------------------------------

/// Something holding a handle, on its way to the release thread.
type Released = Box<dyn Send>;

#[derive(Default)]
struct Reaper {
    sender: Option<Sender<Released>>,
    thread: Option<JoinHandle<()>>,
    stopped: bool,
}

fn reaper() -> MutexGuard<'static, Reaper> {
    static REAPER: OnceLock<Mutex<Reaper>> = OnceLock::new();
    REAPER.get_or_init(|| Mutex::new(Reaper::default())).lock().unwrap_or_else(|e| e.into_inner())
}

/// Drops `item` on the release thread. Deleting a connection waits until its transports have stopped, and must never
/// run on one of the stack's threads (it can deadlock there) nor hold up its owner, so owners and callbacks hand their
/// handles here. After [`shutdown`] the item is kept instead: keeping a handle open is safe, releasing it late is not.
pub fn release_in_background<T: Send + 'static>(item: T) {
    let mut reaper = reaper();
    if reaper.sender.is_none() && !reaper.stopped {
        let (sender, items) = mpsc::channel::<Released>();
        let thread = std::thread::Builder::new().name("szfriends-datachannel-release".into());
        if let Ok(thread) = thread.spawn(move || items.into_iter().for_each(drop)) {
            reaper.sender = Some(sender);
            reaper.thread = Some(thread);
        }
    }
    let item: Released = Box::new(item);
    match reaper.sender.as_ref() {
        Some(sender) => {
            if let Err(mpsc::SendError(item)) = sender.send(item) {
                std::mem::forget(item);
            }
        }
        None => std::mem::forget(item),
    }
}

fn stop_reaper(join: bool) {
    let thread = {
        let mut reaper = reaper();
        reaper.stopped = true;
        reaper.sender = None;
        reaper.thread.take()
    };
    if let Some(thread) = thread.filter(|_| join) {
        let _ = thread.join();
    }
}
