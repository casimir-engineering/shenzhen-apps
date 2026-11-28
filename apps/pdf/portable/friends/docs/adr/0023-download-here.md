# ADR 0023: Download here

Status: Accepted (the owner's rule, 2026-11-28). Date: 2026-11-28.
Amends ADR 0014 § Files and § You (which files copy between one person's computers by themselves) and ADR 0016
§ Get after a deletion (now the only way any file copies). Areas: sync (`service/sync/SZFriendsSyncFiles.m`, core-rs
`sync/files.rs`), presentation (the catalog's `transfer.action.fetch`, the You file's states), both helpers' device
file facts (`SZFriendsNearbyService+Devices.m`, helper `service/device_files.rs`, `service/devices.rs`). Client
contract: PROTOCOL.md § Devices, Files another computer holds and You.

## Context

The owner, 2026-11-28: "avoid auto-downloading a file to another device like you do now, the user should have the
choice of downloading it or not to his other device. just a 'download here' button on the file". Until now a file
another of the person's computers held copied to every other computer by itself when it was 25 MB or less, and
whatever its size in You; larger ones waited for Get.

## Decision

**Nothing copies by itself.** A file one of the person's computers holds (sent to You there, or received from a
friend there) is listed on every other computer at once, as before: its name, size, kind, and "On Raph’s Mac mini".
Its bytes copy to a computer only when the person presses **Download here** on that computer (`fetch_from_device`,
the action formerly labelled Get), whatever the file's size or conversation. Download here starts the copy Get
started (ADR 0014's WANT/PART/NONE, or a pull by blocks, ADR 0018 § 9.6): progress, Cancel and resume are unchanged.
Once the copy is whole the item is `received`, with Open and Show. `filesWanted` / `files_wanted` holds only what the
person asked for here (the `want/<transfer id>` sync state, which never syncs); `SZFriendsSyncCopiesAutomatically`,
`SZFriendsSyncAutoCopyMax`, `copies_automatically` and `AUTO_COPY_MAX` are gone.

**The computer that has the file** serves it exactly as before. Its You item says what is now true from there:
`queued` "Shows on your other computers when they connect" until every other computer holds an event that carried
the file, then `delivered` "Ready to download on your other computers" (Open and Show, nothing to cancel), `sending`
"Copying to your other computers · 40%" while one of them downloads it, and `delivered` "On all your computers" once
every one holds the bytes. The new facts set (`youItemsListed` / `you_items_listed`, from
`itemsListedOnEveryDeviceInConversation` / `items_listed_on_every_device`) is the item set those first two words need.

**Upgrade.** An automatic copy queued or half done when a computer updates was never recorded as asked for, so after
the update it is listed with Download here and nothing is pulled. What already arrived stays in
`received/.partial/`, and Download here resumes from it. Files already copied stay where they were saved.

**Mixed versions.** No wire change, no capability bit. A copy is always the receiving computer's request (WANT, or a
pull's tree request), so each computer decides for itself: an updated computer pulls nothing until Download here; a
computer on a released helper (Friends protocol 1, ADR 0024; ADR 0014 as it was) keeps pulling files up to 25 MB and You files
by itself, and an updated computer serves it as before. A file sent to You from a released helper says "Copies to
your other computers when they connect" there until an updated computer downloads it.

## Alternatives considered

- **A setting to keep automatic copies.** Not asked for; the rule is the person chooses per file. It can come later
  as a setting that writes the same `want/` state.
- **A wire flag so senders stop offering.** Senders never offered: copies are requests from the receiver, so the
  change is local to each receiver and needs nothing from older peers.

## Consequences

- A file sent to You is not on the other computers' disks until the person asks there; while the computer that has
  it is away, Download here waits ("Copies when Raph’s Mac mini is nearby with … open").
- The sender's own copy, or the file it was sent from while unchanged (ADR 0016), keeps serving the others for as long
  as it is there; deleting it there with no other computer holding it leaves the others nothing to download.
- No thumbnail travels with a listed file: the item shows its type's icon until it is downloaded.

## Verification

`friends-sync-check` (nothing wanted until asked, small, large or in You; a copy after Download here; resume after a
cut), `friends-presentation-check` and the core's `presentation_devices` (the `devices-*` fixtures with "Download
here"), `friends-e2e-devices-check` (a You file listed with Download here, "Ready to download on your other
computers" on the sender, copied after Download here), the core's `sync_release`, the helper's `devices` and the
interop `you_copies`, `again` and `pulls` tests (each presses Download here before a copy).
