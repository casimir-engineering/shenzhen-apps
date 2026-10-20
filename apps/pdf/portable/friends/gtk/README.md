# Shenzhen Friends GTK views

The GTK 4.22 and libadwaita 1.9 views of Shenzhen Friends, in C, for Shenzhen Files now and ShenzhenPDF's Linux
frontend later. They render [PROTOCOL.md](../PROTOCOL.md) snapshots and send intents through
[`client/szfriends_client.h`](../client/szfriends_client.h) only; they never include `service/`, `mac/`, AppKit or a
reader header (`tests/containment-check.sh` fails on any). The plan they follow is Shenzhen Files'
`docs/friends-integration.md` § 3.1.

## Files

The core:

- `szfriends_gtk.h`, `szfriends_gtk_host.h`: the host's API and contract (`SZFriendsGtkHost`, versioned by
  `struct_size`).
- `szfriends_gtk_link*.{c,h}`: one client per process on the GLib main loop. The descriptor watch is re-armed on every
  state change, a timeout runs the ticks, subscriptions go out again after each READY, replies are routed by id and
  run once, and one `badge` subscription serves every window.
- `szfriends_gtk_snapshot.{c,h}`, `szfriends_gtk_schema.{c,h}`: every view, frame and result the views read, as plain
  structs parsed by one walker from field tables type-checked at compile time (the frames and results are in
  `szfriends_gtk_snapshot_frames.h` and `szfriends_gtk_schema_frames.h`).
- `szfriends_gtk_actions.{c,h}`, `szfriends_gtk_text.c`: actions and attachments to intents (which id each action
  takes), Settings pages, and rich-text segments as text with a `PangoAttrList`.
- `szfriends_gtk_drops.{c,h}`: `GdkFileList` and host types to items; folders, links and special files refused with
  the helper's words (`drop_folders_refused`, `drop_not_a_file`); "Send 2 files to…".
- `szfriends_gtk_avatars.{c,h}`, `szfriends_gtk_avatar_view.c`: the animal set's manifest, and avatars drawn from its
  SVGs (GtkSvg), the helper's photos or initials. A photo is read only from directly inside `<state>/pictures/`,
  without following a link, at most 256 KiB and 1,024 px a side, and decoded on a worker thread.
- `szfriends_gtk_button.c`: the menu button, badge overlay, drop target, spring-loading after 500 ms; refused files
  get the helper's refusal, never the drop hint.
- `szfriends_gtk_dropdown*.{c,h}`, `szfriends_gtk_page.c`: each window's popover (autohide off), its
  `AdwNavigationView` of pages, per-window state, Escape.
- `szfriends_gtk_pages_builtin.c`: registers the pages below for every link.
- `szfriends_gtk_glyphs.{c,h}`: the route icons, the check and the circle with a slash, from the AppKit views' paths.
- `szfriends_gtk_style.c`, `szfriends_gtk.css`, `szfriends_gtk.gresource.xml`, `icons/`: the resource, the two-people
  symbolic icon and the `@szfriends_*` colour tokens.
- `gtk.mk`: `friends-gtk-lib` (`libszfriends_gtk.a`: views, client library, cJSON) and the four suites below.

The pages:

- List and Nearby (`szfriends_gtk_list_page.{c,h}`, `szfriends_gtk_list_page_private.h`, `szfriends_gtk_list_*.c`,
  `szfriends_gtk_nearby_page.c`): the root page with search, the Friends and Nearby tabs, the notices above the rows
  and the footer. `szfriends_gtk_list_style.c` holds the pages' stylesheet and `szfriends_gtk_list_support.c` what
  every page else shares: the one table of ways out of the views (`SZFriendsGtkSeams`: clipboard, URIs, Settings'
  dialog, the image chooser), the one confirmation (`szfriends_gtk_confirm`: a card over the dropdown, a dialog in Settings) and running an action
  (`szfriends_gtk_perform`).
- Rows (`szfriends_gtk_row.{c,h}`, `szfriends_gtk_row_private.h`, `szfriends_gtk_row_*.c`): a person's row, its
  display-free look, its drops, Accept, Decline and Block, and its menu (`szfriends_gtk_row_menu.c`, PROTOCOL.md
  list_row `menu`, capability `list.menu`): Remove on a right-click, a long press, the Menu key or Shift+F10, and
  Delete on the focused row; the row leaves the list as soon as the person confirms, and comes back if the helper
  refuses. A row of someone nearby (Nearby's people, a friend seen nearby) says how they were found (PROTOCOL.md
  `found`, capability `nearby.found`): the route icon of each method, then the helper's words, before the subtitle. Rows are reused by position, so a press or a drag
  belongs to the person who held the row when it began, and completes for nobody else. `szfriends_gtk_row.h` also
  holds the arming rule every Block in the views shares (`szfriends_gtk_arming_*`, never a double-click's second half)
  and its clock seam (`szfriends_gtk_set_clock`).
- A conversation (`szfriends_gtk_conversation*.{c,h}`, `szfriends_gtk_message*.c`, `szfriends_gtk_transfer.c`,
  `szfriends_gtk_composer*.{c,h}`, `szfriends_gtk_mention_card*.c`): the history, transfer cards with previews,
  the composer with its `#` and `@` pickers, and the card for someone mentioned.
- A friend's details, your profile and the Settings section (`szfriends_gtk_details_page.{c,h}`,
  `szfriends_gtk_details_*.c`, `szfriends_gtk_profile_page.c`, `szfriends_gtk_settings_section.c`), with the crop step
  for your own photo (`szfriends_gtk_crop.{c,h}`) and the QR code of your ID (`szfriends_gtk_qr.{c,h}`).
- Links (`szfriends_gtk_link_card.c`, `szfriends_gtk_profile_links.c`): the page a friend or download link opens on,
  with the helper's card, what a host calls for links (`szfriends_gtk.h` § Links), and Your links in the profile.
- Several computers (`szfriends_gtk_devices.h`, `szfriends_gtk_join_page.c`, `szfriends_gtk_list_devices.c`,
  `szfriends_gtk_profile_devices.c`, `szfriends_gtk_snapshot_devices.h`, `szfriends_gtk_schema_devices.h`): the join
  page a new computer shows, the list's join requests and "This computer was removed" notice, the name prompt's "Use
  my existing profile", and Your computers in the profile (PROTOCOL.md § Devices, § Joining).

## Adding a page

The shell owns placement, the back arrow (top left, with the waiting count), the centred title, navigation, Escape
and lifetimes. A page registers a `SZFriendsGtkPageClass` for its kind in `szfriends_gtk_pages_builtin.c`
(`szfriends_gtk_register_page`) and fills the frame it is given:

- `build` sets the content and bars, and the title (`szfriends_gtk_page_set_title`, plain text) once a snapshot says it;
- `presented` subscribes when the page is on screen and releases when it leaves, since `open_conversation` marks a
  conversation read while held;
- `escape` returns TRUE when it closed something of its own (a picker, an armed pill), so Escape never navigates back;
- strings come from snapshots or `szfriends_gtk_link_string()`, set with `gtk_label_set_text`, never as markup;
- actions run through `szfriends_gtk_perform` and a Block arms through `szfriends_gtk_arming_*`; the clipboard, URIs,
  dialogs and the image chooser go through `SZFriendsGtkSeams` (the conversation's links still have an opener of
  their own), so the suites drive them on one clock with nothing on screen;
- secondary text uses `.szfriends-secondary` or `.szfriends-caption` (`@szfriends_secondary_text`, 4.9:1 on white),
  never libadwaita's `.dimmed`, whose 3.2:1 is under the 4.5:1 small text needs; flat text buttons in a column carry
  `.szfriends-text-action`, so their words start at the column's edge.

Navigation, drafts, scroll positions, the send picker and the drop hint live on the window's
`SZFriendsGtkDropdown` (`szfriends_gtk_dropdown.h`), so they survive closing and reopening.

## Tests

Four suites, each a display-free binary and a probe binary that renders offscreen in light and dark:

- `make -C portable friends-gtk-check`: `SZFriendsGtkTests` round-trips every fixture through the structs, compares
  the tables with PROTOCOL.md's schema blocks both ways, builds intents from every action in the fixtures, classifies
  drops on real files, checks which avatar photos may be read, and runs the link against the fake helper
  (reconnects, resubscription, reply routing, `connection_lost` once, the launch spawn). `SZFriendsGtkProbes` renders
  the icon, the button, the dropdown shell and avatars to `$(BUILD)/friends/gtk/renders/`.
- `friends-gtk-list-check`: `SZFriendsGtkListTests` checks the rows' look from the fixtures and the arming rule;
  `SZFriendsGtkListProbes` drives the list, rows, Nearby and the footer, including rows reordered under a drag or a
  held button and a live switch between light and dark, and renders to `$(BUILD)/friends/gtk/list/renders/`.
- `friends-gtk-conversation-check`: previews loaded only at the snapshot's size, and the conversation page, its cards'
  Block on the hand-moved clock, rendered to `$(BUILD)/friends/gtk/conversation/renders/`.
- `friends-gtk-details-check`: the crop square, which photos the views decode, the intents built from what was typed
  and the QR encoder; the probes drive details, profile and Settings, measure their secondary text's contrast and
  render to `$(BUILD)/friends/gtk/details/renders/`.

How the probes work:

- The probes open GDK's display but never map a window: widgets sit in a realized, unmapped `GtkWindow`, the probe maps
  the window's child itself, and a `GskRenderer` realized for the display draws the snapshot.
- An unmapped window's frame clock never runs, so GTK never restyles a widget after a change. Build each visual state
  (light, dark, highlighted) into a fresh widget before its first layout rather than toggling an old one. A probe of
  a live change (light to dark with the page open) emits the clock's update phase itself, which is GTK's next frame.
- Time that a person's clicks depend on (the double-click time, an armed pill's expiry) runs on the hand-moved clock in
  `tests/szfriends_gtk_list_probe_clock.c`, never real time.
- On macOS the probes link `tests/szfriends_gtk_quiet.c`, which interposes `TransformProcessType` so opening the display
  neither adds a Dock icon nor takes focus from whatever the person is using.
