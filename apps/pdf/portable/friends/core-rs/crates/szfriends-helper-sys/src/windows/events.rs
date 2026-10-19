//! Sleep, wake and network changes for the Windows helper (ADR 0015 § 16), delivered to a callback on a thread
//! Windows chooses. Callbacks must return quickly; the helper's forward each event to its own loop.

use std::ffi::c_void;
use std::io;
use std::panic::{catch_unwind, AssertUnwindSafe};

use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::NetworkManagement::IpHelper::{
    CancelMibChangeNotify2, NotifyIpInterfaceChange, NotifyUnicastIpAddressChange, MIB_IPINTERFACE_ROW,
    MIB_NOTIFICATION_TYPE, MIB_UNICASTIPADDRESS_ROW,
};
use windows_sys::Win32::Networking::WinSock::AF_UNSPEC;
use windows_sys::Win32::System::Power::{
    PowerRegisterSuspendResumeNotification, PowerUnregisterSuspendResumeNotification,
    DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS,
};
use windows_sys::Win32::UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK;

/// `PBT_APMSUSPEND`: the system is about to sleep.
const PBT_APMSUSPEND: u32 = 0x4;
/// `PBT_APMRESUMEAUTOMATIC`: the system woke, whether or not a person is there (sent on every resume).
const PBT_APMRESUMEAUTOMATIC: u32 = 0x12;
/// `MibInitialNotification`: the call made once at registration, when asked for.
const MIB_INITIAL_NOTIFICATION: MIB_NOTIFICATION_TYPE = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowerEvent {
    Suspend,
    Resume,
}

type Callback<T> = Box<dyn Fn(T) + Send + Sync>;

struct PowerContext {
    callback: Callback<PowerEvent>,
}

/// A registration for sleep and wake; unregistered when dropped.
#[derive(Debug)]
pub struct PowerWatch {
    registration: isize,
}

unsafe extern "system" fn power_callback(context: *const c_void, kind: u32, _setting: *const c_void) -> u32 {
    // SAFETY: `context` is the PowerContext registered with this callback, kept alive for the process.
    let context = unsafe { &*(context as *const PowerContext) };
    let event = match kind {
        PBT_APMSUSPEND => Some(PowerEvent::Suspend),
        PBT_APMRESUMEAUTOMATIC => Some(PowerEvent::Resume),
        _ => None,
    };
    if let Some(event) = event {
        let _ = catch_unwind(AssertUnwindSafe(|| (context.callback)(event)));
    }
    0
}

/// Calls `callback` before the system sleeps and after it wakes. No window needed.
pub fn watch_power(callback: impl Fn(PowerEvent) + Send + Sync + 'static) -> io::Result<PowerWatch> {
    // Leaked on purpose: Windows documents no point after unregistering from which a callback can no longer run, so
    // the context outlives every registration (one small allocation per helper).
    let context: &'static PowerContext = Box::leak(Box::new(PowerContext { callback: Box::new(callback) }));
    let parameters = DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
        Callback: Some(power_callback),
        Context: context as *const PowerContext as *mut c_void,
    };
    let mut registration: *mut c_void = std::ptr::null_mut();
    // SAFETY: with DEVICE_NOTIFY_CALLBACK the recipient is the parameters structure, read during the call.
    let status = unsafe {
        PowerRegisterSuspendResumeNotification(
            DEVICE_NOTIFY_CALLBACK,
            &parameters as *const DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS as HANDLE,
            &mut registration,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(PowerWatch { registration: registration as isize })
}

impl Drop for PowerWatch {
    fn drop(&mut self) {
        // SAFETY: a registration this value owns, unregistered once.
        unsafe { PowerUnregisterSuspendResumeNotification(self.registration) };
    }
}

/// A network change: an interface or an address came, went or changed. `initial` marks the one call made at
/// registration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NetworkEvent {
    pub initial: bool,
}

struct NetworkContext {
    callback: Callback<NetworkEvent>,
}

/// Registrations for interface and address changes; cancelled when dropped.
#[derive(Debug)]
pub struct NetworkWatch {
    registrations: Vec<HANDLE>,
    context: *mut c_void,
}

// SAFETY: the context pointer is only dereferenced by Windows' callbacks (the callback inside is Send + Sync) and
// freed by Drop after every registration is cancelled.
unsafe impl Send for NetworkWatch {}

fn network_event(context: *const c_void, kind: MIB_NOTIFICATION_TYPE) {
    // SAFETY: `context` is the NetworkContext registered with the callback, alive until the watch is dropped,
    // which first cancels the registrations (CancelMibChangeNotify2 waits for running callbacks).
    let context = unsafe { &*(context as *const NetworkContext) };
    let event = NetworkEvent { initial: kind == MIB_INITIAL_NOTIFICATION };
    let _ = catch_unwind(AssertUnwindSafe(|| (context.callback)(event)));
}

unsafe extern "system" fn interface_callback(context: *const c_void, _: *const MIB_IPINTERFACE_ROW, kind: i32) {
    network_event(context, kind);
}

unsafe extern "system" fn address_callback(context: *const c_void, _: *const MIB_UNICASTIPADDRESS_ROW, kind: i32) {
    network_event(context, kind);
}

/// Calls `callback` when an interface or an address changes, and once at once when `initial` is set.
pub fn watch_network(
    callback: impl Fn(NetworkEvent) + Send + Sync + 'static,
    initial: bool,
) -> io::Result<NetworkWatch> {
    let context = Box::into_raw(Box::new(NetworkContext { callback: Box::new(callback) })).cast::<c_void>();
    let mut watch = NetworkWatch { registrations: Vec::new(), context };
    let mut handle: HANDLE = 0;
    // SAFETY: a callback with the documented signature and a context that lives as long as `watch`.
    let status = unsafe {
        NotifyIpInterfaceChange(AF_UNSPEC, Some(interface_callback), context, u8::from(initial), &mut handle)
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    watch.registrations.push(handle);
    let mut handle: HANDLE = 0;
    // SAFETY: as above.
    let status = unsafe { NotifyUnicastIpAddressChange(AF_UNSPEC, Some(address_callback), context, 0, &mut handle) };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    watch.registrations.push(handle);
    Ok(watch)
}

impl Drop for NetworkWatch {
    fn drop(&mut self) {
        for registration in self.registrations.drain(..) {
            // SAFETY: a registration this value owns; the call waits for callbacks in progress.
            unsafe { CancelMibChangeNotify2(registration) };
        }
        // SAFETY: made by Box::into_raw in `watch_network`; no registration can call back any more.
        drop(unsafe { Box::from_raw(self.context.cast::<NetworkContext>()) });
    }
}
