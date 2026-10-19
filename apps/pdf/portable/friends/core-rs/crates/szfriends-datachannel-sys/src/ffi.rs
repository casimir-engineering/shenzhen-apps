//! The part of libdatachannel's C API (`ext/libdatachannel/include/rtc/rtc.h`, 0.24.6) this crate calls, declared
//! by hand: the build defines `RTC_STATIC`, `RTC_ENABLE_MEDIA=0` and `RTC_ENABLE_WEBSOCKET=0`, and never
//! `CAPI_STDCALL`, so every function and callback uses the C calling convention on every target. The layouts of
//! `rtcConfiguration`, `rtcReliability` and `rtcDataChannelInit` are checked by `layout.rs`, which
//! `tests/loopback.rs` runs.

#![allow(non_camel_case_types, non_snake_case, dead_code)]

use std::ffi::{c_char, c_int, c_uint, c_void};

pub const RTC_ERR_SUCCESS: c_int = 0;
pub const RTC_ERR_INVALID: c_int = -1;
pub const RTC_ERR_FAILURE: c_int = -2;
pub const RTC_ERR_NOT_AVAIL: c_int = -3;
pub const RTC_ERR_TOO_SMALL: c_int = -4;

// C enums are int-sized on every target this crate builds for.
pub type rtcState = c_int;
pub type rtcGatheringState = c_int;
pub type rtcLogLevel = c_int;
pub type rtcCertificateType = c_int;
pub type rtcTransportPolicy = c_int;

pub const RTC_GATHERING_COMPLETE: rtcGatheringState = 2;
pub const RTC_LOG_NONE: rtcLogLevel = 0;
pub const RTC_LOG_ERROR: rtcLogLevel = 2;
pub const RTC_LOG_WARNING: rtcLogLevel = 3;

pub type rtcLogCallbackFunc = Option<extern "C" fn(level: rtcLogLevel, message: *const c_char)>;
pub type rtcDescriptionCallbackFunc =
    Option<extern "C" fn(pc: c_int, sdp: *const c_char, kind: *const c_char, ptr: *mut c_void)>;
pub type rtcCandidateCallbackFunc =
    Option<extern "C" fn(pc: c_int, cand: *const c_char, mid: *const c_char, ptr: *mut c_void)>;
pub type rtcStateChangeCallbackFunc = Option<extern "C" fn(pc: c_int, state: rtcState, ptr: *mut c_void)>;
pub type rtcGatheringStateCallbackFunc = Option<extern "C" fn(pc: c_int, state: rtcGatheringState, ptr: *mut c_void)>;
pub type rtcDataChannelCallbackFunc = Option<extern "C" fn(pc: c_int, dc: c_int, ptr: *mut c_void)>;
pub type rtcOpenCallbackFunc = Option<extern "C" fn(id: c_int, ptr: *mut c_void)>;
pub type rtcClosedCallbackFunc = Option<extern "C" fn(id: c_int, ptr: *mut c_void)>;
pub type rtcErrorCallbackFunc = Option<extern "C" fn(id: c_int, error: *const c_char, ptr: *mut c_void)>;
pub type rtcMessageCallbackFunc =
    Option<extern "C" fn(id: c_int, message: *const c_char, size: c_int, ptr: *mut c_void)>;

#[repr(C)]
#[derive(Debug)]
pub struct rtcConfiguration {
    pub iceServers: *mut *const c_char,
    pub iceServersCount: c_int,
    pub proxyServer: *const c_char,
    pub bindAddress: *const c_char,
    pub certificateType: rtcCertificateType,
    pub iceTransportPolicy: rtcTransportPolicy,
    pub enableIceTcp: bool,
    pub enableIceUdpMux: bool,
    pub disableAutoNegotiation: bool,
    pub forceMediaTransport: bool,
    pub portRangeBegin: u16,
    pub portRangeEnd: u16,
    pub mtu: c_int,
    pub maxMessageSize: c_int,
}

#[repr(C)]
#[derive(Debug, Default, Clone, Copy)]
pub struct rtcReliability {
    pub unordered: bool,
    pub unreliable: bool,
    pub maxPacketLifeTime: c_uint,
    pub maxRetransmits: c_uint,
}

#[repr(C)]
#[derive(Debug)]
pub struct rtcDataChannelInit {
    pub reliability: rtcReliability,
    pub protocol: *const c_char,
    pub negotiated: bool,
    pub manualStream: bool,
    pub stream: u16,
}

extern "C" {
    pub fn rtcInitLogger(level: rtcLogLevel, cb: rtcLogCallbackFunc);
    pub fn rtcSetUserPointer(id: c_int, ptr: *mut c_void);

    pub fn rtcCreatePeerConnection(config: *const rtcConfiguration) -> c_int;
    pub fn rtcClosePeerConnection(pc: c_int) -> c_int;
    pub fn rtcDeletePeerConnection(pc: c_int) -> c_int;
    pub fn rtcSetLocalDescriptionCallback(pc: c_int, cb: rtcDescriptionCallbackFunc) -> c_int;
    pub fn rtcSetLocalCandidateCallback(pc: c_int, cb: rtcCandidateCallbackFunc) -> c_int;
    pub fn rtcSetStateChangeCallback(pc: c_int, cb: rtcStateChangeCallbackFunc) -> c_int;
    pub fn rtcSetGatheringStateChangeCallback(pc: c_int, cb: rtcGatheringStateCallbackFunc) -> c_int;
    pub fn rtcSetDataChannelCallback(pc: c_int, cb: rtcDataChannelCallbackFunc) -> c_int;
    pub fn rtcSetLocalDescription(pc: c_int, kind: *const c_char) -> c_int;
    pub fn rtcSetRemoteDescription(pc: c_int, sdp: *const c_char, kind: *const c_char) -> c_int;
    pub fn rtcAddRemoteCandidate(pc: c_int, cand: *const c_char, mid: *const c_char) -> c_int;
    pub fn rtcGetSelectedCandidatePair(
        pc: c_int,
        local: *mut c_char,
        local_size: c_int,
        remote: *mut c_char,
        remote_size: c_int,
    ) -> c_int;

    pub fn rtcSetOpenCallback(id: c_int, cb: rtcOpenCallbackFunc) -> c_int;
    pub fn rtcSetClosedCallback(id: c_int, cb: rtcClosedCallbackFunc) -> c_int;
    pub fn rtcSetErrorCallback(id: c_int, cb: rtcErrorCallbackFunc) -> c_int;
    pub fn rtcSetMessageCallback(id: c_int, cb: rtcMessageCallbackFunc) -> c_int;
    pub fn rtcSendMessage(id: c_int, data: *const c_char, size: c_int) -> c_int;
    pub fn rtcClose(id: c_int) -> c_int;
    pub fn rtcMaxMessageSize(id: c_int) -> c_int;
    pub fn rtcGetBufferedAmount(id: c_int) -> c_int;

    pub fn rtcCreateDataChannelEx(pc: c_int, label: *const c_char, init: *const rtcDataChannelInit) -> c_int;
    pub fn rtcDeleteDataChannel(dc: c_int) -> c_int;
    pub fn rtcGetDataChannelReliability(dc: c_int, reliability: *mut rtcReliability) -> c_int;

    pub fn rtcSetThreadPoolSize(count: c_uint) -> c_int;
    pub fn rtcCleanup();

    // From Mbed TLS, for the version check: the archive and the pinned header agree.
    pub fn mbedtls_version_get_string(buffer: *mut c_char);
}
