//! Addresses and their scopes for the NAT techniques (`SZFriendsNATEndpoint.m`), after the IANA special-purpose
//! registries (RFC 6890 and its updates): anything not global there stays out of what a prober may reach. IPv4-mapped
//! IPv6 addresses become IPv4, so one address never has two spellings.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Scope {
    Unspecified,
    Loopback,
    LinkLocal,
    Multicast,
    Private,
    /// 100.64/10, carrier-grade NAT.
    Shared,
    Reserved,
    Global,
}

fn prefix(bytes: &[u8], prefix: &[u8], bits: usize) -> bool {
    let (whole, rest) = (bits / 8, bits % 8);
    if bytes[..whole] != prefix[..whole] {
        return false;
    }
    rest == 0 || {
        let mask = 0xffu8 << (8 - rest);
        bytes[whole] & mask == prefix[whole] & mask
    }
}

fn scope_v4(a: [u8; 4]) -> Scope {
    const TABLE: [([u8; 4], usize, Scope); 17] = [
        ([0, 0, 0, 0], 32, Scope::Unspecified),
        ([255, 255, 255, 255], 32, Scope::Multicast),
        ([127, 0, 0, 0], 8, Scope::Loopback),
        ([169, 254, 0, 0], 16, Scope::LinkLocal),
        ([224, 0, 0, 0], 4, Scope::Multicast),
        ([10, 0, 0, 0], 8, Scope::Private),
        ([172, 16, 0, 0], 12, Scope::Private),
        ([192, 168, 0, 0], 16, Scope::Private),
        ([100, 64, 0, 0], 10, Scope::Shared),
        ([0, 0, 0, 0], 8, Scope::Reserved),
        ([192, 0, 0, 0], 24, Scope::Reserved),
        ([192, 0, 2, 0], 24, Scope::Reserved),
        ([192, 88, 99, 0], 24, Scope::Reserved),
        ([198, 18, 0, 0], 15, Scope::Reserved),
        ([198, 51, 100, 0], 24, Scope::Reserved),
        ([203, 0, 113, 0], 24, Scope::Reserved),
        ([240, 0, 0, 0], 4, Scope::Reserved),
    ];
    TABLE.iter().find(|(p, bits, _)| prefix(&a, p, *bits)).map_or(Scope::Global, |(_, _, scope)| *scope)
}

fn scope_v6(a: [u8; 16]) -> Scope {
    if a == [0; 16] {
        return Scope::Unspecified;
    }
    if a == Ipv6Addr::LOCALHOST.octets() {
        return Scope::Loopback;
    }
    if a[0] == 0xfe && a[1] & 0xc0 == 0x80 {
        return Scope::LinkLocal;
    }
    if a[0] == 0xff {
        return Scope::Multicast;
    }
    if a[0] & 0xfe == 0xfc {
        return Scope::Private;
    }
    if a[0] & 0xe0 != 0x20 {
        return Scope::Reserved;
    }
    const RESERVED: [([u8; 4], usize); 4] =
        [([0x20, 0x01, 0x0d, 0xb8], 32), ([0x20, 0x01, 0, 0], 23), ([0x20, 0x02, 0, 0], 16), ([0x3f, 0xff, 0, 0], 20)];
    if RESERVED.iter().any(|(p, bits)| prefix(&a, p, *bits)) {
        return Scope::Reserved;
    }
    Scope::Global
}

/// The address with IPv4-mapped IPv6 turned into IPv4.
pub fn canonical(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        v4 => v4,
    }
}

pub fn canonical_addr(addr: SocketAddr) -> SocketAddr {
    SocketAddr::new(canonical(addr.ip()), addr.port())
}

pub fn scope(ip: IpAddr) -> Scope {
    match canonical(ip) {
        IpAddr::V4(v4) => scope_v4(v4.octets()),
        IpAddr::V6(v6) => scope_v6(v6.octets()),
    }
}

/// Numeric forms only: nothing here resolves a name. A scope id ("%en0") is refused: only link-local addresses carry
/// one, and no technique sends to those.
pub fn parse_ip(text: &str) -> Option<IpAddr> {
    if text.contains('%') {
        return None;
    }
    text.parse::<IpAddr>().ok().map(canonical)
}

/// The numeric host as a candidate line or a URI writes it (IPv6 without brackets).
pub fn host_text(ip: IpAddr) -> String {
    canonical(ip).to_string()
}

/// This computer's addresses as far as the routing table shows them without enumerating interfaces: the source address
/// each family's default route would use (nothing is sent). A prober never aims at them.
pub fn own_addresses() -> Vec<IpAddr> {
    let probes: [(&str, &str); 2] = [("0.0.0.0:0", "192.0.2.1:9"), ("[::]:0", "[2001:db8::1]:9")];
    probes
        .iter()
        .filter_map(|(bind, to)| {
            let socket = UdpSocket::bind(bind).ok()?;
            socket.connect(to).ok()?;
            socket.local_addr().ok().map(|a| canonical(a.ip()))
        })
        .collect()
}

/// Loopback addresses of each family.
pub fn loopback(ipv6: bool) -> IpAddr {
    if ipv6 {
        IpAddr::V6(Ipv6Addr::LOCALHOST)
    } else {
        IpAddr::V4(Ipv4Addr::LOCALHOST)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scopes_follow_the_registries() {
        let s = |t: &str| scope(t.parse().unwrap());
        assert_eq!(s("8.8.8.8"), Scope::Global);
        assert_eq!(s("127.0.0.1"), Scope::Loopback);
        assert_eq!(s("10.1.2.3"), Scope::Private);
        assert_eq!(s("100.100.0.1"), Scope::Shared);
        assert_eq!(s("198.19.0.1"), Scope::Reserved);
        assert_eq!(s("::ffff:192.168.1.1"), Scope::Private);
        assert_eq!(s("2001:db8::1"), Scope::Reserved);
        assert_eq!(s("2606:4700::1"), Scope::Global);
        assert_eq!(s("fe80::1"), Scope::LinkLocal);
        assert!(parse_ip("fe80::1%en0").is_none());
        assert_eq!(parse_ip("::ffff:1.2.3.4"), Some("1.2.3.4".parse().unwrap()));
    }
}
