//! Network changes from the kernel (ADR 0015 § 16): rtnetlink's link and address groups, so the helper learns of a
//! new network, a lost one or a changed address without NetworkManager.

use std::io;

use rustix::net::netlink::SocketAddrNetlink;
use rustix::net::{AddressFamily, RecvFlags, SocketFlags, SocketType};

const RTMGRP_LINK: u32 = 0x1;
const RTMGRP_IPV4_IFADDR: u32 = 0x10;
const RTMGRP_IPV6_IFADDR: u32 = 0x100;
const RTM_NEWLINK: u16 = 16;
const RTM_DELLINK: u16 = 17;
const RTM_NEWADDR: u16 = 20;
const RTM_DELADDR: u16 = 21;

/// Whether a datagram of netlink messages reports a link or address change.
pub fn reports_change(datagram: &[u8]) -> bool {
    let mut rest = datagram;
    while rest.len() >= 16 {
        let length = u32::from_ne_bytes([rest[0], rest[1], rest[2], rest[3]]) as usize;
        let kind = u16::from_ne_bytes([rest[4], rest[5]]);
        if matches!(kind, RTM_NEWLINK | RTM_DELLINK | RTM_NEWADDR | RTM_DELADDR) {
            return true;
        }
        if length < 16 || length > rest.len() {
            return false;
        }
        rest = rest.get(length.div_ceil(4) * 4..).unwrap_or(&[]);
    }
    false
}

/// Calls `on_change` for each datagram that reports a change, until the socket fails.
pub fn watch(on_change: impl Fn()) -> io::Result<()> {
    let socket = rustix::net::socket_with(AddressFamily::NETLINK, SocketType::RAW, SocketFlags::CLOEXEC, None)?;
    rustix::net::bind(&socket, &SocketAddrNetlink::new(0, RTMGRP_LINK | RTMGRP_IPV4_IFADDR | RTMGRP_IPV6_IFADDR))?;
    let mut buffer = vec![0u8; 64 * 1024];
    loop {
        match rustix::net::recv(&socket, &mut buffer[..], RecvFlags::empty()) {
            Ok((received, _)) => {
                if reports_change(&buffer[..received]) {
                    on_change();
                }
            }
            Err(rustix::io::Errno::INTR) => continue,
            // Too many changes at once for the socket's buffer: something certainly changed.
            Err(rustix::io::Errno::NOBUFS) => on_change(),
            Err(error) => return Err(error.into()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn message(kind: u16, payload: usize) -> Vec<u8> {
        let length = 16 + payload;
        let mut bytes = (length as u32).to_ne_bytes().to_vec();
        bytes.extend_from_slice(&kind.to_ne_bytes());
        bytes.resize(length.div_ceil(4) * 4, 0);
        bytes
    }

    #[test]
    fn link_and_address_messages_are_changes() {
        assert!(reports_change(&message(RTM_NEWADDR, 8)));
        let mut two = message(3, 5);
        two.extend(message(RTM_DELLINK, 0));
        assert!(reports_change(&two), "the second message of a datagram counts");
        assert!(!reports_change(&message(3, 4)), "NLMSG_DONE alone is no change");
        assert!(!reports_change(&[0u8; 8]), "too short");
        let mut lying = message(3, 0);
        lying[0] = 200;
        assert!(!reports_change(&lying), "a length past the end stops the walk");
    }
}
