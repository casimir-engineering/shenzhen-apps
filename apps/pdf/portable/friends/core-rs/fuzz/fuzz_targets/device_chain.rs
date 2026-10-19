//! The device chain decoder (ADR 0012) fed anything a friend's CHAIN frame or an own device might carry: it must
//! never panic, and a chain it accepts must encode back to exactly the bytes it read and merge with itself unchanged.

#![no_main]

use libfuzzer_sys::fuzz_target;
use szfriends_core::identity::chain::DeviceChain;

fuzz_target!(|data: &[u8]| {
    if let Ok(chain) = DeviceChain::decode(data, None) {
        assert_eq!(chain.encoded(), data, "one encoding per chain");
        assert_eq!(chain.merged(&chain).expect("merges with itself"), chain);
        let pinned = DeviceChain::decode(data, Some(chain.root_key())).expect("the same root");
        assert_eq!(pinned, chain);
    }
});
