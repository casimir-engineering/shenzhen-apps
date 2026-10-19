# ADR 0002: Helper lifecycle and IPC

Status: Accepted by lead; owner review pending. Date: 2026-10-12.
Brief: § Processes and IPC, § Containment and porting, release gate "Launch". Areas: helper (owner),
protocol (client library), host adapter.

## Context

Reader windows are separate processes, restored in parallel, and detaching a tab starts another one.
Networking, keys and the store need exactly one owner per Mac user, shared later with Shenzhen Files.
Reception from launch is the one sanctioned launch-path exception and must not cost launch time.

## Decision

**One helper per Mac user.** A Foundation-only helper bundle (no AppKit, `LSBackgroundOnly`) in each app's
`Contents/Helpers/`, signed by its own `codesign` line before the outer bundle, like the Collection
companion. It has its own bundle identifier, distinct from both apps, because the reader's quit cascade and
the updater's instance count both match the reader's identifier: neither may kill or wait for the helper.
Both apps embed it with the same identifier and team so its Keychain item reads without a prompt. State
lives in `~/Library/Application Support/Shenzhen Friends/` (override `SZFRIENDS_STATE_DIR`).

**Spawn at launch, off the main thread, only while enabled.**

- ShenzhenPDF reads `friends.enabled` from the `settings.yaml` it already reads. When false, nothing else
  happens: no queue, socket, spawn or Friends file access.
- When true, one `dispatch_async` to a utility-QoS queue; the main thread never waits for it. The block
  calls the client library's connect-or-spawn (`szfriends_spawn_helper()`): connect once; on `ENOENT` or
  `ECONNREFUSED`, `posix_spawn` the helper and return. The block never waits for the helper: the client's own
  reconnection (first retry 50 ms, doubling, capped at 2 s; PROTOCOL.md § Lifecycle) connects once it is
  listening. Flags: `POSIX_SPAWN_SETSID`, so the helper leaves the reader's process group and outlives it;
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, so it inherits none of the reader's descriptors, whose locks it would
  otherwise hold after the reader exits. stdin and stdout go to `/dev/null`, stderr to the helper log. The
  spawner reaps the child from a detached thread, so a helper that exits never lingers as a zombie of a
  long-running reader.
- Connect-or-spawn lives in the C client library (libc only), so the GTK host reuses it; the host adapter
  passes only the helper's path. Readers do no other Friends work before first paint; the badge appears
  with the first snapshot.

**Single instance by `flock`.** The helper's first act is to open `<state>/helper.lock` (`O_CLOEXEC`, 0600)
and `flock(LOCK_EX | LOCK_NB)`; on `EWOULDBLOCK` it exits 0 before touching anything else. The kernel
releases the lock on any exit, SIGKILL included, so a stale lock cannot exist. Only the lock holder unlinks
a leftover socket and binds. A client that connects between unlink and bind gets `ECONNREFUSED`, spawns a
duplicate that exits at once, and connects on its next retry.

**Socket location.** `<state>/ipc/helper.sock`, with `ipc/` at 0700 and the socket at 0600. `sun_path` holds
104 bytes including the NUL; when the path does not fit (deep test directories, long user names), both
sides use `<per-user temp dir>/szfriends-<hash>/helper.sock`, where the temp dir comes from
`confstr(_CS_DARWIN_USER_TEMP_DIR)` (already private to the user) and `<hash>` is 16 hex digits of a 64-bit
FNV-1a over the resolved state directory. One client-library function computes the path for both sides.
Before use, the directory must be owned by the user, mode 0700 and not a symlink (`lstat`); otherwise refuse.
That check is one client-library function too (`szfriends_socket_directory_check()`).

**Peer checks.** On accept the helper reads `LOCAL_PEERCRED` and closes any peer with another uid. In builds
signed with a team identifier it also reads `LOCAL_PEERTOKEN` (the audit token, because a pid can be
reused), gets the peer's code with `kSecGuestAttributeAudit`, and checks `anchor apple generic and
certificate leaf[subject.OU] = "<team>"`, with the team read from the helper's own signature at run time.
ShenzhenPDF and Shenzhen Files both pass without an identifier list; other software the user runs cannot
drive the helper. Ad-hoc and test builds have no team and check the uid only.

**IPC.** Newline-delimited JSON, 8 MB per line, owned by the client library. Hello, version negotiation,
snapshots, intents, events and the handover request are specified in `portable/friends/PROTOCOL.md`, not
here. Clients render snapshots and send intents; the helper alone owns networking, keys, timers and writes.

**Exit.** The helper exits 10 seconds after its last client disconnects, long enough for a tab detach or a
multi-window restore to reconnect, or 30 seconds after start if no client ever connected (the spawner
died). On the way out it commits the open transaction, sends CLOSE on each session so peers resume later,
and stops discovery; outbox and transfers are already durable. SIGTERM takes the same path; SIGKILL loses
nothing committed (ADR 0003). A client that turns Friends off disconnects; the helper keeps serving any
other client.

**Version handover.** Every helper build carries an increasing build number, and each client's hello names
the build embedded in its own app. When the running helper is older, the client asks it to hand over: it
stops accepting clients, tells connected ones it is restarting, commits, sends CLOSE on its sessions, and
exits within 5 seconds, releasing the lock. Clients reconnect through connect-or-spawn and the newest
embedded helper wins. Equal builds never hand over, so two apps cannot ping-pong. A newer helper serves
clients one protocol major version older. An older helper that finds a store it cannot open reports "needs
update" to its clients and leaves the store alone (ADR 0003).

**Bundle replacement.** The updater can replace the app while the helper runs (Shenzhen Files may still use
it). The helper loads every resource it needs at start and never re-executes from its bundle path; the next
app launch hands over to the new helper.

**Permission attribution.** macOS attributes Local Network and Bluetooth prompts and grants to the
"responsible" app, which for a `posix_spawn`ed helper is the app that spawned it. Usage strings go into both
apps' and the helper's `Info.plist`. The two-Mac spike records which name macOS shows; if attribution per
spawning app makes behaviour depend on which app started the helper, launch it through LaunchServices
instead so it is responsible for itself. Launch activation never prompts (ADR 0004).

## Alternatives considered

- **launchd agent, login item, SMAppService**: running after the apps quit is a non-goal, and each adds
  persistent system configuration.
- **XPC service per app**: two apps would run two owners of one identity, and XPC services die with their app.
- **An elected reader process**: windows come and go; detaching or quitting the leader would drop sessions.
- **Socket under `/tmp`**: shared and world-writable; the per-user temp dir is private.
- **NSTask** (as the companion): it works, but `posix_spawn` states descriptor and session handling
  explicitly and is available to the libc client library.

## Consequences

- The helper lingers up to 10 s after the last window closes; a quick relaunch reuses it.
- The newest of the installed apps supplies the helper for both.
- A disabled launch costs only the settings read the reader already makes.
- Runs from Terminal attribute prompts to Terminal, so permission tests use signed builds on the hardware matrix.

## Verification

- Host-adapter unit test with injected settings and fake spawn, connect and dispatch: disabled makes zero
  calls of each; enabled makes exactly one dispatch, and the fakes record that spawn and connect ran with
  `pthread_main_np() == 0`.
- Link check on the reader binary (`otool -L`, `nm`): no CoreBluetooth and no Friends service symbols, only
  the client library, so the reader cannot open the store or a Bluetooth manager even by mistake.
- Two-helper harness: 20 clients connect-or-spawn at once on one state directory; exactly one helper holds
  the lock, duplicates exit 0 within 100 ms, all 20 receive a hello. After `kill -9` of the helper the next
  client starts a new one at once (no stale lock or socket).
- Harness: a state directory whose socket path exceeds 104 bytes works through the fallback; a fallback
  directory with the wrong owner or mode is refused.
- Harness: the helper exits 10 s ± 1 after the last client; a client returning at 5 s keeps it; a fake host
  sees one check-in per helper start however many clients connect.
- Handover: builds N and N+1 in the harness; N exits within 5 s and N+1 serves every client; N with N never
  hands over.
- Peer checks: unit tests of the uid and requirement decisions with injected credentials.
- Launch timing, in the verify wave and only when the owner allows launching a copy: own bundle copy,
  scratch `SPDF_STATE_DIR`, `SPDF_LAUNCH_PROFILE=1`, 20 cold launches each with Friends on and off;
  first-window median and p95 match within noise.

## Review amendments

Recorded on 2026-10-13 from the security reviews of the M1 build and the wave-3 re-check, which found the app side
of the peer check missing. `client/szfriends_client.h` § Signing policy holds the interface.

1. **Apps check the helper too, and ignore the state override when signed.** A team-signed app tells the client
   library its own Team ID and a verifier at launch, before spawning or connecting
   (`szfriends_set_signing_policy()`). The library then reads the helper's `LOCAL_PEERTOKEN` after the uid check and
   trusts the helper only when the verifier finds it satisfies the requirement the helper applies to its clients,
   `anchor apple generic and certificate leaf[subject.OU] = "<team>"`; a malformed team, a missing token or a missing
   verifier refuses every helper, and nothing is written to a refused one. It also ignores `SZFRIENDS_STATE_DIR`,
   the client side of the rule the signed helper applies to itself (`SZFriendsEnvironmentOverridesAllowed`).
   Connect-or-spawn treats a refused listener like a missing one once per launch, so our helper can take the path
   from a listener that does not hold the lock; the client's own retries never spawn for it, so a squatter costs one
   process per launch, not a loop. The library stays libc only: the verifier, on Security.framework, is the host's.
   Before this, any process running as the person could set `SZFRIENDS_STATE_DIR` for the next launch (`launchctl
   setenv`), listen there, and receive every message, file path and picture the app sent (findings: helper IPC
   client trust, environment overrides). Unsigned and ad-hoc builds keep the uid check and the override, as tests
   need.
