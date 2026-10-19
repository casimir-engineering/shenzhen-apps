# Shenzhen Friends: friend links and download links

Status: planned 2026-10-13; amended the same day with the M2 decisions (ADR 0009 to 0011, lead decision 10 in
`portable/friends/docs/m2-decision-brief.md`). Owner: lead integrator. Builds on
[shenzhen-friends.md](shenzhen-friends.md) (Friends host, online friends, transfers) and needs online friends (M2),
the Internet transport, which links reuse. Order: Shenzhen Files host (wave 6), online friends (wave 7), links
(wave 8), then multi-device.

## What people get

- **Friend link.** Profile → **Your friend link** → Copy. Whoever opens it lands on a page: "Mei invited you to
  Shenzhen Friends", with **Open in ShenzhenPDF**, **Open in Shenzhen Files** and **Open in Shenzhen 3D**. Each app
  opens its Friends panel on a card, "Add Mei? Friends ID brave-otter", with **Add**. Because Mei made the link, Mei's
  app accepts automatically, and both sides show "Added through Mei's link". The QR in the profile carries the same
  link, so a phone camera opens the page too.
- **Download link.** Copy Download Link on a document: in ShenzhenPDF from File ▸ Share, the tab's menu, or the
  Friends button's drop panel; in Shenzhen Files from the file's context menu; in Shenzhen 3D from File ▸ Copy
  Download Link. The page shows the file's name, size and thumbnail once it reaches the sender's computer, with
  **Open in ShenzhenPDF**, **Open in Shenzhen Files**, **Open in Shenzhen 3D** and **Download**. Download streams the
  file straight from the sender's computer to the browser, peer to peer, on any computer or phone, no app needed.
- The page remembers which app you chose. It explains, for someone who has never heard of these apps, what they are
  and links to them. On Windows and Linux it offers only Shenzhen 3D, the app with Friends there; on a phone, whose
  Shenzhen 3D reaches friends only nearby, friend links say where Friends works and download links offer Download.
  Since a download link's sender may be on a Mac, a PC or a Linux computer, the page names the sender rather than
  their Mac ("Waiting for Mei").
- **Your links** in the profile lists each download link with its file, downloads so far, expiry and **Revoke**,
  and the friend link with **Reset link**, which stops the old one working.

## Rules

- **Download links work while the sender's computer is on** with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open,
  since the file comes from there. The page says so plainly while it waits: "Waiting for the sender. The file comes
  once the sender has ShenzhenPDF, Shenzhen Files or Shenzhen 3D open." (The link carries no name; the page names Mei
  once the file's details arrive.) Links expire after 7 days by default (1 day, 7 days or 30 days when
  copying), and Revoke ends one at once. A revoked or expired link says so at once ("Mei stopped sharing this file",
  "This link has expired") for 31 days afterwards, even while Mei's Mac is off: the helper keeps a hash of the link's
  id and why it ended, and the host answers from it.
- **The file is fixed when the link is made, at any size.** The helper keeps an APFS clone of the exact bytes,
  which takes no extra disk space, deleted when the link expires or is revoked; later edits never change what the
  link delivers. Where a clone isn't possible (another volume, a file system without clones), it records the file's
  size, date and SHA-256 instead of copying it, and serves the original only while it is unchanged; if it changed,
  the page says "Mei changed this file after sharing the link" and the download stops before any byte arrives.
  There is no size limit.
- **Friend links** carry the Friends ID, the identity key, the name Mei chose and an invite token. A request that
  presents a valid token is accepted automatically, at most 20 a day per link (past that it waits for Mei, so a link
  that leaks cannot make friends of strangers faster), and works online as well as nearby; links stay valid until
  Reset (or 30 days for a one-time link, an option when copying). Comparison codes stay unverified until compared, as
  with Add by ID; the key in the link means the request completes only with Mei, never whoever holds that ID later.
- **Received through a link** in an app: the file lands in Friends' received folder like any transfer, the app
  opens it (ShenzhenPDF) or shows it (Shenzhen Files), and the Friends list gets a row for the sender, "Sent you
  Site photos.pdf through a link", with Add if you aren't friends. Nothing is accepted automatically except the one
  file you clicked for.

## How it works

- **Link format.** `https://<link origin>/f#<payload>` and `https://<link origin>/d#<payload>`. The origin is the
  main Friends host's web origin, named in the signed host list (`links` entry) so a replacement host can serve old
  links. Everything secret sits after `#`, which browsers never send to the server. A download payload holds a
  public link id and a 32-byte secret, exactly 49 bytes with the version, and no name: the sender's name travels only
  inside the sealed metadata. The page sends only the link id to the host.
- **Pages.** Static HTML, CSS and one script served by the Friends host from `/f` and `/d`: no third-party code, no
  analytics, no cookies; `Content-Security-Policy` allowing only itself and its WebSocket; `frame-ancestors 'none'`;
  `Referrer-Policy: no-referrer`; names and file names set as text, never markup. The pages are part of the host's
  source tree and tests.
- **Apps.** ShenzhenPDF registers `shenzhenpdf:`, Shenzhen Files `shenzhenfiles:` and Shenzhen 3D `shenzhen3d:`
  (CFBundleURLTypes). The page's buttons open `shenzhenpdf://friends/link#<payload>`, `shenzhenfiles://…` or
  `shenzhen3d://…`; each app validates the payload strictly and hands it to the shared helper. The apps share one
  helper and one profile, so any of them gives the same result.
- **Signalling.** The sender's helper registers each live download link with the host over its existing
  connection: an expiring record from link id to that connection, holding nothing about the file. A browser or a
  helper opening the link connects to the host with the link id; the host forwards connection setup between them
  and stores nothing. Every setup payload between the opener and the sender's helper is sealed under a key derived
  from the link secret (HKDF-SHA-256, AES-256-GCM in WebCrypto), so the host can neither read it nor swap the DTLS
  fingerprints both sides send inside it. Before anything about the file is sent, and before the sender's helper
  creates any peer connection, the opener proves it holds the secret with an HMAC over a challenge from the sender,
  which the host can't compute (ADR 0009 § Who may reach the stack).
- **Browser transfer: WebRTC.** A data channel between the sender's helper and the browser, with ICE over the same
  techniques as online friends (host-run STUN, IPv6, port mapping, hole punching), except that the sender's helper
  never offers a browser a private or link-local address: only global IPv6 host candidates beside server-reflexive
  and relay ones, because libdatachannel does not hide local addresses behind mDNS names as browsers do and anyone
  holding the link would learn them. Last resort, as always: the host's TURN relay (coturn, 5 Mbit/s per session,
  counted in relay statistics), with credentials issued for that link session only. Content is encrypted end to end
  on top of DTLS, under a key derived from the link secret: AES-256-GCM per chunk with the chunk index in the nonce
  and a final-chunk flag, each sealed record at most 64 KiB on the wire (one data-channel message, the largest every
  browser accepts), and metadata (name, size, type, SHA-256, thumbnail as PNG) in its own sealed record.
- **Integrity without holding the file.** WebCrypto has no incremental SHA-256, and digesting the whole file at the
  end held 511 MB for a 200 MiB file in the stack spike. The page hashes chunk by chunk in JavaScript instead: each
  decrypted chunk goes into the page's own incremental SHA-256, and the result is checked against the metadata's
  SHA-256 before the download completes.
- **Downloads that outlast a connection.** A connection that drops mid-file (the relay ends each session after an
  hour; networks change) does not lose the download: the page, or the app, connects again with a fresh key and
  carries on from the last chunk it verified and wrote, so a file of any size finishes, through the relay too. The
  page says "Reconnecting" meanwhile and keeps its progress.
- **Saving in the browser.** Chromium streams to a file the person picks (File System Access); others stream
  through a service worker download. A browser that can do neither keeps the file in memory until it is saved, so
  for files larger than it can hold the page says before starting to use another browser or one of the apps.
- **Helper stack.** One WebRTC/ICE stack in the helper serves both online friends and browsers: libdatachannel
  (MPL-2.0) with libjuice and usrsctp, statically linked against Mbed TLS, which keeps the helper free of Homebrew
  and OpenSSL dylibs, behind the helper's own transport interface (`friends/service/online/SZFriendsOnlineTransport.h`).
  Chosen in ADR 0009 after the online-friends spike.
- **App transfer through a link.** The opener's helper reaches the sender's helper by the same rendezvous and the
  online-friends transport, proves the secret inside the Noise handshake, and receives the file through the normal
  transfer code (digest check, quarantine, thumbnail replaced locally).

## Host

- New routes on the existing service: the pages, link registration, link signalling and TURN credentials for link
  sessions. Limits per Friends ID (50 live download links, 500 opens a day) and per address; the admin dashboard
  shows links made, opens, downloads by browser or app, relay use, and can switch links off for one Friends ID.
- Stores no file, no file name, no link secret; logs no addresses, as today. Link bindings survive a host restart,
  stored by hash: the SHA-256 of the link id with the sender's keyed identity hash and the expiry, never the link id
  itself (ADR 0010 § Download links).
- STUN and TURN on meerkat open UDP 3478 and a bounded relay port range; recorded in DEPLOY.md and the server notes.

## Verification

- Link payloads: malformed, oversized, wrong-type and replayed payloads refused by both apps; scheme handlers never
  act without the card; invite tokens accepted only while valid, Reset revokes, one-time links work once.
- Download: a browser stand-in (node-datachannel) and real headless Chromium against a local host: direct, via
  TURN only, wrong secret refused before metadata, tampered chunks and truncation detected, revoked and expired
  links refused, no peer connection on the sender before the proof, no private or link-local candidate offered,
  setup payloads that fail to open under the link key refused, every data-channel message at most 64 KiB, the
  chunk-by-chunk hash matching for files larger than the browser could hold, sender offline then online, files
  past 4 GB (sparse test files, no 32-bit sizes or counters
  anywhere), a non-clonable source changed after linking, a download that keeps dropping carrying on from its last
  written chunk (an artificially short relay session limit), revoked and expired links said at once, and file names
  with bidi controls shown and saved with their real extension.
- Pages: CSP, no network calls beyond the host's WebSocket, no fragment in any request (checked in the browser's
  network log), text-only rendering of hostile names and file names, light and dark, phone width.
- Manual matrix: Safari, Chrome and Firefox on macOS, Safari on iPhone, Chrome on Windows and Android; across the
  border (mainland network ↔ Hong Kong host), as for online friends.
- Independent security review (capability URLs, signalling, TURN abuse, scheme handlers, browser crypto) and UX
  critique of both pages for a first-time visitor.
