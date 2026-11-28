# ADR 0024: Friends protocol 1 and 2

Status: Accepted (the owner's request). Date: 2026-11-29.
Names what helpers speak to each other before and after the November 2026 Friends work (ADR 0018 § 9.2 (c),
ADR 0022, ADR 0023, the Bluetooth pace), and dates the end of support for the older one. Areas: session (capability
bits 6, 7 and 8), BOOST (Abilities bit 4), the Rust helper's Bluetooth pace, the Mac helper's Bluetooth dial. Client
contract: PROTOCOL.md § Friends protocol 1 and 2, which holds the table of every difference.

## Context

The owner: "make sure the app is retro-compatible with the old protocol lets call prev protocol 1 and
the new one protocol 2. Mark it for removal mid 2027." The released apps (ShenzhenPDF and Shenzhen Files 26.11.19-1,
Shenzhen 3D 0.2.10) meet helpers that set capability bits they do not know, and an updated helper cannot tell from
a missing bit 6 or 7 alone whether its peer is not allowed direct Wi-Fi now, has no hardware AES, or predates both.

## Decision

**Two names.** *Friends protocol 1* is the behaviour of every release up to ShenzhenPDF and Shenzhen Files 26.11.19-1
and Shenzhen 3D 0.2.10: no capability bit 6, 7 or 8; ChaChaPoly sessions throughout; files copied between one
person's computers by themselves (ADR 0014 as it was); direct Wi-Fi without the owner's rule; no piece HAVEs from
the Rust helper on a copy or a pull. *Friends protocol 2* is every helper since: it sets bit 8 in every handshake
with fast transfers, and a helper that sets bit 8 knows bits 6 and 7 and BOOST's Abilities bit 4. The names are
always written "Friends protocol 1" and "Friends protocol 2" (constants `CAPABILITY_PROTOCOL_2`,
`SZFriendsCapabilityProtocol2`; the session-up log lines), never bare: the host's protocol numbers
(HOST-PROTOCOL.md) and the session's major and minor versions are other things.

**No new frames.** Both protocols negotiate session minor 4 and send the same frames; protocol 2 only adds the three
handshake bits and one Abilities bit, which a protocol 1 helper ignores as unknown. So a protocol 2 helper keeps
every session with a protocol 1 peer and works around what that peer does not do, as the table in PROTOCOL.md
§ Friends protocol 1 and 2 says, case by case: ChaChaPoly throughout, never direct Wi-Fi with it, no boost, an
unpaced Bluetooth link when it serves a protocol 1 Rust helper's copy, the Mac dials a protocol 1 phone at once, and
copies that protocol 1 computer pulls by itself are served as before.

**Removal after 2027-06-30.** Until then protocol 1 peers are supported. Every code path that exists only for them
carries one greppable comment, `FRIENDS-PROTOCOL-1: remove after 2027-06-30`, with the reason after it:

| Language | Tags | Where |
|---|---|---|
| Rust | 7 | `szfriends-core` session `handshake.rs` (a peer without bit 8 still gets a session), `channel_state.rs` (`aes_session`, `direct_wifi_allowed`), `transfer/boost/steps.rs` (Abilities bit 4); `szfriends-helper` `direct_wifi.rs` (closing `p2p_wifi`), `radio_pace.rs` (the unpaced fallback), `nearby/trace.rs` (the log's protocol) |
| Objective-C | 8 | `SZFriendsSecureChannel+Handshake.m`, `SZFriendsSecureChannel.m` (`aesSession`, `directWiFiAllowed`), `SZFriendsNearbyService+Sessions.m` (closing `p2p_wifi`, the log's protocol), `SZFriendsDirectWiFiBoost.m` (Abilities bit 4), `SZFriendsNearbyService+PhoneDials.m` (dialling a protocol 1 phone at once), `SZFriendsStoreDevices.m` (the record that tells the two apart) |
| Swift | 0 | The iOS plugin passes radio events and Wi-Fi standing to the Rust core and reads no handshake bit |
| Kotlin | 0 | Likewise on Android; asking for full-size packets does not depend on the peer |

The change that removes support greps the tag and, at each site, deletes the protocol 1 case: where bit 6 or 7
still has a protocol 2 meaning (a device not allowed direct Wi-Fi now, one without hardware AES) the gate stays and
only the protocol 1 wording goes; the Mac's per-device record (settings key `bluetooth_phone_dials.<hex>`, kept under
that name so devices already recorded are not forgotten) goes, and the Mac waits for every Android phone. Whether a
peer without bit 8 then gets a session at all, or a message that it needs an update, is decided in that change.

## Alternatives considered

- **A new session minor (5) for protocol 2.** It would add nothing a capability bit does not, and a minor is about
  frames; protocol 2 adds none.
- **Refusing protocol 1 peers now.** Friends who have not updated could no longer reach those who have;
  the owner asked for compatibility.

## Consequences

- Until 2027-06-30 a pair with one protocol 1 side never uses direct Wi-Fi or an AES session, and a protocol 1 Rust
  helper receiving a copy over Bluetooth leaves the serving side unpaced, as before the pace.
- After that date, a peer still on a protocol 1 release has been out of date for over seven months.

## Verification

Comments, documentation and names only: `make mac-app`, the Friends core crates (`cargo build --release` of
`szfriends-wire`, `-crypto`, `-core`, `-online`, `-helper`) and Shenzhen 3D's Android fast test APK compile, and
`make friends-transfer-interop` (the released peers against today's helpers) passes.
