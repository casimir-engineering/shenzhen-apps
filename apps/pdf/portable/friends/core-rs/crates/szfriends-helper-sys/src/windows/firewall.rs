//! What Windows Defender Firewall would do with a listener of ours (ADR 0015 § 15), read through `INetFwPolicy2`
//! without elevation and without changing anything: the current profiles, which of them have the firewall on or
//! block all inbound traffic, and the enabled inbound rules. The decision is `szfriends-core::nearby::firewall`'s.
//!
//! The COM interfaces are called through their vtables by index (netfw.h); only getters are ever called.

use std::ffi::c_void;
use std::io;
use std::ptr::null_mut;

use windows_sys::core::{GUID, HRESULT};
use windows_sys::Win32::Foundation::SysFreeString;
use windows_sys::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows_sys::Win32::System::Variant::{VariantClear, VARIANT};

const CLSID_NET_FW_POLICY2: GUID = GUID::from_u128(0xe2b3c97f_6ae1_41ac_817a_f6f92166d7dd);
const IID_INET_FW_POLICY2: GUID = GUID::from_u128(0x98325047_c671_4174_8d81_defcd3f03186);
const IID_INET_FW_RULE: GUID = GUID::from_u128(0xaf230d27_baba_4e42_aced_f524f22cfce2);
const IID_INET_FW_RULE3: GUID = GUID::from_u128(0xb21563ff_d696_4222_ab46_4e89b73ab34a);
const IID_IENUM_VARIANT: GUID = GUID::from_u128(0x00020404_0000_0000_c000_000000000046);
const VT_DISPATCH: u16 = 9;
const VT_UNKNOWN: u16 = 13;
const NET_FW_RULE_DIR_IN: i32 = 1;
const NET_FW_ACTION_ALLOW: i32 = 1;

/// One inbound rule, as `szfriends-core`'s decision reads it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub enabled: bool,
    pub allow: bool,
    pub profiles: i32,
    pub protocol: i32,
    pub local_ports: String,
    pub application: String,
    /// The service the rule is for ("*": every service, and only services); empty for any process.
    pub service: String,
    /// "*" for any; otherwise the addresses the rule admits connections from ("LocalSubnet", ranges).
    pub remote_addresses: String,
    /// "All", or the kinds of interface it covers ("Lan", "Wireless", "RemoteAccess").
    pub interface_types: String,
    /// The app package (an AppContainer's SID) the rule is for; empty for programs outside packages.
    pub package: String,
    /// The user the rule is for; empty for every user.
    pub user: String,
    /// For the log only.
    pub name: String,
}

/// What the policy says now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Policy {
    /// `NET_FW_PROFILE2_*` bits of the current profiles.
    pub current_profiles: i32,
    /// Per profile bit (1, 2, 4): firewall on, and all inbound blocked.
    pub enabled: Vec<(i32, bool)>,
    pub block_all_inbound: Vec<(i32, bool)>,
    pub inbound_rules: Vec<Rule>,
}

/// A COM interface pointer released when dropped.
struct Com(*mut c_void);

impl Com {
    /// The `index`th vtable entry.
    ///
    /// # Safety
    /// The pointer must be a live COM object whose vtable has that entry, of type `F`.
    unsafe fn method<F: Copy>(&self, index: usize) -> F {
        // SAFETY: a COM object starts with a pointer to its vtable of function pointers (the caller's promise).
        unsafe {
            let vtable = *(self.0 as *const *const usize);
            std::mem::transmute_copy(&*vtable.add(index))
        }
    }

    fn query(&self, iid: &GUID) -> Option<Com> {
        let mut out = null_mut();
        // SAFETY: entry 0 of every COM vtable is QueryInterface(this, riid, ppv).
        let query: unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> HRESULT =
            unsafe { self.method(0) };
        (unsafe { query(self.0, iid, &mut out) } >= 0 && !out.is_null()).then(|| Com(out))
    }
}

impl Drop for Com {
    fn drop(&mut self) {
        // SAFETY: entry 2 is Release; this value holds one reference.
        let release: unsafe extern "system" fn(*mut c_void) -> u32 = unsafe { self.method(2) };
        unsafe { release(self.0) };
    }
}

type GetI32 = unsafe extern "system" fn(*mut c_void, *mut i32) -> HRESULT;
type GetBool = unsafe extern "system" fn(*mut c_void, *mut i16) -> HRESULT;
type GetProfileBool = unsafe extern "system" fn(*mut c_void, i32, *mut i16) -> HRESULT;
type GetBstr = unsafe extern "system" fn(*mut c_void, *mut *mut u16) -> HRESULT;
type GetObject = unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> HRESULT;
type Next = unsafe extern "system" fn(*mut c_void, u32, *mut VARIANT, *mut u32) -> HRESULT;

fn check(result: HRESULT) -> io::Result<()> {
    if result < 0 {
        Err(io::Error::from_raw_os_error(result))
    } else {
        Ok(())
    }
}

fn get_i32(object: &Com, index: usize) -> io::Result<i32> {
    let mut value = 0;
    // SAFETY: `index` is a getter taking an out pointer to a LONG (netfw.h).
    check(unsafe { object.method::<GetI32>(index)(object.0, &mut value) })?;
    Ok(value)
}

fn get_string(object: &Com, index: usize) -> String {
    let mut text: *mut u16 = null_mut();
    // SAFETY: `index` is a getter returning a BSTR the caller frees.
    if unsafe { object.method::<GetBstr>(index)(object.0, &mut text) } < 0 || text.is_null() {
        return String::new();
    }
    // SAFETY: a BSTR is NUL-terminated UTF-16.
    let value = unsafe { super::from_wide(text) };
    // SAFETY: ours to free, once.
    unsafe { SysFreeString(text) };
    value
}

fn rule(object: &Com) -> io::Result<Rule> {
    let mut enabled = 0i16;
    // SAFETY: entry 33 is get_Enabled(VARIANT_BOOL*).
    check(unsafe { object.method::<GetBool>(33)(object.0, &mut enabled) })?;
    Ok(Rule {
        enabled: enabled != 0,
        allow: get_i32(object, 41)? == NET_FW_ACTION_ALLOW,
        profiles: get_i32(object, 37)?,
        protocol: get_i32(object, 15)?,
        local_ports: get_string(object, 17),
        application: get_string(object, 11),
        service: get_string(object, 13),
        remote_addresses: get_string(object, 23),
        interface_types: get_string(object, 31),
        // INetFwRule3 (Windows 8 and later): the package and user owner a rule is scoped to.
        package: object.query(&IID_INET_FW_RULE3).map(|v3| get_string(&v3, 45)).unwrap_or_default(),
        user: object.query(&IID_INET_FW_RULE3).map(|v3| get_string(&v3, 47)).unwrap_or_default(),
        name: get_string(object, 7),
    })
}

/// Reads the policy. COM is initialised on the calling thread (multithreaded) if it was not.
pub fn policy() -> io::Result<Policy> {
    // SAFETY: initialising COM for this thread; a thread already initialised keeps its model.
    unsafe { CoInitializeEx(null_mut(), COINIT_MULTITHREADED as u32) };
    let mut raw = null_mut();
    // SAFETY: standard in-process activation of the firewall policy object.
    check(unsafe {
        CoCreateInstance(&CLSID_NET_FW_POLICY2, null_mut(), CLSCTX_INPROC_SERVER, &IID_INET_FW_POLICY2, &mut raw)
    })?;
    let policy = Com(raw);
    let current_profiles = get_i32(&policy, 7)?;
    let mut enabled = Vec::new();
    let mut block_all_inbound = Vec::new();
    for profile in [1, 2, 4] {
        let (mut on, mut block) = (0i16, 0i16);
        // SAFETY: entries 8 and 12 are get_FirewallEnabled and get_BlockAllInboundTraffic(profile, VARIANT_BOOL*).
        check(unsafe { policy.method::<GetProfileBool>(8)(policy.0, profile, &mut on) })?;
        check(unsafe { policy.method::<GetProfileBool>(12)(policy.0, profile, &mut block) })?;
        enabled.push((profile, on != 0));
        block_all_inbound.push((profile, block != 0));
    }
    let mut rules_raw = null_mut();
    // SAFETY: entry 18 is get_Rules(INetFwRules**).
    check(unsafe { policy.method::<GetObject>(18)(policy.0, &mut rules_raw) })?;
    let rules = Com(rules_raw);
    let mut enumerator_raw = null_mut();
    // SAFETY: entry 11 of INetFwRules is get__NewEnum(IUnknown**).
    check(unsafe { rules.method::<GetObject>(11)(rules.0, &mut enumerator_raw) })?;
    let enumerator = Com(enumerator_raw).query(&IID_IENUM_VARIANT).ok_or_else(|| io::Error::other("no enumerator"))?;
    let mut inbound_rules = Vec::new();
    loop {
        // SAFETY: a zeroed VARIANT is VT_EMPTY.
        let mut item: VARIANT = unsafe { std::mem::zeroed() };
        let mut fetched = 0u32;
        // SAFETY: entry 3 of IEnumVARIANT is Next(celt, rgVar, pCeltFetched).
        let result = unsafe { enumerator.method::<Next>(3)(enumerator.0, 1, &mut item, &mut fetched) };
        if result != 0 || fetched == 0 {
            break;
        }
        // SAFETY: the union's first member is the VARIANT's type and value.
        let (kind, pointer) = unsafe { (item.Anonymous.Anonymous.vt, item.Anonymous.Anonymous.Anonymous.pdispVal) };
        if (kind == VT_DISPATCH || kind == VT_UNKNOWN) && !pointer.is_null() {
            // A borrowed pointer: AddRef through QueryInterface, released by our Com.
            let borrowed = std::mem::ManuallyDrop::new(Com(pointer));
            if let Some(entry) = borrowed.query(&IID_INET_FW_RULE) {
                if get_i32(&entry, 27).ok() == Some(NET_FW_RULE_DIR_IN) {
                    if let Ok(found) = rule(&entry) {
                        inbound_rules.push(found);
                    }
                }
            }
        }
        // SAFETY: releases what Next put in the VARIANT.
        unsafe { VariantClear(&mut item) };
    }
    Ok(Policy { current_profiles, enabled, block_all_inbound, inbound_rules })
}
