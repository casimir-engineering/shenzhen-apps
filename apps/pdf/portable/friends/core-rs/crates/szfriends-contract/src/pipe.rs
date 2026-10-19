//! Windows: how a client finds its own helper's named pipe and refuses anyone else's (ADR 0015 § Desktop IPC).
//!
//! The pipe namespace is shared by every account on the machine, so creating a pipe first proves nothing: another
//! account (or a sandboxed process) can create `\\.\pipe\<our name>` before the helper does and wait for clients.
//! Four rules close that:
//!
//! - **The lock decides the single instance**, not pipe creation: `<state dir>\ipc\helper.lock`, held with
//!   `LockFileEx` by the running helper. The state directory is under `%LOCALAPPDATA%`, which only the user can write.
//!   The holder writes its process id at the start of the file ([`lock_owner_line`]) and locks one byte at
//!   [`LOCKED_BYTE`], past the id, so clients can read who holds it.
//! - **The pipe name is unguessable and written down**: the helper holding the lock creates
//!   `\\.\pipe\szfriends-<user SID>-<16 hex of the state dir>-<32 random hex>` with `FILE_FLAG_FIRST_PIPE_INSTANCE`,
//!   a DACL for the user alone, an explicit owner (the user's SID) and `PIPE_REJECT_REMOTE_CLIENTS`, then writes the
//!   name to `<state dir>\ipc\helper.pipe`. Clients read the name from there, never derive it.
//! - **The client checks the server before sending a byte**: `GetNamedPipeServerProcessId` must be the lock's
//!   holder, read from `helper.lock` after the pipe connected (so a name left behind by a helper that has gone, or
//!   handed over, is not trusted); that process's token user SID and the pipe's owner SID (`GetSecurityInfo`) must
//!   both be the client's own user SID. The client opens the pipe with `SECURITY_SQOS_PRESENT |
//!   SECURITY_IDENTIFICATION`, so even a server that passed would not be able to act as the client. The helper checks
//!   each client's token user the same way (`GetNamedPipeClientProcessId`).
//! - **Neither side trusts a weaker process of the same user**: the other end's token must not be an AppContainer
//!   (`TokenIsAppContainer`) and its mandatory integrity level (`TokenIntegrityLevel`) must be at least the checker's
//!   own. A sandboxed or low-integrity process running as the user (a browser's renderer, a document viewer's
//!   sandbox) could otherwise squat the name or drive the helper with the user's friends.
//!
//! This module holds the decisions as pure functions; the Win32 calls that gather [`PeerFacts`] arrive with the
//! helper in wave 3, in a platform crate (this workspace forbids `unsafe`).

use std::path::{Path, PathBuf};

use crate::socket::fnv1a64;

/// A Windows security identifier in its string form (`S-1-5-21-…`), as `ConvertSidToStringSidW` writes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Sid(String);

impl Sid {
    /// `S-1-` then 1 to 15 dash-separated decimal sub-authorities; nothing else, so a SID can sit in a pipe name.
    pub fn parse(text: &str) -> Option<Self> {
        let rest = text.strip_prefix("S-1-")?;
        let parts: Vec<&str> = rest.split('-').collect();
        let valid = (1..=16).contains(&parts.len())
            && parts.iter().all(|p| !p.is_empty() && p.len() <= 10 && p.bytes().all(|b| b.is_ascii_digit()));
        valid.then(|| Self(text.to_owned()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// `<state dir>\ipc\helper.lock`: whoever holds it is the helper.
pub fn lock_path(state_dir: &Path) -> PathBuf {
    state_dir.join("ipc").join("helper.lock")
}

/// The byte of `helper.lock` the helper locks (`LockFileEx`, one byte). Windows locks are mandatory, so the lock sits
/// past the process id at the start of the file, which clients must still be able to read.
pub const LOCKED_BYTE: u64 = 1 << 32;

/// What the lock holder writes at the start of `helper.lock`: its process id and a newline.
pub fn lock_owner_line(process_id: u32) -> String {
    format!("{process_id}\n")
}

/// The process id at the start of `helper.lock`, accepted only in exactly [`lock_owner_line`]'s form (decimal, no
/// leading zero, not 0, then a newline). Anything else names no helper.
pub fn lock_owner(contents: &str) -> Option<u32> {
    let digits = contents.strip_suffix('\n')?;
    let canonical = !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) && !digits.starts_with('0');
    canonical.then(|| digits.parse().ok()).flatten()
}

/// `<state dir>\ipc\helper.pipe`: the name of the running helper's pipe, written by the lock holder.
pub fn advertised_name_path(state_dir: &Path) -> PathBuf {
    state_dir.join("ipc").join("helper.pipe")
}

fn name_prefix(user: &Sid, canonical_state_dir: &str) -> String {
    format!(r"\\.\pipe\szfriends-{}-{:016x}-", user.as_str(), fnv1a64(canonical_state_dir.as_bytes()))
}

/// The pipe a helper creates for `user` and its state directory, with 16 fresh random bytes.
pub fn pipe_name(user: &Sid, canonical_state_dir: &str, nonce: &[u8; 16]) -> String {
    let hex: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    name_prefix(user, canonical_state_dir) + &hex
}

/// The name read from [`advertised_name_path`], accepted only when it is exactly a name [`pipe_name`] makes for this
/// user and state directory (one line, an optional trailing newline). Anything else is not our helper's.
pub fn advertised_name(contents: &str, user: &Sid, canonical_state_dir: &str) -> Option<String> {
    let line = contents.strip_suffix('\n').unwrap_or(contents);
    let nonce = line.strip_prefix(&name_prefix(user, canonical_state_dir))?;
    let ok = nonce.len() == 32 && nonce.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'));
    ok.then(|| line.to_owned())
}

/// A token's mandatory integrity level: the RID of its `TokenIntegrityLevel` label (`SECURITY_MANDATORY_*_RID`).
/// Ordered as Windows orders them; levels between the named ones compare by their RID.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct IntegrityLevel(pub u32);

impl IntegrityLevel {
    pub const UNTRUSTED: Self = Self(0x0000);
    pub const LOW: Self = Self(0x1000);
    pub const MEDIUM: Self = Self(0x2000);
    pub const MEDIUM_PLUS: Self = Self(0x2100);
    pub const HIGH: Self = Self(0x3000);
    pub const SYSTEM: Self = Self(0x4000);
}

/// The checking side's own token: who it runs as, and at what integrity level.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OwnToken {
    pub user: Sid,
    pub integrity: IntegrityLevel,
}

/// What Windows reports about the other end of a connected pipe. `None` where a call failed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PeerFacts {
    /// The process at the other end (`GetNamedPipeServerProcessId` or `…ClientProcessId`).
    pub process_id: Option<u32>,
    /// That process's token user.
    pub process_user: Option<Sid>,
    /// That process's token integrity level.
    pub integrity: Option<IntegrityLevel>,
    /// Whether that process's token is an AppContainer's (`TokenIsAppContainer`).
    pub app_container: Option<bool>,
    /// The pipe object's owner (`GetSecurityInfo`, `OWNER_SECURITY_INFORMATION`). Checked by clients only: the
    /// server created the pipe and knows its owner.
    pub pipe_owner: Option<Sid>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeerRefusal {
    /// The peer's process or token could not be read: refused, never assumed to be ours.
    Unknown,
    /// The peer process runs as another user.
    OtherUser,
    /// The pipe belongs to another user (a squatter that created it first).
    OtherOwner,
    /// The peer runs in an AppContainer: a sandbox, even when it runs as the user.
    AppContainer,
    /// The peer's integrity level is below the checker's own.
    LowerIntegrity,
    /// The server is not the process holding `helper.lock` (or nothing readable holds it).
    NotLockOwner,
}

/// What both sides check of the other end's token.
fn check_token(own: &OwnToken, facts: &PeerFacts) -> Result<(), PeerRefusal> {
    let (Some(process), Some(integrity), Some(app_container)) =
        (&facts.process_user, facts.integrity, facts.app_container)
    else {
        return Err(PeerRefusal::Unknown);
    };
    if *process != own.user {
        Err(PeerRefusal::OtherUser)
    } else if app_container {
        Err(PeerRefusal::AppContainer)
    } else if integrity < own.integrity {
        Err(PeerRefusal::LowerIntegrity)
    } else {
        Ok(())
    }
}

/// A client's check of the server it reached, before it sends anything. `lock_owner` is [`lock_owner`] of
/// `helper.lock` read after the pipe connected.
pub fn check_server(own: &OwnToken, lock_owner: Option<u32>, facts: &PeerFacts) -> Result<(), PeerRefusal> {
    let Some(server) = facts.process_id else { return Err(PeerRefusal::Unknown) };
    check_token(own, facts)?;
    match &facts.pipe_owner {
        None => return Err(PeerRefusal::Unknown),
        Some(owner) if *owner != own.user => return Err(PeerRefusal::OtherOwner),
        Some(_) => {}
    }
    if lock_owner != Some(server) {
        return Err(PeerRefusal::NotLockOwner);
    }
    Ok(())
}

/// The helper's check of a client that connected.
pub fn check_client(own: &OwnToken, facts: &PeerFacts) -> Result<(), PeerRefusal> {
    check_token(own, facts)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DIR: &str = r"C:\Users\mei\AppData\Local\Shenzhen Friends";

    fn mei() -> Sid {
        Sid::parse("S-1-5-21-1004336348-1177238915-682003330-1001").expect("a user SID")
    }

    #[test]
    fn sids_are_only_what_windows_writes() {
        assert!(Sid::parse("S-1-5-18").is_some());
        for bad in ["", "S-1-", "S-1-5-", "S-2-5-18", "S-1-5-18-", "S-1-5-x", r"S-1-5-18\..\x", "s-1-5-18"] {
            assert_eq!(Sid::parse(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_advertised_name_must_be_ours_exactly() {
        let name = pipe_name(&mei(), DIR, &[0xab; 16]);
        assert!(name.starts_with(r"\\.\pipe\szfriends-S-1-5-21-1004336348-1177238915-682003330-1001-"));
        assert_eq!(advertised_name(&format!("{name}\n"), &mei(), DIR), Some(name.clone()));
        assert_eq!(advertised_name(&name, &mei(), DIR), Some(name.clone()));
        let other_user = Sid::parse("S-1-5-21-1004336348-1177238915-682003330-1002").unwrap();
        assert_eq!(advertised_name(&name, &other_user, DIR), None, "another user's name");
        assert_eq!(advertised_name(&name, &mei(), r"C:\elsewhere"), None, "another state directory");
        let short = &name[..name.len() - 2];
        for bad in [short.to_owned(), format!("{name}0"), name.to_uppercase(), format!("{name}\n\n"), String::new()] {
            assert_eq!(advertised_name(&bad, &mei(), DIR), None, "{bad:?}");
        }
        assert_eq!(advertised_name(&name.replace("abab", "ABAB"), &mei(), DIR), None, "uppercase hex");
    }

    fn own() -> OwnToken {
        OwnToken { user: mei(), integrity: IntegrityLevel::MEDIUM }
    }

    fn ours() -> PeerFacts {
        PeerFacts {
            process_id: Some(4242),
            process_user: Some(mei()),
            integrity: Some(IntegrityLevel::MEDIUM),
            app_container: Some(false),
            pipe_owner: Some(mei()),
        }
    }

    #[test]
    fn a_squatter_is_refused_before_anything_is_sent() {
        let squatter = Sid::parse("S-1-5-21-9-9-9-1003").unwrap();
        assert_eq!(check_server(&own(), Some(4242), &ours()), Ok(()));
        let other_process = PeerFacts { process_user: Some(squatter.clone()), ..ours() };
        assert_eq!(check_server(&own(), Some(4242), &other_process), Err(PeerRefusal::OtherUser));
        let other_owner = PeerFacts { pipe_owner: Some(squatter.clone()), ..ours() };
        assert_eq!(check_server(&own(), Some(4242), &other_owner), Err(PeerRefusal::OtherOwner));
        let unreadable = PeerFacts { process_user: None, ..ours() };
        assert_eq!(check_server(&own(), Some(4242), &unreadable), Err(PeerRefusal::Unknown));
        assert_eq!(check_server(&own(), Some(4242), &PeerFacts::default()), Err(PeerRefusal::Unknown));
        assert_eq!(check_client(&own(), &ours()), Ok(()));
        assert_eq!(check_client(&own(), &other_process), Err(PeerRefusal::OtherUser));
        assert_eq!(check_client(&own(), &PeerFacts::default()), Err(PeerRefusal::Unknown));
    }

    #[test]
    fn a_sandbox_of_the_same_user_is_refused_both_ways() {
        let sandboxed = PeerFacts { app_container: Some(true), integrity: Some(IntegrityLevel::LOW), ..ours() };
        assert_eq!(check_server(&own(), Some(4242), &sandboxed), Err(PeerRefusal::AppContainer));
        assert_eq!(check_client(&own(), &sandboxed), Err(PeerRefusal::AppContainer));
        let container_at_medium = PeerFacts { app_container: Some(true), ..ours() };
        assert_eq!(check_client(&own(), &container_at_medium), Err(PeerRefusal::AppContainer));
        for unread in [PeerFacts { app_container: None, ..ours() }, PeerFacts { integrity: None, ..ours() }] {
            assert_eq!(check_server(&own(), Some(4242), &unread), Err(PeerRefusal::Unknown));
            assert_eq!(check_client(&own(), &unread), Err(PeerRefusal::Unknown));
        }
    }

    #[test]
    fn a_lower_integrity_peer_is_refused_both_ways() {
        for level in [IntegrityLevel::UNTRUSTED, IntegrityLevel::LOW, IntegrityLevel(0x1fff)] {
            let low = PeerFacts { integrity: Some(level), ..ours() };
            assert_eq!(check_server(&own(), Some(4242), &low), Err(PeerRefusal::LowerIntegrity), "{level:?}");
            assert_eq!(check_client(&own(), &low), Err(PeerRefusal::LowerIntegrity), "{level:?}");
        }
        let (medium, high) = (IntegrityLevel::MEDIUM, IntegrityLevel::HIGH);
        for level in [medium, IntegrityLevel::MEDIUM_PLUS, high, IntegrityLevel::SYSTEM] {
            let same_or_higher = PeerFacts { integrity: Some(level), ..ours() };
            assert_eq!(check_server(&own(), Some(4242), &same_or_higher), Ok(()), "{level:?}");
            assert_eq!(check_client(&own(), &same_or_higher), Ok(()), "{level:?}");
        }
        // An elevated helper refuses the app running normally as its client; an elevated app refuses a normal helper.
        let elevated = OwnToken { integrity: IntegrityLevel::HIGH, ..own() };
        assert_eq!(check_client(&elevated, &ours()), Err(PeerRefusal::LowerIntegrity));
        assert_eq!(check_server(&elevated, Some(4242), &ours()), Err(PeerRefusal::LowerIntegrity));
    }

    #[test]
    fn the_server_must_still_hold_the_lock() {
        assert_eq!(check_server(&own(), Some(4243), &ours()), Err(PeerRefusal::NotLockOwner), "another holder");
        assert_eq!(check_server(&own(), None, &ours()), Err(PeerRefusal::NotLockOwner), "no readable holder");
        let no_pid = PeerFacts { process_id: None, ..ours() };
        assert_eq!(check_server(&own(), Some(4242), &no_pid), Err(PeerRefusal::Unknown));
        assert_eq!(check_server(&own(), lock_owner(&lock_owner_line(4242)), &ours()), Ok(()));
    }

    #[test]
    fn the_lock_names_its_holder_exactly() {
        assert_eq!(lock_owner_line(4242), "4242\n");
        assert_eq!(lock_owner("4242\n"), Some(4242));
        assert_eq!(lock_owner(&lock_owner_line(u32::MAX)), Some(u32::MAX));
        for bad in ["", "\n", "4242", "04242\n", "0\n", "4242\n\n", " 4242\n", "+4242\n", "4294967296\n", "42a\n"] {
            assert_eq!(lock_owner(bad), None, "{bad:?}");
        }
        assert!(LOCKED_BYTE > lock_owner_line(u32::MAX).len() as u64);
    }

    #[test]
    fn lock_and_name_live_in_the_state_directory() {
        let dir = Path::new("state");
        assert_eq!(lock_path(dir), dir.join("ipc").join("helper.lock"));
        assert_eq!(advertised_name_path(dir), dir.join("ipc").join("helper.pipe"));
    }
}
