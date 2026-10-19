# Friends pictures

Everyone in Shenzhen Friends has a picture: a cartoon animal from the bundled set, picked at random at first
launch, or their own photo. An animal travels as its set version and index, so every app draws it from its own
copy; a photo travels as one small re-encoded JPEG. The interface is [`SZFriendsAvatars.h`](SZFriendsAvatars.h);
the wire format is in [PROTOCOL.md](../PROTOCOL.md) (avatar objects, `set_picture`) and ADR 0001 (PROFILE frames).

| Path | What |
|---|---|
| `animals/svg/NN-name.svg` | The animals, hand-written SVG. The source of truth: GTK draws these directly |
| `animals/pdf/NN-name.pdf` | Generated for AppKit, one 64 x 64 pt page each. Committed; never edit by hand |
| `animals/manifest.json` | Generated: set version, count, per-index name, color, SVG and PDF paths |
| `animals/pdf/sources.sha256` | Generated: the SVG hashes the PDFs were made from, so the suite notices a stale PDF |
| `tools/regenerate-pdfs.sh` | Rebuilds the three generated kinds of file from the SVGs (needs `rsvg-convert`) |
| `tools/SZFriendsContactSheet.m` | Draws every PDF at 64 and 28 px, light and dark: `preview/contact-sheet.png` |
| `SZFriendsPicture.m`, `SZFriendsAnimalSet.m` | Picture value, set, initials, placeholder colors (views too) |
| `SZFriendsPicturePipeline.m`, `SZFriendsPictureIntent.m` | Photos in, `set_picture` parsing (helper only) |
| `SZFriendsJPEG.c`, `SZFriendsImageEnds.c` | Byte checks in front of ImageIO (`SZFriendsImageBytes.h`) |

## The animal set

Set 1 has 24 animals. Indexes are permanent: a friend on an older app draws an animal by its index, and an index
it lacks becomes a placeholder. Never renumber, reuse or recolor a shipped index. The colors of indexes 0, 1, 3,
4, 5, 7, 9, 10 and 11 are also fixed by the golden fixtures (`SZFriendsAvatars.h` lists them).

**Style.** Every animal follows the same rules, so a new one sits beside the others without looking borrowed:

- A 64 x 64 canvas: `width="64" height="64" viewBox="0 0 64 64"`, then the background circle exactly as
  `<circle id="bg" cx="32" cy="32" r="32" fill="#rrggbb"/>`, then the character in a group clipped to that circle
  (`<clipPath id="c">`). The script and the suite read the color from that line.
- The circle is a muted mid-dark color that keeps white initials at 4.5:1 or better (the placeholder fallback
  draws white initials on it); the suite checks the contrast.
- A head-and-shoulders bust facing forward, filling most of the circle, shoulders running off the bottom edge.
- Flat fills, no outlines, no gradients, no text, no images, no external references. One lighter or darker tone
  of the main color for inner ears, muzzles and bellies.
- Ink `#2b2233` for pupils, noses and mouths. Eyes are ink ovals about 6 x 7 units with a white highlight at
  their upper right, or closed arcs for sleepy and happy faces. Cheeks are `#ff8fa3` ovals at 0.6 to 0.8 opacity.
- One joke per animal (the goose mid-honk, the capybara's orange, the sloth's sleep bubble), big enough to read
  at 28 px. If it vanishes at 28 px, it is not part of the drawing.
- The character's main colors contrast with the circle, so it reads on light and dark backgrounds alike.

**Adding an animal.** Write `animals/svg/NN-name.svg` with the next index, then:

```sh
portable/friends/avatars/tools/regenerate-pdfs.sh      # PDFs, manifest, checksums
make -C portable friends-avatars-preview               # contact sheet: look at it at 28 px
make -C portable friends-avatars-check
```

Bump `SET_VERSION` in the script when a release adds animals, so friends on older apps know to fall back.

**Tools.** `rsvg-convert` 2.62.3 (librsvg, LGPL-2.1-or-later, Homebrew `librsvg`, cairo 1.18.4) generated set 1.
It is a maintenance tool only: nothing ships it and the build never runs it. The script pins
`SOURCE_DATE_EPOCH`, so regenerating unchanged SVGs changes no PDF. The suite's 66-byte WebP sample was made once
with ImageMagick 7.1.2 (ImageIO reads WebP but cannot write it). No file was downloaded.

## Photos

The helper alone decodes photos (`SZFriendsPicturePipeline`); reader windows only ever draw JPEGs the helper wrote.

- Accepted: JPEG, PNG, HEIC/HEIF and WebP, at most 5 MiB and 8,192 px on a side, checked from the file's header
  before anything is decoded. Pictures declaring over 4 megapixels with more than 1,024 pixels per byte are
  refused as decompression bombs. Truncated files are refused (ImageIO would fill the gap with gray).
- Decoded no larger than the crop needs (at most 2,048 px), EXIF orientation applied; the crop is a square in
  displayed pixels, origin top left; transparency becomes white.
- Output: 256 x 256 baseline sRGB JPEG, at most 48 KiB (quality steps down from 0.85 until it fits), with no
  metadata segment at all, the same bytes for the same pixels. Stored as `<sha256>.jpg` in the helper's pictures
  directory, mode 0600.
- Received from a friend: only a baseline 256 x 256 JPEG of at most 48 KiB passes, checked from its markers
  before ImageIO parses it, then decoded and re-encoded the same way.

Error messages are written for the person choosing their own picture and passed through as the reply's
`error.message`; userInfo carries the PROTOCOL.md code (`invalid_field`, `picture_invalid`, `file_missing`,
`internal`) and the field.

## Where an app keeps the set

`<App>.app/Contents/Resources/Friends/animals/` holds `manifest.json`, `svg/` and `pdf/`. A helper app inside
`Contents/Helpers/` reads its host app's copy. `SZFRIENDS_AVATARS_MANIFEST` (absolute path) overrides the lookup
for helpers run outside a bundle, such as the two-helper harness.
