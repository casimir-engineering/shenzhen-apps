# ADR 0008: File previews before acceptance

Status: Proposed, 2026-10-13. It records what wave 6a built; the lead accepts it when committing.
Brief: § Transfers, Thumbnails before acceptance; release gate "File previews". Areas: thumbnails (owner:
`service/thumbnails/`), session (the THUMBNAIL frame), store (keeping and deleting previews), helper (when previews are
made, sent and kept), presentation (`thumbnail` in snapshots).

## Context

Someone deciding whether to accept a file wants to see what it is: the first page of a PDF or document, the photo, a
frame of a video. The file itself must not move before they accept (ADR 0001, Files), and nothing a friend sent may be
rendered on the recipient's Mac before acceptance (brief § Transfers). So the picture has to be made on the sender's
Mac, travel as untrusted bytes, and be checked and redrawn by the recipient's helper with code small enough to review
and fuzz. Every Mac has a different set of previewers (QuickLook generators for Office, video and so on), and a later
Linux helper will have none of them, so the platform part has to be replaceable. The pictures must also go away with
the offers they belong to.

## Decision

**Render on the sender, behind one interface.** `SZFriendsThumbnailRenderer`
(`service/thumbnails/SZFriendsThumbnails.h`) takes a file, its type identifier and a largest side, and calls back once
with RGBA pixels (8 bits per channel, straight alpha, rows top to bottom) or nil; it returns a block that stops the
render. On macOS, `SZFriendsQuickLookRenderer` asks QuickLook's thumbnail generator for a real thumbnail only, never the
file-type icon, so a format the Mac cannot draw yields nil and the views draw the type icon themselves. Everything after
the pixels is portable C99 (`szfriends_image.h`: fitting and area-average downscaling; `szfriends_qoi.h`: the codec; a
PNG writer), so a Linux helper supplies only a renderer. `SZFriendsThumbnailMaker` runs at most two renders at a time
off the helper's queue, each given 2 seconds; when the time runs out it stops the render and drops any late picture, so
a hostile file cannot keep QuickLook busy for the helper. A preview never delays its offer: the OFFER goes as soon as
the file is bound, and a picture not ready in time is simply not sent.

**One small format: QOI.** The picture travels as QOI ("Quite OK Image", specification 1.0): a 14-byte header, four
opcodes and an 8-byte end marker, decodable in a few hundred lines this repository owns. The decoder is stricter than
the reference: a stream that ends before its last pixel, a run past it, a missing or misplaced end marker, or bytes
after it fail, because an honest encoder never writes them. The cache holds a PNG the helper writes itself from the
decoded pixels (stored deflate blocks, no compression), so no system image codec ever reads bytes a friend sent, and
views only ever load that local file.

**Limits.** At most 192 pixels on the longer side, and at most 64,000 bytes of QOI, so a THUMBNAIL frame with its id,
width and height fields fits one session frame (65,519 bytes). The encoder fits the picture to 192 and, when the QOI is
too large, tries 160, 128, 112, 96, 80, 64, 48 and 32; nothing is sent when even 32 does not fit. A renderer's pixels
are accepted only from 1 to 4,096 on a side. These are in `SZFriendsThumbnails.h` and PROTOCOL.md § Limits (File
preview).

**On the wire.** THUMBNAIL is session frame type 23, fields ID (the offer's), Width (tag 30, u16be), Height (tag 31,
u16be) and Data (23 to 64,000 bytes of QOI) (`service/session/SZFriendsSession.h`). It belongs to session minor 1, so it
is sent only to a peer whose range reaches minor 1: an older helper would close the session on an unknown type and the
sender would resend on every reconnect. It goes in the channel's chunk queue, so messages typed after a drop overtake
up to 64 KB per file over Bluetooth. It is sent only after its OFFER was written or acknowledged, and only while the
offer is queued or offered; once the offer is answered, nothing more is sent, so a preview can never follow its
file's DONE. The sender keeps the QOI with the offer (store, below) until the friend's Mac acknowledges it, so the
outbox delivers it on a later session too.

**What the recipient keeps, and what it refuses.** At most one picture per offer from that friend, while the file has
not arrived (waiting for an answer, or receiving: an offer accepted automatically still gets its picture before the
file lands). Before anything is allocated the helper checks the frame's declared size against 64,000 bytes, both
declared sides against 1 to 192, and that the QOI header agrees with them (the same area in another shape is refused);
then it decodes strictly and writes the PNG. Refused, changing nothing: a picture for an offer that is not waiting or
receiving (unsolicited, late or a second one), for another friend's offer or for one of our own outgoing ids, from
someone blocked or not a friend, and anything that fails a check. The recipient acknowledges every THUMBNAIL that passes
the codec, kept or refused, because acknowledgements that share an offer id are matched oldest first (ADR 0001,
Corrections): a missing one would settle the transfer's own acknowledgement early.

**The sender's word, then the file's.** The picture is the sender's claim about the file, not proof. Once the file
arrives and its digest checks, a picture made on this Mac from the real file replaces it (`source` `local`); when this
Mac cannot preview the format, the sender's picture goes and the type icon shows. Snapshots never show the sender's
picture on a received file. The sender shows its own picture on its own item, also with `source` `local`.

**Where previews live, and when they go.** Schema v6 adds `transfer_thumbnails` (ADR 0003, Corrections): one row per
transfer, cascading with it, naming a PNG in `<state>/thumbnails/` and, on the sending side, holding the QOI until
acknowledged. File names are random and chosen by this Mac, never derived from the sender's transfer id (APFS folds
case, and the id is the sender's choice); files are written 0600 in a 0700 directory, created exclusively without
following a link. Previews are deleted in the store's one state-change function, in the same transaction as the
change: when a transfer is declined or cancelled, or fails before anyone accepted it (from queued, offered or waiting
for you), on both sides. Removing or blocking someone declines their offers still waiting, so those pictures go at once
rather than when the offers expire. Delete history and Reset Friends delete pictures with their transfers (Reset removes
`thumbnails/`), and at start the helper deletes files in `thumbnails/` that no row names (a crash between writing and
recording, or an older helper's deletes).

**Views.** A transfer item's `thumbnail` gives `path`, `width`, `height` and `source` (PROTOCOL.md § Thumbnails). Views
lay the item out from `width` and `height` before loading, load only `path`, and treat a missing or unreadable file as
no preview. Without one they draw the type icon locally: AppKit from `file.type_identifier`, GTK from
`file.extension` through its content type. They never load anything else a friend sent.

## Alternatives considered

- **PNG, JPEG or HEIC on the wire, decoded with ImageIO or GdkPixbuf**: smaller, but a general image library parsing
  bytes from a stranger's helper before acceptance is the surface this feature must not add, and each platform's
  decoder differs.
- **WebP or AVIF**: better compression for the same reasons as above, with far larger decoders to own or trust.
- **The picture inside the OFFER**: offers would grow by up to 64 KB and wait for a render, and a slow QuickLook would
  delay the offer itself.
- **Render on the recipient after acceptance only**: no preview before acceptance, which is the point of the feature.
- **The system's thumbnail cache (QuickLook's own) on the recipient**: it would render the received file with whatever
  generators the Mac has before the person opens it; the local replacement does the same only after acceptance and the
  digest check.
- **Compressed PNG in the cache**: about a third of the size, at the cost of a deflate encoder to review; the cache is
  small (at most about 148 KB per picture) and short-lived.

## Consequences

- The recipient's helper runs QuickLook on every received file to make the local picture (out of process, sandboxed,
  no network observed in the security review): accepted, since the file was accepted and its digest checked.
- Office documents and video depend on the QuickLook providers of each Mac; the automated tests cover PDF, Markdown, an
  image, a text file and an unknown binary, and the rest belong to the hardware matrix.
- A received file that crashed mid-publish gets no local replacement (it shows the type icon); an offer retried after
  it failed before acceptance gets no new picture; a helper restarted before a picture was made sends that offer
  without one.
- No automated test makes a peer speak only minor 0; the rule is one guard on the negotiated minor, and the
  negotiation itself is tested.

## Verification

- `friends-thumbnails-check`: the codec (the reference encoder's exact bytes included) and every refusal above, the
  PNG writer read back by ImageIO, fitting and the size steps, the maker's timeout and cancel, the renderer on real
  files, and a replay of the whole fuzz corpus under AddressSanitizer and UndefinedBehaviorSanitizer.
- `friends-thumbnails-fuzz` (`FRIENDS_FUZZ_SECONDS` per target, default 600; libFuzzer where the compiler has its
  runtime, a mutation driver otherwise) over the QOI decoder and the session frame parser with the THUMBNAIL path;
  `friends-thumbnails-fuzz-seeds` regenerates the seeds. The corpus is kept in `service/thumbnails/fuzz/corpus/`.
- Store suite: schema v6, the deletion rules, the sweep at start, Delete history and Reset.
- Two-helper harness: previews before acceptance, replaced after the digest, gone on decline and cancel; unsolicited,
  oversized, malformed and second previews refused.
