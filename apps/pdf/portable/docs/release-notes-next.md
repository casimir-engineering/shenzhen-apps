# Release notes

User-facing notes for changes merged since the last release (26.11.5 build 1).

Release notes are tracked in `portable/docs/releases/`. Prepare the next release
with `./portable/cut-release.sh --prepare-only ["summary"]`; publish the
validated metadata from master with `./portable/cut-release.sh --publish`.

How to write them: [docs/RELEASE-NOTES.md](../../../../docs/RELEASE-NOTES.md). Only list what someone on the last
published release will notice; never a fix for a bug that was never released.

## Next release

- macOS no longer asks, each time ShenzhenPDF starts, whether it may "access data from other apps". A document you
  open from WeChat, Mail or another app is kept as ShenzhenPDF's own copy.
- Friends (Beta): the You row shows how your other computers are connected.

### Documents from other apps

A document opened from WeChat, Mail, Messages or Safari is copied into ShenzhenPDF when you open it, under the same
name, and its tab, recent items and Collection use that copy. macOS can still ask about the other app's files while
you are looking at such a document, when ShenzhenPDF checks whether the app has a newer version of it; if you don't
allow it, you keep reading the copy. If a tab has no copy and the document can't be read, it tells you to open the
document again from that app.

### Friends (Beta)

The You row now shows how your other computers are connected, as a friend's row does. If any of them goes through the
Friends relay, it shows the relay; point at the icon to see each computer and how it's connected. Your computers, in
your profile, shows the same under each computer.
