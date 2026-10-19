//! Checks the hand-written structures in `ffi.rs` against what this target's C compiler makes of rtc.h
//! (`layout.c`), so a layout mismatch on a new platform fails a test instead of corrupting a call.

use std::ffi::{c_char, CStr};
use std::mem::{offset_of, size_of};

use crate::ffi::{rtcConfiguration, rtcDataChannelInit, rtcReliability};

extern "C" {
    fn szfdc_layout(out: *mut usize, count: usize) -> usize;
    fn szfdc_rtc_version() -> *const c_char;
}

/// Compares every size and offset, and the header's version with the pinned one. Err names the first difference.
pub fn check_layouts() -> Result<(), String> {
    let ours = [
        size_of::<rtcConfiguration>(),
        offset_of!(rtcConfiguration, iceServersCount),
        offset_of!(rtcConfiguration, proxyServer),
        offset_of!(rtcConfiguration, bindAddress),
        offset_of!(rtcConfiguration, certificateType),
        offset_of!(rtcConfiguration, iceTransportPolicy),
        offset_of!(rtcConfiguration, enableIceTcp),
        offset_of!(rtcConfiguration, forceMediaTransport),
        offset_of!(rtcConfiguration, portRangeBegin),
        offset_of!(rtcConfiguration, portRangeEnd),
        offset_of!(rtcConfiguration, mtu),
        offset_of!(rtcConfiguration, maxMessageSize),
        size_of::<rtcReliability>(),
        offset_of!(rtcReliability, maxRetransmits),
        size_of::<rtcDataChannelInit>(),
        offset_of!(rtcDataChannelInit, protocol),
        offset_of!(rtcDataChannelInit, negotiated),
        offset_of!(rtcDataChannelInit, stream),
    ];
    let mut theirs = [0usize; 18];
    // SAFETY: `theirs` is writable for the count given; layout.c writes at most that many values.
    let count = unsafe { szfdc_layout(theirs.as_mut_ptr(), theirs.len()) };
    if count != ours.len() {
        return Err(format!("layout.c reports {count} values, layout.rs compares {}", ours.len()));
    }
    if let Some(index) = (0..ours.len()).find(|&i| ours[i] != theirs[i]) {
        return Err(format!("value {index}: Rust {} vs C {}", ours[index], theirs[index]));
    }
    // SAFETY: RTC_VERSION is a string literal with static lifetime.
    let version = unsafe { CStr::from_ptr(szfdc_rtc_version()) }.to_string_lossy();
    if version != crate::LIBDATACHANNEL_VERSION {
        return Err(format!("rtc.h is {version}, the crate pins {}", crate::LIBDATACHANNEL_VERSION));
    }
    Ok(())
}
