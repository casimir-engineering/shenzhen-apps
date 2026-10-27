//! Windows: Friends' one firewall rule, added from Nearby's Allow on Private Networks when the installer's step was
//! declined or never ran (a per-user install cannot add it without an administrator's yes). The rule and its
//! arguments are `szfriends-core`'s ([`szfriends_core::nearby::firewall::rule_arguments`]), the same the installer uses.

/// Asks Windows to add the rule (User Account Control shows `netsh`, from Microsoft); whether it was added.
pub fn allow_nearby(owner: isize) -> bool {
    match szfriends_helper::windows::firewall::netsh_elevated(
        &szfriends_core::nearby::firewall::rule_arguments(),
        owner,
    ) {
        Ok(added) => {
            crate::link::log(if added {
                "Friends' firewall rule was added"
            } else {
                "Friends' firewall rule was not added (declined, or netsh failed)"
            });
            added
        }
        Err(error) => {
            crate::link::log(&format!("could not ask for Friends' firewall rule: {error}"));
            false
        }
    }
}
