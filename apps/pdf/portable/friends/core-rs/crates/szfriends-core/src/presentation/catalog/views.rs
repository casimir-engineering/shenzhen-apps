//! The English catalog, part two (`SZFriendsCatalogViews.m`): transfers, requests, the composer and Nearby.

pub(super) const TRANSFERS_AND_CONVERSATIONS: &[(&str, &str)] = &[
    // Transfers
    ("transfer.meta", "{kind} · {size}"),
    ("transfer.left.spoken", "{duration} left"),
    ("transfer.disk_low.spoken", "There wasn’t enough free space to accept it automatically."),
    ("transfer.status.queued", "Sends when {first} is nearby"),
    ("transfer.status.queued_online", "Sends when {first} is online or nearby"),
    ("transfer.status.connecting", "Connecting to {first}…"),
    ("transfer.status.offered", "Waiting for {first} to accept"),
    ("transfer.status.waiting_for_you", "Waiting for you to accept"),
    ("transfer.status.disk_low", "Waiting for you. There wasn’t enough free space to accept it automatically."),
    ("transfer.status.sending", "Sending · {percent}%"),
    ("transfer.status.sending_timed", "Sending · {percent}% · {duration} left"),
    ("transfer.status.receiving", "Receiving · {percent}%"),
    ("transfer.status.receiving_timed", "Receiving · {percent}% · {duration} left"),
    ("transfer.status.delivered", "Delivered to {first}"),
    ("transfer.status.received", "Received"),
    ("transfer.status.received.saved", "Saved to {folder}"),
    ("transfer.status.declined.out", "{first} declined"),
    ("transfer.status.declined.in", "You declined"),
    ("transfer.status.cancelled", "Cancelled"),
    ("transfer.status.failed.out", "Not sent"),
    ("transfer.status.failed.in", "Didn’t arrive"),
    // Failure keys from the store (SZFriendsOutbox.h, SZFriendsTransfers.h); others keep the two lines above.
    ("transfer.status.failed.out.not_delivered_30_days", "Not delivered. Stopped trying after 30 days."),
    ("transfer.status.failed.out.refused", "{first} couldn’t receive this file"),
    ("transfer.status.failed.out.refused.removed", "Not sent because you removed {first}"),
    ("transfer.status.failed.out.refused.blocked", "Not sent because you blocked {first}"),
    // The version bound when it was sent is gone; sending the file again sends what is there now.
    ("transfer.status.failed.out.source_missing", "Not sent because this version of the file is no longer available"),
    ("transfer.status.failed.out.digest_mismatch", "Arrived damaged for {first}, so it wasn’t saved"),
    ("transfer.status.failed.in.digest_mismatch", "Arrived damaged, so it wasn’t saved"),
    ("transfer.progress.sending", "Sending, {percent} percent"),
    ("transfer.progress.receiving", "Receiving, {percent} percent"),
    ("transfer.spoken.in.waiting_for_you", "{sender} wants to send you {file}, {kind}, {size}{note}{extra}"),
    (
        "transfer.spoken.in.receiving",
        "{sender} is sending {file}, {kind}, {size}{auto}, {percent} percent received{left}",
    ),
    ("transfer.spoken.in.received", "{sender} sent {file}, {kind}, {size}{auto}, received"),
    ("transfer.spoken.in.received.saved", "{sender} sent {file}, {kind}, {size}{auto}, saved to {folder}"),
    ("transfer.spoken.in.declined", "{sender} offered {file}, {kind}, {size}, you declined"),
    ("transfer.spoken.in.cancelled", "{sender} offered {file}, {kind}, {size}, cancelled"),
    ("transfer.spoken.in.failed", "{sender} offered {file}, {kind}, {size}, it didn’t arrive"),
    (
        "transfer.spoken.in.failed.digest_mismatch",
        "{sender} sent {file}, {kind}, {size}. It arrived damaged, so it wasn’t saved",
    ),
    // States an incoming file never has; worded plainly in case the store reports one.
    ("transfer.spoken.in.queued", "{sender} offered {file}, {kind}, {size}"),
    ("transfer.spoken.in.offered", "{sender} offered {file}, {kind}, {size}"),
    ("transfer.spoken.in.sending", "{sender} is sending {file}, {kind}, {size}"),
    ("transfer.spoken.in.delivered", "{sender} sent {file}, {kind}, {size}"),
    ("transfer.spoken.out.queued", "You are sending {file}, {kind}, {size}. {status}."),
    ("transfer.spoken.out.offered", "You offered {file}, {kind}, {size}. {status}."),
    ("transfer.spoken.out.sending", "You are sending {file}, {kind}, {size}, {percent} percent sent{left}"),
    ("transfer.spoken.out.delivered", "You sent {file}, {kind}, {size}, delivered to {first}"),
    ("transfer.spoken.out.declined", "You offered {file}, {kind}, {size}, {first} declined"),
    ("transfer.spoken.out.cancelled", "You offered {file}, {kind}, {size}, cancelled"),
    ("transfer.spoken.out.failed", "You tried to send {file}, {kind}, {size}. {status}."),
    // States an outgoing file never has.
    ("transfer.spoken.out.waiting_for_you", "You offered {file}, {kind}, {size}"),
    ("transfer.spoken.out.receiving", "You are sending {file}, {kind}, {size}"),
    ("transfer.spoken.out.received", "You sent {file}, {kind}, {size}"),
    // Requests
    ("request.title.incoming", "{title} wants to be friends"),
    ("request.title.outgoing", "Request sent to {title}"),
    ("request.found_nearby", "Found you nearby"),
    ("request.by_id", "Sent to your ID"),
    ("request.sent", "Request sent"),
    ("request.sent_at", "Sent {moment}"),
    ("request.code_prompt.incoming", "Before you accept, check that {first}’s screen shows the same code."),
    ("request.code_prompt.outgoing", "Check that {first}’s screen shows the same code."),
    ("request.code_later", "A code to compare appears when you’re both online or nearby."),
    (
        "request.footnote.incoming",
        "Once you accept, {first} can message you and send you files. You decide on each file unless you turn on \
         automatic acceptance for {first}.",
    ),
    ("request.footnote.outgoing", "You’ll be friends once {first} accepts."),
    // An answer to the person's own Add by ID that the Friends server could not confirm: anyone nearby who heard
    // the request could have sent it, so it waits like a request (wave-4 security re-check, Add by ID).
    ("request.title.answer", "{title} answered your request"),
    ("request.asked_for", "You asked for {id}"),
    (
        "request.footnote.answer",
        "Friends couldn’t confirm that {id} belongs to {first}. Anyone nearby could have answered your request, so \
         accept only if the codes on both screens match.",
    ),
    // Composer
    ("composer.placeholder", "Message {first}"),
    ("composer.send", "Send"),
    // The hint under the composer, in words a newcomer follows: "Type # to attach, @ to mention someone, or drop
    // files here" (the keys are shown emphasised; the parts depend on what the host offers).
    ("composer.hint.type", "Type"),
    ("composer.hint.or", "or"),
    ("composer.hint.attach", "to attach"),
    ("composer.hint.assistant", "to ask the assistant"),
    ("composer.hint.drop", "drop files here"),
    ("composer.hint.drop_alone", "Drop files here to send them"),
    // When queued messages go is static.queued_note (SZFriendsCatalog.m), shared with the hosts' own surfaces.
    ("composer.note.blocked", "You blocked {first}. Unblock them in their details to send messages."),
    ("composer.note.removed", "You’re no longer friends. Add {first} again to send messages."),
    ("composer.note.key_change", "{first}’s key changed. Check it in their details before sending."),
    // They answered, but no way to connect worked just now, the relay included. Nothing is lost: it all waits, and
    // the helper tries again.
    (
        "composer.note.unreachable",
        "Couldn’t connect to {first} just now. Friends keeps trying, and sends what’s waiting as soon as it can.",
    ),
];

pub(super) const NEARBY: &[(&str, &str)] = &[
    ("visibility.visible.title", "You’re visible to people nearby"),
    ("visibility.visible.body", "Anyone nearby can see your name and picture and send you a request."),
    ("visibility.stop", "Stop"),
    ("visibility.start", "Make myself visible for 5 minutes"),
    (
        "visibility.hidden.body",
        "Friends you’ve added show up here on their own. Other people need to make themselves visible.",
    ),
    // Windows only (ADR 0015 § 15): with no firewall rule for Friends, this PC accepts no connections nearby.
    ("visibility.unavailable.firewall", "People nearby can’t see this PC."),
    (
        "nearby_inbound_blocked",
        "Windows Firewall blocks incoming connections, so this PC connects to friends nearby itself. You don’t need \
         to change anything.",
    ),
    ("method.network.not_asked", "Starts when you open Friends"),
    ("method.network.starting", "Starting…"),
    ("method.network.working", "Looking on your network and over Wi-Fi"),
    ("method.network.denied", "Local Network access is off for {app}"),
    ("method.network.radio_off", "Wi-Fi is off"),
    ("method.network.unavailable", "Can’t look on your network right now"),
    ("method.bluetooth.not_asked", "Starts when you open Friends"),
    ("method.bluetooth.starting", "Starting…"),
    ("method.bluetooth.working", "Looking over Bluetooth"),
    ("method.bluetooth.denied", "Bluetooth access is off for {app}"),
    ("method.bluetooth.radio_off", "Bluetooth is off"),
    ("method.bluetooth.unavailable", "Bluetooth isn’t working right now"),
    ("method.network.unsupported", "This computer can’t look on your network"),
    ("method.bluetooth.unsupported", "This computer can’t use Bluetooth"),
    // Without an identity nothing runs, and the list's banner says how to start again.
    ("method.identity_unavailable", "Starts once you reset Friends"),
    ("visibility.unavailable.identity", "Reset Friends to be visible to people nearby."),
    // Nothing asked for access yet: Allow starts Nearby, and the system asks the first time.
    ("alert.not_asked.title", "Find people near you"),
    (
        "alert.not_asked.body",
        "Click Allow to start looking. The first time, you’re asked whether {app} may use your local network and \
         Bluetooth.",
    ),
    // Phones: a tap, not a click.
    (
        "alert.not_asked.body.phone",
        "Tap Allow to start looking. The first time, you’re asked whether {app} may use your local network and \
         Bluetooth.",
    ),
    ("nearby.allow", "Allow"),
    ("nearby.try_again", "Try Again"),
    ("note.bluetooth_unsupported", "This computer can’t use Bluetooth. People nearby without Wi-Fi won’t appear."),
    ("note.bluetooth_not_asked", "Bluetooth hasn’t started yet."),
    ("nearby.empty.unavailable.body.identity", "Reset Friends to find people nearby on this computer."),
    ("alert.network_denied.title", "{app} can’t find people on your network"),
    (
        "alert.network_denied.body",
        "Turn on Local Network for {app} in System Settings › Privacy & Security. Until then, people on your Wi-Fi \
         won’t appear.",
    ),
    (
        "alert.network_denied.body.phone",
        "Turn on Local Network for {app} in Settings › Privacy & Security. Until then, people on your Wi-Fi won’t \
         appear.",
    ),
    ("alert.wifi_off.title", "Wi-Fi is off"),
    ("alert.wifi_off.body", "Turn on Wi-Fi to find people on your network and close by."),
    // Both radios off: one card names both, since nothing about Bluetooth shows under a card unless it works.
    ("alert.radios_off.title", "Wi-Fi and Bluetooth are off"),
    (
        "alert.radios_off.body",
        "Turn on Wi-Fi to find people on your network and close by, or Bluetooth to find people nearby without Wi-Fi.",
    ),
    ("alert.network_unavailable.title", "{app} can’t find people on your network right now"),
    ("alert.network_unavailable.body", "People on your Wi-Fi won’t appear until it works again."),
    ("settings_link.privacy", "Open Privacy Settings"),
    ("settings_link.app.phone", "Open Settings"),
    ("settings_link.wifi", "Open Wi-Fi Settings"),
    ("settings_link.bluetooth", "Open Bluetooth settings"),
    ("note.still_bluetooth", "Still looking over Bluetooth."),
    ("note.bluetooth_off", "Bluetooth is off. People nearby without Wi-Fi won’t appear."),
    ("note.bluetooth_denied", "Bluetooth access is off for {app}. People nearby without Wi-Fi won’t appear."),
    ("note.bluetooth_unavailable", "Bluetooth isn’t working. People nearby without Wi-Fi won’t appear."),
    ("nearby.still_looking", "Still looking"),
    ("nearby.subtitle.lan", "On your network"),
    ("nearby.subtitle.p2p_wifi", "Over direct Wi-Fi"),
    ("nearby.subtitle.bluetooth", "Over Bluetooth · messages fine, files slower"),
    ("nearby.subtitle.visible", "Visible now"),
    ("nearby.subtitle.no_name", "No name set"),
    ("nearby.status.friend", "Friend"),
    ("nearby.status.request_sent", "Request sent"),
    ("nearby.request", "Request"),
    ("nearby.empty.searching.title", "Looking for people nearby…"),
    ("nearby.empty.nobody.title", "Nobody visible nearby"),
    // The visibility line above already says who shows up; this answers whether to wait.
    ("nearby.empty.nobody.body", "{app} keeps looking while it’s open."),
    ("nearby.empty.unavailable.title", "Nearby isn’t working right now"),
];
