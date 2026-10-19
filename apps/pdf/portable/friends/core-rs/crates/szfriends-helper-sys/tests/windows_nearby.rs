//! Windows' own DNS-SD and firewall policy, as the helper reads them (ADR 0015 § 15): the firewall policy reads
//! without elevation and without changing any rule; and an instance registered under a test service type is browsed and
//! resolved back with its port and TXT, then withdrawn. Windows' DNS-SD does not browse on loopback (it refuses with
//! WSAENETUNREACH), so that test uses the VM's own virtual network and runs only when `SZFRIENDS_VM_NETWORK_TESTS=1`
//! asks for it; otherwise it says so and passes. Windows only; the Windows VM runs them.

#[cfg(windows)]
mod windows {
    use std::sync::mpsc::channel;
    use std::time::Duration;

    use szfriends_helper_sys::{dnssd, firewall};

    /// Every interface: Windows' DNS-SD has no loopback browsing.
    fn interface() -> u32 {
        0
    }

    fn label() -> String {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().subsec_nanos();
        format!("{:08x}", nanos ^ std::process::id())
    }

    pub fn register_browse_resolve() {
        if std::env::var_os("SZFRIENDS_VM_NETWORK_TESTS").is_none() {
            eprintln!("skipped: DNS-SD on the VM's network runs only with SZFRIENDS_VM_NETWORK_TESTS=1");
            return;
        }
        let label = label();
        let service = format!("_szfw{label}._tcp.local");
        let full = format!("probe{label}.{service}");
        let host = format!("{}.local", std::env::var("COMPUTERNAME").unwrap_or_default().to_lowercase());
        let txt = vec![("v".to_owned(), "1".to_owned()), ("t".to_owned(), "0102030405060708".to_owned())];
        let registration = dnssd::register(&full, &host, 47_123, &txt, interface()).expect("registered");
        let (sender, seen) = channel();
        let callback = Box::new(move |record| {
            let _ = sender.send(record);
        });
        let browse = dnssd::browse(&service, interface(), callback).expect("browsing");
        let found = (0..50).find_map(|_| match seen.recv_timeout(Duration::from_millis(200)) {
            Ok(dnssd::BrowseRecord::Added(found)) if found.eq_ignore_ascii_case(&full) => Some(found),
            _ => None,
        });
        let found = found.expect("the registration browsed back");
        let resolved = dnssd::resolve(&found, interface(), Duration::from_secs(5)).expect("resolved");
        let instance = resolved.expect("an instance");
        assert_eq!(instance.port, 47_123);
        assert!(instance.properties.contains(&("t".to_owned(), "0102030405060708".to_owned())), "{instance:?}");
        drop(registration);
        let removed = |record: &dnssd::BrowseRecord| match record {
            dnssd::BrowseRecord::Removed(r) => r.eq_ignore_ascii_case(&full),
            dnssd::BrowseRecord::Added(_) => false,
        };
        let gone = (0..50).any(|_| seen.recv_timeout(Duration::from_millis(200)).is_ok_and(|r| removed(&r)));
        eprintln!("withdrawal browsed: {gone}");
        drop(browse);
    }

    pub fn firewall_reads_without_changing() {
        let before = firewall::policy().expect("the policy reads without elevation");
        assert!(before.current_profiles & 0x7 != 0, "a current profile: {before:?}");
        let after = firewall::policy().expect("again");
        assert_eq!(before.inbound_rules.len(), after.inbound_rules.len(), "reading changes no rule");
        let admitting: Vec<_> = before
            .inbound_rules
            .iter()
            .filter(|r| r.enabled && r.allow && r.service.is_empty() && r.application.is_empty())
            .filter(|r| r.package.is_empty() && r.user.is_empty())
            .filter(|r| matches!(r.protocol, 6 | 256) && r.profiles & before.current_profiles != 0)
            .filter(|r| r.local_ports.is_empty() || r.local_ports == "*")
            .collect();
        for rule in &admitting {
            eprintln!("admits any program and port: {rule:?}");
        }
        eprintln!(
            "profiles {:#x}, enabled {:?}, block all {:?}, {} inbound rules",
            before.current_profiles,
            before.enabled,
            before.block_all_inbound,
            before.inbound_rules.len()
        );
    }
}

#[test]
fn dnssd_register_browse_resolve() {
    #[cfg(windows)]
    windows::register_browse_resolve();
}

#[test]
fn firewall_reads_without_changing() {
    #[cfg(windows)]
    windows::firewall_reads_without_changing();
}
