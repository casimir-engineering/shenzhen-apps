//! Windows' own DNS-SD (`DnsServiceBrowse`, `DnsServiceResolve`, `DnsServiceRegister`; Windows 10 1809 and later),
//! which the system's DNS client serves with its built-in mDNS firewall rules, so the helper opens no UDP 5353
//! socket of its own and nothing meets the firewall (ADR 0015 § 15). Callbacks arrive on threads Windows chooses;
//! each forwards to a Rust closure and returns.

use std::ffi::c_void;
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr::{null, null_mut};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::time::Duration;

use windows_sys::Win32::Foundation::DNS_REQUEST_PENDING;
use windows_sys::Win32::NetworkManagement::Dns::{
    DnsFree, DnsFreeRecordList, DnsServiceBrowse, DnsServiceBrowseCancel, DnsServiceConstructInstance,
    DnsServiceDeRegister, DnsServiceFreeInstance, DnsServiceRegister, DnsServiceResolve, DnsServiceResolveCancel,
    DNS_QUERY_REQUEST_VERSION1, DNS_RECORDW, DNS_SERVICE_BROWSE_REQUEST, DNS_SERVICE_BROWSE_REQUEST_0,
    DNS_SERVICE_CANCEL, DNS_SERVICE_INSTANCE, DNS_SERVICE_REGISTER_REQUEST, DNS_SERVICE_RESOLVE_REQUEST, DNS_TYPE_PTR,
};

use super::{from_wide, wide};

/// `ERROR_CANCELLED`: the last call a cancelled browse makes.
const ERROR_CANCELLED: u32 = 1223;

/// What a browse reports: an instance's full name ("name._type._tcp.local") coming or going (a TTL of 0).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BrowseRecord {
    Added(String),
    Removed(String),
}

struct BrowseContext {
    callback: Box<dyn Fn(BrowseRecord) + Send + Sync>,
}

/// A running browse; cancelled when dropped.
pub struct Browse {
    cancel: Box<DNS_SERVICE_CANCEL>,
    // Kept alive until Windows has made its last call; freed by that call (ERROR_CANCELLED).
    _query: Vec<u16>,
}

impl std::fmt::Debug for Browse {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Browse")
    }
}

unsafe extern "system" fn browse_callback(status: u32, context: *const c_void, records: *const DNS_RECORDW) {
    if status == ERROR_CANCELLED {
        // SAFETY: the context was leaked from a Box when the browse started; this is Windows' last call with it.
        drop(unsafe { Box::from_raw(context as *mut BrowseContext) });
        return;
    }
    // SAFETY: the context outlives every call before ERROR_CANCELLED (above).
    let context = unsafe { &*(context as *const BrowseContext) };
    let mut record = records;
    while !record.is_null() {
        // SAFETY: Windows hands a valid record list, each `pNext` a record or null.
        let current = unsafe { &*record };
        if current.wType == DNS_TYPE_PTR {
            // SAFETY: a PTR record's data is a DNS_PTR_DATAW whose name is NUL-terminated UTF-16.
            let name = unsafe { from_wide(current.Data.PTR.pNameHost) };
            let event = if current.dwTtl == 0 { BrowseRecord::Removed(name) } else { BrowseRecord::Added(name) };
            let _ = catch_unwind(AssertUnwindSafe(|| (context.callback)(event)));
        }
        record = current.pNext;
    }
    if !records.is_null() {
        // SAFETY: the list was allocated by the DNS client for this callback, freed once here.
        unsafe { DnsFree(records.cast(), DnsFreeRecordList) };
    }
}

/// Browses `service` ("_szfriends._tcp.local") on `interface` (0: all).
pub fn browse(service: &str, interface: u32, callback: Box<dyn Fn(BrowseRecord) + Send + Sync>) -> io::Result<Browse> {
    let query = wide(service);
    let context = Box::into_raw(Box::new(BrowseContext { callback }));
    let request = DNS_SERVICE_BROWSE_REQUEST {
        Version: DNS_QUERY_REQUEST_VERSION1,
        InterfaceIndex: interface,
        QueryName: query.as_ptr(),
        Anonymous: DNS_SERVICE_BROWSE_REQUEST_0 { pBrowseCallback: Some(browse_callback) },
        pQueryContext: context.cast(),
    };
    let mut cancel = Box::new(DNS_SERVICE_CANCEL { reserved: null_mut() });
    // SAFETY: the request and its name stay valid for the call; the context lives until ERROR_CANCELLED.
    let status = unsafe { DnsServiceBrowse(&request, &mut *cancel) };
    if status != DNS_REQUEST_PENDING {
        // SAFETY: Windows did not take the context; it is still ours alone.
        drop(unsafe { Box::from_raw(context) });
        return Err(io::Error::from_raw_os_error(status));
    }
    Ok(Browse { cancel, _query: query })
}

// SAFETY: the cancel handle and query name are plain data the DNS client reads on any thread; nothing in them is tied
// to the thread that started the browse.
unsafe impl Send for Browse {}

impl Drop for Browse {
    fn drop(&mut self) {
        // SAFETY: the handle came from a pending DnsServiceBrowse and is cancelled once.
        unsafe { DnsServiceBrowseCancel(&*self.cancel) };
    }
}

/// A resolved instance.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Instance {
    pub host: String,
    pub port: u16,
    pub ipv4: Option<Ipv4Addr>,
    pub ipv6: Option<Ipv6Addr>,
    pub properties: Vec<(String, String)>,
}

/// # Safety
/// `instance` must be a valid DNS_SERVICE_INSTANCE from the DNS client.
unsafe fn read_instance(instance: &DNS_SERVICE_INSTANCE) -> Instance {
    let text = |p: *mut u16| if p.is_null() { String::new() } else { unsafe { from_wide(p) } };
    let ipv4 = (!instance.ip4Address.is_null())
        .then(|| Ipv4Addr::from(u32::from_be(unsafe { *instance.ip4Address })))
        .filter(|a| !a.is_unspecified());
    // SAFETY: when present, the IPv6 address is 16 bytes.
    let ipv6 = (!instance.ip6Address.is_null())
        .then(|| Ipv6Addr::from(unsafe { (*instance.ip6Address).IP6Byte }))
        .filter(|a| !a.is_unspecified());
    let mut properties = Vec::new();
    for i in 0..instance.dwPropertyCount as usize {
        // SAFETY: `keys` and `values` hold dwPropertyCount strings each.
        let (key, value) = unsafe { (*instance.keys.add(i), *instance.values.add(i)) };
        properties.push((text(key), text(value)));
    }
    Instance { host: text(instance.pszHostName), port: instance.wPort, ipv4, ipv6, properties }
}

unsafe extern "system" fn resolve_callback(status: u32, context: *const c_void, instance: *const DNS_SERVICE_INSTANCE) {
    // SAFETY: the context is the sender `resolve` leaked for this one call.
    let sender = unsafe { Box::from_raw(context as *mut SyncSender<Option<Instance>>) };
    let result = (status == 0 && !instance.is_null()).then(|| unsafe { read_instance(&*instance) });
    if !instance.is_null() {
        // SAFETY: the instance was allocated by the DNS client for this callback.
        unsafe { DnsServiceFreeInstance(instance) };
    }
    let _ = sender.try_send(result);
}

/// Resolves one instance's full name, waiting at most `timeout`.
pub fn resolve(full_name: &str, interface: u32, timeout: Duration) -> io::Result<Option<Instance>> {
    let mut query = wide(full_name);
    let (sender, receiver) = sync_channel(1);
    let context = Box::into_raw(Box::new(sender));
    let request = DNS_SERVICE_RESOLVE_REQUEST {
        Version: DNS_QUERY_REQUEST_VERSION1,
        InterfaceIndex: interface,
        QueryName: query.as_mut_ptr(),
        pResolveCompletionCallback: Some(resolve_callback),
        pQueryContext: context.cast(),
    };
    let mut cancel = DNS_SERVICE_CANCEL { reserved: null_mut() };
    // SAFETY: the request is valid for the call; the context is freed by the one completion call.
    let status = unsafe { DnsServiceResolve(&request, &mut cancel) };
    if status != DNS_REQUEST_PENDING {
        // SAFETY: Windows did not take the context.
        drop(unsafe { Box::from_raw(context) });
        return Err(io::Error::from_raw_os_error(status));
    }
    match receiver.recv_timeout(timeout) {
        Ok(result) => Ok(result),
        Err(_) => {
            // SAFETY: the query is pending; cancelling makes its completion call (which frees the context).
            unsafe { DnsServiceResolveCancel(&cancel) };
            Ok(None)
        }
    }
}

struct RegisterContext {
    done: SyncSender<u32>,
}

unsafe extern "system" fn register_callback(
    status: u32,
    context: *const c_void,
    instance: *const DNS_SERVICE_INSTANCE,
) {
    // SAFETY: the context lives as long as its Registration, which waits for this call before freeing it.
    let context = unsafe { &*(context as *const RegisterContext) };
    if !instance.is_null() {
        // SAFETY: the completion's instance is the DNS client's copy, ours to free.
        unsafe { DnsServiceFreeInstance(instance) };
    }
    let _ = context.done.try_send(status);
}

/// A registered instance; withdrawn when dropped.
pub struct Registration {
    request: Box<DNS_SERVICE_REGISTER_REQUEST>,
    context: Box<RegisterContext>,
    receiver: std::sync::mpsc::Receiver<u32>,
}

impl std::fmt::Debug for Registration {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Registration")
    }
}

/// Registers `full_name` ("name._type._tcp.local") at `host` ("computer.local") and `port`, with TXT `properties`.
pub fn register(
    full_name: &str,
    host: &str,
    port: u16,
    properties: &[(String, String)],
    interface: u32,
) -> io::Result<Registration> {
    let (name, host) = (wide(full_name), wide(host));
    let keys: Vec<Vec<u16>> = properties.iter().map(|(k, _)| wide(k)).collect();
    let values: Vec<Vec<u16>> = properties.iter().map(|(_, v)| wide(v)).collect();
    let key_pointers: Vec<*const u16> = keys.iter().map(|k| k.as_ptr()).collect();
    let value_pointers: Vec<*const u16> = values.iter().map(|v| v.as_ptr()).collect();
    // SAFETY: every string is NUL-terminated and alive for the call, which copies them into the instance.
    let instance = unsafe {
        DnsServiceConstructInstance(
            name.as_ptr(),
            host.as_ptr(),
            null(),
            null(),
            port,
            0,
            0,
            properties.len() as u32,
            key_pointers.as_ptr(),
            value_pointers.as_ptr(),
        )
    };
    if instance.is_null() {
        return Err(io::Error::other("DnsServiceConstructInstance failed"));
    }
    let (done, receiver) = sync_channel(4);
    let context = Box::new(RegisterContext { done });
    let request = Box::new(DNS_SERVICE_REGISTER_REQUEST {
        Version: DNS_QUERY_REQUEST_VERSION1,
        InterfaceIndex: interface,
        pServiceInstance: instance,
        pRegisterCompletionCallback: Some(register_callback),
        pQueryContext: (&*context as *const RegisterContext) as *mut c_void,
        hCredentials: 0,
        unicastEnabled: 0,
    });
    // SAFETY: the request, its instance and context stay alive in the Registration until it is withdrawn.
    let status = unsafe { DnsServiceRegister(&*request, null_mut()) };
    if status != DNS_REQUEST_PENDING as u32 {
        // SAFETY: the instance is ours and was not taken.
        unsafe { DnsServiceFreeInstance(instance) };
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    let registration = Registration { request, context, receiver };
    match registration.receiver.recv_timeout(Duration::from_secs(5)) {
        Ok(0) => Ok(registration),
        Ok(code) => Err(io::Error::from_raw_os_error(code as i32)),
        Err(_) => Err(io::Error::new(io::ErrorKind::TimedOut, "registration did not complete")),
    }
}

// SAFETY: the request, its instance and the context are heap data owned by this value alone; the DNS client calls
// back on its own threads whatever thread registered, and the context's sender is Send.
unsafe impl Send for Registration {}

impl Drop for Registration {
    fn drop(&mut self) {
        // SAFETY: the request registered successfully and is withdrawn once.
        let status = unsafe { DnsServiceDeRegister(&*self.request, null_mut()) };
        let finished =
            status == DNS_REQUEST_PENDING as u32 && self.receiver.recv_timeout(Duration::from_secs(2)).is_ok();
        // SAFETY: our constructed instance, no longer used by a pending call once the withdrawal completed.
        if finished {
            unsafe { DnsServiceFreeInstance(self.request.pServiceInstance) };
        } else {
            // Windows may still call back with the context and read the request: keep both for the process.
            let request = std::mem::replace(&mut self.request, Box::new(unsafe { std::mem::zeroed() }));
            let (done, _) = sync_channel(1);
            let context = std::mem::replace(&mut self.context, Box::new(RegisterContext { done }));
            Box::leak(request);
            Box::leak(context);
        }
    }
}
