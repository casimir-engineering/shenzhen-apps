//! Whether the desktop helper listens for nearby connections (ADR 0015 § 15). Nothing in Friends may cause a firewall
//! prompt: on Windows, Defender Firewall prompts the first time a program listens on a network address, and on a
//! standard account dismissing that prompt leaves block rules behind. So the helper listens only when the firewall of
//! the current profile already admits it, read without elevation; otherwise every nearby route works outbound first
//! (whoever finds the other dials) and the Nearby page says so in one line. Pure: the facts are the platform's.

/// A Windows firewall profile (`NET_FW_PROFILE2_*`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    Domain,
    Private,
    Public,
}

impl Profile {
    /// The `NET_FW_PROFILE2_*` bit.
    pub fn bit(self) -> i32 {
        match self {
            Self::Domain => 0x1,
            Self::Private => 0x2,
            Self::Public => 0x4,
        }
    }
}

/// One inbound rule as `INetFwRule` reports it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub enabled: bool,
    /// `true` for Allow.
    pub allow: bool,
    /// `NET_FW_PROFILE2_*` bits; `0x7fffffff` for all.
    pub profiles: i32,
    /// `NET_FW_IP_PROTOCOL_*`: 6 TCP, 256 any.
    pub protocol: i32,
    /// "*", or a list such as "5353,49152-49160"; empty means any.
    pub local_ports: String,
    /// The program the rule is for, or empty for any.
    pub application: String,
    /// The service the rule is for: empty for any process; anything else (a name, or "*" for every service) covers
    /// services only, never the helper.
    pub service: String,
    /// The app package (an AppContainer) or user the rule is scoped to: either set, it is not the helper's.
    pub package: String,
    pub user: String,
}

/// What the helper learnt about the firewall of the profile in force now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Facts {
    /// The current profiles (several on a computer with networks of different kinds).
    pub profiles: Vec<Profile>,
    /// Profiles whose firewall is on.
    pub enabled: Vec<Profile>,
    /// Profiles that block all inbound traffic whatever the rules say.
    pub block_all_inbound: Vec<Profile>,
    pub inbound_rules: Vec<Rule>,
}

fn port_listed(list: &str, port: u16) -> bool {
    let list = list.trim();
    if list.is_empty() || list == "*" {
        return true;
    }
    list.split(',').map(str::trim).any(|item| match item.split_once('-') {
        Some((low, high)) => match (low.trim().parse::<u16>(), high.trim().parse::<u16>()) {
            (Ok(low), Ok(high)) => (low..=high).contains(&port),
            _ => false,
        },
        None => item.parse::<u16>() == Ok(port),
    })
}

fn same_program(rule: &str, program: &str) -> bool {
    let rule = rule.trim();
    rule.is_empty() || rule.eq_ignore_ascii_case(program)
}

/// `true` when listening on `port` from `program` meets no prompt and no block: every current profile's firewall is
/// off, or admits the port by an enabled Allow rule for TCP that names this program or none. A profile that blocks all
/// inbound traffic admits nothing.
pub fn may_listen(facts: &Facts, port: u16, program: &str) -> bool {
    if facts.profiles.is_empty() {
        return false; // nothing known: fail closed (no prompt)
    }
    facts.profiles.iter().all(|profile| {
        if !facts.enabled.contains(profile) {
            return true;
        }
        if facts.block_all_inbound.contains(profile) {
            return false;
        }
        facts.inbound_rules.iter().any(|rule| {
            rule.enabled
                && rule.allow
                && rule.profiles & profile.bit() != 0
                && matches!(rule.protocol, 6 | 256)
                && port_listed(&rule.local_ports, port)
                && same_program(&rule.application, program)
                && rule.service.trim().is_empty()
                && rule.package.trim().is_empty()
                && rule.user.trim().is_empty()
        })
    })
}

/// Where the helper may listen (the hidden listener moves to a fresh port every window, ADR 0004 Review amendments,
/// 3): anywhere, within the port ranges the rules admit (a fixed-port rule from a per-machine install keeps one port),
/// or nowhere, when it connects outbound only.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Listen {
    Anywhere,
    Within(Vec<(u16, u16)>),
    Nowhere,
}

fn ranges(list: &str) -> Vec<(u16, u16)> {
    let list = list.trim();
    if list.is_empty() || list == "*" {
        return vec![(1, u16::MAX)];
    }
    list.split(',')
        .filter_map(|item| match item.trim().split_once('-') {
            Some((low, high)) => Some((low.trim().parse().ok()?, high.trim().parse().ok()?)),
            None => item.trim().parse().ok().map(|port| (port, port)),
        })
        .filter(|(low, high)| low <= high)
        .collect()
}

/// The listen plan for `program` from the firewall facts (see [`may_listen`] for what admits a port).
pub fn listen_plan(facts: &Facts, program: &str) -> Listen {
    if facts.profiles.is_empty() {
        return Listen::Nowhere;
    }
    if facts.profiles.iter().all(|p| !facts.enabled.contains(p)) {
        return Listen::Anywhere;
    }
    // A rule's range counts when its ports pass for every current profile: checked port by port up to 4,096 ports,
    // at both ends beyond that (such wide ranges come from rules for any port).
    let mut admitted: Vec<(u16, u16)> = Vec::new();
    for rule in &facts.inbound_rules {
        for (low, high) in ranges(&rule.local_ports) {
            let span = u32::from(high) - u32::from(low);
            let all = if span <= 4096 {
                (low..=high).all(|port| may_listen(facts, port, program))
            } else {
                may_listen(facts, low, program) && may_listen(facts, high, program)
            };
            if all && !admitted.contains(&(low, high)) {
                admitted.push((low, high));
            }
        }
    }
    if admitted.is_empty() {
        Listen::Nowhere
    } else {
        Listen::Within(admitted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn listen_plans() {
        assert_eq!(listen_plan(&facts(&[], vec![]), HELPER), Listen::Anywhere);
        assert_eq!(listen_plan(&facts(&[Profile::Private], vec![]), HELPER), Listen::Nowhere);
        let fixed = facts(&[Profile::Private], vec![rule(0x2, "47810"), rule(0x4, "9000")]);
        assert_eq!(listen_plan(&fixed, HELPER), Listen::Within(vec![(47_810, 47_810)]));
    }

    fn rule(profiles: i32, ports: &str) -> Rule {
        Rule {
            enabled: true,
            allow: true,
            profiles,
            protocol: 6,
            local_ports: ports.into(),
            application: String::new(),
            service: String::new(),
            package: String::new(),
            user: String::new(),
        }
    }

    fn facts(enabled: &[Profile], rules: Vec<Rule>) -> Facts {
        Facts {
            profiles: vec![Profile::Private],
            enabled: enabled.to_vec(),
            block_all_inbound: Vec::new(),
            inbound_rules: rules,
        }
    }

    const HELPER: &str = r"C:\Users\a\AppData\Local\Shenzhen Friends\helper\1\szfriends-helper.exe";

    #[test]
    fn profile_off_listens() {
        assert!(may_listen(&facts(&[], vec![]), 47_810, HELPER));
    }

    #[test]
    fn rule_present_listens() {
        assert!(may_listen(&facts(&[Profile::Private], vec![rule(0x2, "47810")]), 47_810, HELPER));
        assert!(may_listen(&facts(&[Profile::Private], vec![rule(0x7fff_ffff, "47000-48000")]), 47_810, HELPER));
    }

    #[test]
    fn disabled_rule_does_not() {
        let mut off = rule(0x2, "47810");
        off.enabled = false;
        assert!(!may_listen(&facts(&[Profile::Private], vec![off]), 47_810, HELPER));
        let mut block = rule(0x2, "47810");
        block.allow = false;
        assert!(!may_listen(&facts(&[Profile::Private], vec![block]), 47_810, HELPER));
    }

    #[test]
    fn other_profile_or_port_or_program_does_not() {
        assert!(!may_listen(&facts(&[Profile::Private], vec![rule(0x4, "47810")]), 47_810, HELPER));
        assert!(!may_listen(&facts(&[Profile::Private], vec![rule(0x2, "47811,5000-5010")]), 47_810, HELPER));
        let mut other = rule(0x2, "*");
        other.application = r"C:\Program Files\Other\other.exe".into();
        assert!(!may_listen(&facts(&[Profile::Private], vec![other]), 47_810, HELPER));
        let mut udp = rule(0x2, "*");
        udp.protocol = 17;
        assert!(!may_listen(&facts(&[Profile::Private], vec![udp]), 47_810, HELPER));
        for service in ["*", "Dnscache"] {
            let mut services = rule(0x2, "*");
            services.service = service.into();
            assert!(!may_listen(&facts(&[Profile::Private], vec![services]), 47_810, HELPER), "{service}");
        }
        // A Store app's rule admits that app package alone (the VM's Microsoft Store, Teams, Game Bar...).
        let mut package = rule(0x7, "");
        package.protocol = 256;
        package.package = "S-1-15-2-1609473798-1231923017-684268153".into();
        assert!(!may_listen(&facts(&[Profile::Private], vec![package]), 47_810, HELPER));
    }

    #[test]
    fn block_all_inbound_and_unknown_fail_closed() {
        let mut blocked = facts(&[Profile::Private], vec![rule(0x2, "*")]);
        blocked.block_all_inbound = vec![Profile::Private];
        assert!(!may_listen(&blocked, 47_810, HELPER));
        let unknown = Facts { profiles: vec![], enabled: vec![], block_all_inbound: vec![], inbound_rules: vec![] };
        assert!(!may_listen(&unknown, 47_810, HELPER));
    }

    #[test]
    fn every_current_profile_must_admit() {
        let mut two = facts(&[Profile::Private, Profile::Public], vec![rule(0x2, "*")]);
        two.profiles = vec![Profile::Private, Profile::Public];
        assert!(!may_listen(&two, 47_810, HELPER));
        two.inbound_rules.push(rule(0x4, "*"));
        assert!(may_listen(&two, 47_810, HELPER));
    }
}
