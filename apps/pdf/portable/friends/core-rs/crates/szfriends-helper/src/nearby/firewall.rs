//! Where the nearby listeners may bind (ADR 0015 § 15). On Windows the firewall decides: the helper reads the policy
//! of the current profiles (no elevation, nothing changed) and listens only where it already admits connections, so
//! no firewall prompt ever appears; otherwise it listens nowhere and reaches friends nearby by its own dials. Linux
//! never asks (firewalld and ufw need root, and a blocked port looks like an empty network).

use std::path::Path;

use super::listeners::Binding;

/// The firewall facts in `szfriends-core`'s terms, from Windows' policy.
#[cfg(windows)]
pub fn facts(policy: &szfriends_helper_sys::firewall::Policy) -> szfriends_core::nearby::firewall::Facts {
    use szfriends_core::nearby::firewall::{Facts, Profile, Rule};
    let all = [Profile::Domain, Profile::Private, Profile::Public];
    let with = |list: &[(i32, bool)]| -> Vec<Profile> {
        all.iter().copied().filter(|p| list.iter().any(|(bit, on)| *bit == p.bit() && *on)).collect()
    };
    Facts {
        profiles: all.iter().copied().filter(|p| policy.current_profiles & p.bit() != 0).collect(),
        enabled: with(&policy.enabled),
        block_all_inbound: with(&policy.block_all_inbound),
        inbound_rules: policy
            .inbound_rules
            .iter()
            .map(|r| Rule {
                enabled: r.enabled,
                allow: r.allow,
                profiles: r.profiles,
                protocol: r.protocol,
                local_ports: r.local_ports.clone(),
                application: r.application.clone(),
                service: r.service.clone(),
                package: r.package.clone(),
                user: r.user.clone(),
            })
            .collect(),
    }
}

/// The binding for this computer, read again each time the LAN adapter asks (each window, each set-up).
pub fn rebind(state_dir: &Path) -> super::lan::Rebind {
    let state_dir = state_dir.to_path_buf();
    Box::new(move || binding(&state_dir))
}

/// The binding for this computer now.
pub fn binding(state_dir: &Path) -> Binding {
    let _ = state_dir;
    #[cfg(windows)]
    {
        use szfriends_core::nearby::firewall::{listen_plan, Listen};
        let program = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        return match szfriends_helper_sys::firewall::policy() {
            Ok(policy) => match listen_plan(&facts(&policy), &program) {
                Listen::Anywhere => Binding::Network,
                Listen::Within(ranges) => Binding::Within(ranges),
                Listen::Nowhere => Binding::Nowhere,
            },
            Err(error) => {
                crate::log!("firewall policy unreadable, connecting outbound only: {error}");
                Binding::Nowhere
            }
        };
    }
    #[allow(unreachable_code)]
    Binding::Network
}
