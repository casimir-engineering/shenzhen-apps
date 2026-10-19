//! Peer connections and data channels, and how the stack's callbacks reach them.
//!
//! Lifetimes: a [`DataChannel`] keeps its connection's handle, so the stack's peer connection is deleted only after
//! the [`PeerConnection`] and every channel of it have been dropped; no channel handle outlives the connection it
//! belongs to. Dropping the `PeerConnection` still closes it, and its channels, and stops its events at once.
//!
//! Threads: the stack calls back on its own threads, and releasing a channel or a connection from inside one of its
//! callbacks can deadlock it. So a callback never releases a handle. What it cannot hand to a receiver (a channel the
//! remote opened after the receiver, or the connection, was dropped) goes to the release thread (`lifetime.rs`).
//!
//! Callbacks find their receiver through a registry keyed by a number, never through a pointer, so a callback that
//! races a drop finds nothing instead of freed memory.

use std::collections::HashMap;
use std::ffi::{c_char, c_int, c_void, CStr};
use std::fmt;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use crate::lifetime::{self, release_in_background};
use crate::{c_string, check, copy_str, ffi, Config, Error, Event, State};

// --- Registry: from a callback's user pointer (a number) to the connection's event sender. ----------------------

#[derive(Clone)]
struct Entry {
    events: Sender<Event>,
    connection: Weak<Handle>,
}

fn registry() -> &'static Mutex<HashMap<usize, Entry>> {
    static REGISTRY: OnceLock<Mutex<HashMap<usize, Entry>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lookup(ptr: *mut c_void) -> Option<Entry> {
    registry().lock().unwrap_or_else(|e| e.into_inner()).get(&(ptr as usize)).cloned()
}

/// A channel the remote opened when nobody was left to take it.
struct Orphan(c_int);

impl Drop for Orphan {
    fn drop(&mut self) {
        // SAFETY: the stack gave this handle to `on_data_channel` and nothing else holds it; released once, here.
        unsafe { ffi::rtcDeleteDataChannel(self.0) };
        lifetime::handle_released();
    }
}

fn deliver(ptr: *mut c_void, event: Event) {
    if let Some(entry) = lookup(ptr) {
        // A dropped receiver means nobody listens; these events hold no handle, so dropping one here is harmless.
        let _ = entry.events.send(event);
    }
}

extern "C" fn on_description(_pc: c_int, sdp: *const c_char, kind: *const c_char, ptr: *mut c_void) {
    deliver(ptr, Event::LocalDescription { sdp: copy_str(sdp), kind: copy_str(kind) });
}

extern "C" fn on_candidate(_pc: c_int, cand: *const c_char, mid: *const c_char, ptr: *mut c_void) {
    let candidate = copy_str(cand);
    let candidate = candidate.strip_prefix("a=").map(str::to_owned).unwrap_or(candidate);
    deliver(ptr, Event::LocalCandidate { candidate, mid: copy_str(mid) });
}

extern "C" fn on_state(_pc: c_int, state: ffi::rtcState, ptr: *mut c_void) {
    deliver(ptr, Event::StateChanged(State::from_raw(state)));
}

extern "C" fn on_gathering(_pc: c_int, state: ffi::rtcGatheringState, ptr: *mut c_void) {
    if state == ffi::RTC_GATHERING_COMPLETE {
        deliver(ptr, Event::GatheringComplete);
    }
}

extern "C" fn on_data_channel(_pc: c_int, dc: c_int, ptr: *mut c_void) {
    lifetime::handle_acquired();
    let Some((events, connection)) = lookup(ptr).and_then(|e| e.connection.upgrade().map(|c| (e.events, c))) else {
        release_in_background(Box::new(Orphan(dc)));
        return;
    };
    // Installed before the event leaves, so no message can arrive unheard (the stack holds them until then).
    install_channel_callbacks(dc, ptr);
    if let Err(mpsc::SendError(event)) = events.send(Event::DataChannel(DataChannel { id: dc, connection })) {
        release_in_background(Box::new(event));
    }
}

extern "C" fn on_open(id: c_int, ptr: *mut c_void) {
    deliver(ptr, Event::ChannelOpen(id));
}

extern "C" fn on_closed(id: c_int, ptr: *mut c_void) {
    deliver(ptr, Event::ChannelClosed(id));
}

extern "C" fn on_error(id: c_int, error: *const c_char, ptr: *mut c_void) {
    deliver(ptr, Event::ChannelError { channel: id, error: copy_str(error) });
}

extern "C" fn on_message(id: c_int, message: *const c_char, size: c_int, ptr: *mut c_void) {
    let (data, text) = if size < 0 {
        (copy_str(message).into_bytes(), true)
    } else if message.is_null() || size == 0 {
        (Vec::new(), false)
    } else {
        // SAFETY: for a binary message the stack passes `size` readable bytes, valid during the callback.
        (unsafe { std::slice::from_raw_parts(message.cast::<u8>(), size as usize) }.to_vec(), false)
    };
    deliver(ptr, Event::Message { channel: id, data, text });
}

fn install_channel_callbacks(dc: c_int, ptr: *mut c_void) {
    // SAFETY: `dc` is a live channel handle; the user pointer is only ever read back as a registry key.
    unsafe {
        ffi::rtcSetUserPointer(dc, ptr);
        ffi::rtcSetOpenCallback(dc, Some(on_open));
        ffi::rtcSetClosedCallback(dc, Some(on_closed));
        ffi::rtcSetErrorCallback(dc, Some(on_error));
        ffi::rtcSetMessageCallback(dc, Some(on_message));
    }
}

// --- Peer connections and data channels ---------------------------------------------------------------------------

/// The stack's peer connection handle, shared by the [`PeerConnection`] and its channels; deleted with the last.
struct Handle {
    id: c_int,
}

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: the handle is live until this call, which releases it once every channel of it has been released.
        unsafe { ffi::rtcDeletePeerConnection(self.id) };
        lifetime::handle_released();
    }
}

/// One libdatachannel peer connection. Dropping it closes it and every channel it opened; events stop.
pub struct PeerConnection {
    handle: Arc<Handle>,
    key: usize,
}

impl fmt::Debug for PeerConnection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PeerConnection").field("id", &self.handle.id).finish()
    }
}

impl PeerConnection {
    /// Creates a peer connection and the receiver of its events. Nothing is gathered until a description exists:
    /// an offerer creates a data channel (which creates the offer), an answerer applies the remote offer.
    pub fn new(config: &Config) -> Result<(PeerConnection, Receiver<Event>), Error> {
        static NEXT_KEY: AtomicUsize = AtomicUsize::new(1);
        let servers = config.ice_servers.iter().map(|url| c_string(url)).collect::<Result<Vec<_>, _>>()?;
        let mut server_ptrs: Vec<*const c_char> = servers.iter().map(|url| url.as_ptr()).collect();
        let bind = config.bind_address.as_deref().map(c_string).transpose()?;
        let (begin, end) = config.port_range.unwrap_or((0, 0));
        let raw = ffi::rtcConfiguration {
            iceServers: if server_ptrs.is_empty() { std::ptr::null_mut() } else { server_ptrs.as_mut_ptr() },
            iceServersCount: server_ptrs.len() as c_int,
            proxyServer: std::ptr::null(),
            bindAddress: bind.as_ref().map_or(std::ptr::null(), |bind| bind.as_ptr()),
            certificateType: 0,
            iceTransportPolicy: c_int::from(config.relay_only),
            enableIceTcp: false,
            enableIceUdpMux: false,
            disableAutoNegotiation: false,
            forceMediaTransport: false,
            portRangeBegin: begin,
            portRangeEnd: end,
            mtu: 0,
            maxMessageSize: c_int::try_from(config.max_message_size).map_err(|_| Error::Invalid)?,
        };
        if !lifetime::connection_starting() {
            return Err(Error::NotAvailable);
        }
        // SAFETY: `raw` and every string it points to outlive the call, which copies the configuration.
        let id = check(unsafe { ffi::rtcCreatePeerConnection(&raw) }).inspect_err(|_| lifetime::handle_released())?;
        let handle = Arc::new(Handle { id });
        let key = NEXT_KEY.fetch_add(1, Ordering::Relaxed);
        let (events, receiver) = mpsc::channel();
        let entry = Entry { events, connection: Arc::downgrade(&handle) };
        registry().lock().unwrap_or_else(|e| e.into_inner()).insert(key, entry);
        let ptr = key as *mut c_void;
        // SAFETY: `id` is the handle just created; the user pointer is set before any callback can read it.
        unsafe {
            ffi::rtcSetUserPointer(id, ptr);
            ffi::rtcSetLocalDescriptionCallback(id, Some(on_description));
            ffi::rtcSetLocalCandidateCallback(id, Some(on_candidate));
            ffi::rtcSetStateChangeCallback(id, Some(on_state));
            ffi::rtcSetGatheringStateChangeCallback(id, Some(on_gathering));
            ffi::rtcSetDataChannelCallback(id, Some(on_data_channel));
        }
        Ok((PeerConnection { handle, key }, receiver))
    }

    /// Opens a reliable, ordered data channel (the helper's only kind). On an offerer the first one creates the offer.
    pub fn create_data_channel(&self, label: &str) -> Result<DataChannel, Error> {
        let label = c_string(label)?;
        let init = ffi::rtcDataChannelInit {
            reliability: ffi::rtcReliability::default(),
            protocol: std::ptr::null(),
            negotiated: false,
            manualStream: false,
            stream: 0,
        };
        // SAFETY: the handle is live while `self` is; `label` and `init` outlive the call.
        let dc = check(unsafe { ffi::rtcCreateDataChannelEx(self.handle.id, label.as_ptr(), &init) })?;
        lifetime::handle_acquired();
        install_channel_callbacks(dc, self.key as *mut c_void);
        Ok(DataChannel { id: dc, connection: Arc::clone(&self.handle) })
    }

    /// Applies the peer's description: "offer" (an answerer, which then creates its answer) or "answer".
    pub fn set_remote_description(&self, sdp: &str, kind: &str) -> Result<(), Error> {
        let (sdp, kind) = (c_string(sdp)?, c_string(kind)?);
        // SAFETY: the handle is live while `self` is; both strings outlive the call.
        check(unsafe { ffi::rtcSetRemoteDescription(self.handle.id, sdp.as_ptr(), kind.as_ptr()) }).map(drop)
    }

    /// Adds one remote candidate ("candidate:..." with or without "a="), for the media section `mid` when given.
    pub fn add_remote_candidate(&self, candidate: &str, mid: Option<&str>) -> Result<(), Error> {
        let candidate = c_string(candidate)?;
        let mid = mid.map(c_string).transpose()?;
        let mid_ptr = mid.as_ref().map_or(std::ptr::null(), |mid| mid.as_ptr());
        // SAFETY: the handle is live while `self` is; both strings outlive the call.
        check(unsafe { ffi::rtcAddRemoteCandidate(self.handle.id, candidate.as_ptr(), mid_ptr) }).map(drop)
    }

    /// The selected candidate pair (local, remote) once ICE has connected.
    pub fn selected_pair(&self) -> Option<(String, String)> {
        let (mut local, mut remote) = (vec![0u8; 256], vec![0u8; 256]);
        let (id, local_ptr, remote_ptr) = (self.handle.id, local.as_mut_ptr().cast(), remote.as_mut_ptr().cast());
        // SAFETY: both buffers are writable for the sizes given; the stack NUL-terminates what it writes.
        let code = unsafe { ffi::rtcGetSelectedCandidatePair(id, local_ptr, 256, remote_ptr, 256) };
        check(code).ok()?;
        let text = |buffer: &[u8]| CStr::from_bytes_until_nul(buffer).ok().map(|s| s.to_string_lossy().into_owned());
        Some((text(&local)?, text(&remote)?))
    }

    /// Closes the connection; events may still report the closing. Dropping it also closes it.
    pub fn close(&self) {
        // SAFETY: the handle is live while `self` is.
        unsafe { ffi::rtcClosePeerConnection(self.handle.id) };
    }
}

impl Drop for PeerConnection {
    fn drop(&mut self) {
        // Unregistered first: a callback still in flight finds no sender and delivers nothing.
        registry().lock().unwrap_or_else(|e| e.into_inner()).remove(&self.key);
        self.close();
        // The handle itself goes with the last of this connection and its channels (`Handle`'s drop).
    }
}

/// A data channel, reliable and ordered. Dropping it closes it. It keeps its connection's handle, which is released
/// only after every channel of it is.
pub struct DataChannel {
    id: c_int,
    connection: Arc<Handle>,
}

impl fmt::Debug for DataChannel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DataChannel").field("id", &self.id).field("connection", &self.connection.id).finish()
    }
}

impl DataChannel {
    /// The handle events name in `ChannelOpen`, `Message` and the others.
    pub fn id(&self) -> i32 {
        self.id
    }

    /// Sends one binary message of at most [`DataChannel::max_message_size`] bytes.
    pub fn send(&self, data: &[u8]) -> Result<(), Error> {
        let size = c_int::try_from(data.len()).map_err(|_| Error::Invalid)?;
        // A zero-length binary message still needs a valid pointer; the slice's dangling one is never read.
        // SAFETY: the handle is live while `self` is; `data` is readable for `size` bytes.
        check(unsafe { ffi::rtcSendMessage(self.id, data.as_ptr().cast(), size) }).map(drop)
    }

    /// Closes the channel (the peer sees it close); sending fails afterwards. Dropping it also closes it.
    pub fn close(&self) {
        // SAFETY: the handle is live while `self` is; closing does not release it.
        unsafe { ffi::rtcClose(self.id) };
    }

    /// The largest message the peer accepts (the smaller of both sides' a=max-message-size).
    pub fn max_message_size(&self) -> usize {
        // SAFETY: the handle is live while `self` is.
        check(unsafe { ffi::rtcMaxMessageSize(self.id) }).map_or(0, |size| size as usize)
    }

    /// Bytes queued to send.
    pub fn buffered_amount(&self) -> usize {
        // SAFETY: the handle is live while `self` is.
        check(unsafe { ffi::rtcGetBufferedAmount(self.id) }).map_or(0, |size| size as usize)
    }

    /// Whether the channel is reliable and ordered, the only kind that can carry ADR 0001.
    pub fn is_reliable_and_ordered(&self) -> bool {
        let mut reliability = ffi::rtcReliability::default();
        // SAFETY: the handle is live while `self` is; `reliability` is writable.
        let code = unsafe { ffi::rtcGetDataChannelReliability(self.id, &mut reliability) };
        code == ffi::RTC_ERR_SUCCESS && !reliability.unordered && !reliability.unreliable
    }
}

impl Drop for DataChannel {
    fn drop(&mut self) {
        // SAFETY: the handle is live until this call, which releases it; it is never used again. The connection's
        // handle (`self.connection`) is released after it.
        unsafe { ffi::rtcDeleteDataChannel(self.id) };
        lifetime::handle_released();
    }
}
