//! The English catalog: one profile on several computers (`SZFriendsCatalogDevices.m`). The reader is the person, on
//! one of their own computers: they think of computers, not of what makes them belong to a profile, so nothing here
//! names that.

pub(super) const DEVICES: &[(&str, &str)] = &[
    // Profile › Your computers. {name} is the computer's name, {system} "macOS 26.1" or "Linux", {last} when it
    // last connected to this one: devices.last.* below or the list's time words ("14:32", "Yesterday", "3 Oct").
    ("devices.title", "Your computers"),
    ("devices.note", "To add a computer, open Friends on it and choose Use my existing profile."),
    ("devices.detail", "{system} · {last}"),
    ("devices.last.this_computer", "This computer"),
    ("devices.last.now", "Now"),
    ("devices.last.minutes.one", "1 min ago"),
    ("devices.last.minutes.other", "{count} min ago"),
    ("devices.last.never", "Not connected to this computer yet"),
    ("devices.accessibility.this_computer", "{name}, {system}, this computer"),
    ("devices.accessibility.now", "{name}, {system}, connected now"),
    // {last} spoken: "yesterday", "14:32", "3 October", "5 minutes ago".
    ("devices.accessibility.seen", "{name}, {system}, last connected {last}"),
    ("devices.accessibility.never", "{name}, {system}, not connected to this computer yet"),
    ("devices.last.minutes.spoken.one", "1 minute ago"),
    ("devices.last.minutes.spoken.other", "{count} minutes ago"),
    // Only on this computer's own row: the name the person's other computers show for it.
    ("devices.rename.label", "Rename"),
    ("devices.rename.placeholder", "Computer name"),
    ("devices.rename.button", "Save"),
    // Remove asks first. The person wonders what happens to that computer (it stops), to their friends (they stop
    // taking anything from it, once one of the person's computers has told them) and to what is already on it
    // (it stays: removing is not erasing, which matters for a lost laptop).
    ("devices.remove", "Remove…"),
    ("devices.remove.confirm.title", "Remove {device}?"),
    (
        "devices.remove.confirm.body",
        "{device} stops getting your messages and files. Your friends stop accepting messages from it as soon as one \
         of your computers connects to them. Chats already on it stay there. To use Friends on it again, start over \
         there, then add it to your profile again.",
    ),
    ("devices.remove.confirm.button", "Remove"),
    // The list on a computer another of the person's computers removed. It answers what happened and what they
    // can still do; the chats stay readable, so the rows stay.
    ("device_removed.title", "This computer was removed from your profile"),
    (
        "device_removed.body",
        "Another of your computers removed it, so it no longer sends or receives messages. Your chats here stay \
         readable. To use Friends here again, start over, then choose Use my existing profile.",
    ),
    ("device_removed.action", "Start Over…"),
    ("device_removed.confirm.title", "Start over on this computer?"),
    (
        "device_removed.confirm.body",
        "This deletes the chats on this computer. Your other computers keep theirs. Files you received stay in \
         Received files.",
    ),
    ("device_removed.confirm.button", "Start Over"),
    ("device_removed.drop_refusal", "This computer can’t send anymore"),
    // A fresh list's name prompt, for someone who already uses Friends on another computer.
    ("name_prompt.join", "Use my existing profile"),
    // You: a conversation with yourself, on all your computers.
    ("you.title", "You"),
    ("you.subtitle.empty", "Send yourself messages and files"),
    ("you.header.subtitle", "On all your computers"),
    ("you.header.accessibility", "You, on all your computers"),
    ("you.row.accessibility", "You, {preview}, {time}"),
    ("you.row.accessibility.empty", "You, send yourself messages and files"),
    ("you.drop_label", "Send to all your computers"),
    ("you.composer.placeholder", "Message yourself"),
    // Under the composer only while something here has not reached every computer yet.
    ("you.composer.note.waiting", "What you send here reaches your other computers when {apps} is open on them."),
    ("you.status.queued", "Waiting for your other computers"),
    ("you.status.delivered", "On all your computers"),
    ("you.transfer.status.queued", "Copies to your other computers when they connect"),
    ("you.transfer.status.sending", "Copying to your other computers · {percent}%"),
    ("you.transfer.status.delivered", "On all your computers"),
    // A file another of the person's computers holds and this one does not have yet (too large to copy by
    // itself). {device} is that computer's name.
    ("transfer.status.on_device", "On {device}"),
    ("transfer.action.fetch", "Get"),
    ("transfer.status.fetching", "Copying from {device} · {percent}%"),
    ("transfer.status.fetch_waiting", "Copies when {device} is nearby with {apps} open"),
    ("transfer.status.fetch_waiting.online", "Copies when {device} is online or nearby with {apps} open"),
    ("transfer.progress.copying", "Copying, {percent} percent"),
    // These files read aloud: who sent it, the file's facts, then where it is ({status}, said mid-sentence).
    ("devices.spoken.transfer.in", "{sender} sent {file}, {kind}, {size}, {status}"),
    ("devices.spoken.transfer.out", "You sent {file}, {kind}, {size}, {status}"),
    (
        "devices.spoken.transfer.fetching",
        "{sender} sent {file}, {kind}, {size}, copying from {device}, {percent} percent",
    ),
    (
        "you.transfer.spoken.sending",
        "You are copying {file}, {kind}, {size}, to your other computers, {percent} percent",
    ),
    ("you.transfer.spoken.queued", "You sent {file}, {kind}, {size}. {status}."),
    // Delete history on a profile with several computers: where it is deleted, and when the others follow.
    ("details.history.note.devices", "Clears this chat on all your computers."),
    ("details.history.note.friend.devices", "Clears this chat on all your computers. {first} stays your friend."),
    (
        "details.history.confirm.goes.devices",
        "Your messages and file history with {first} are deleted from this computer, and from your other computers as \
         soon as they connect. Anything still waiting to go to {first} won’t be sent.",
    ),
    (
        "settings.history.note.devices",
        "Stored on all your computers. Deleting it keeps your friends and the files you received.",
    ),
    (
        "settings.history.confirm.body.devices",
        "Your messages and file history, with every friend and in You, are deleted from this computer, and from your \
         other computers as soon as they connect. Anything still waiting to go won’t be sent. You keep your friends, \
         and they keep their own copies of your chats. Files you received stay in Received files.",
    ),
    (
        "settings.history.confirm.body.assistant.devices",
        "Your messages and file history, with every friend and in You, are deleted from this computer, and from your \
         other computers as soon as they connect. Anything still waiting to go won’t be sent. You keep your friends, \
         and they keep their own copies of your chats. Files you received stay in Received files. AI chat answers \
         that quoted your chats stay in Chats until you delete them there.",
    ),
    // Replies.
    ("error.not_found.device", "That computer was already removed."),
    ("error.not_found.fetch", "This file isn’t on your other computers anymore."),
    ("error.not_allowed.device_removed", "This computer was removed from your profile, so it can’t send anything."),
    ("error.name_invalid.device", "That name is too long or has a line break. Try a shorter one."),
    ("error.name_invalid.device.empty", "Type a name for this computer."),
];
