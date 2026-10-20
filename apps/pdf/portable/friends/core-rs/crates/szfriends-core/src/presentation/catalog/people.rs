//! The English catalog, part two continued (`SZFriendsCatalogViews.m`): details, the profile, Settings, search and
//! reply error messages.

pub(super) const PEOPLE_AND_SETTINGS: &[(&str, &str)] = &[
    // Friend details
    ("verification.verified", "Verified"),
    ("verification.verified_on", "Verified: you compared codes {day}"),
    ("verification.unverified", "Not verified"),
    ("verification.codes_match", "The codes match"),
    (
        "verification.body.compare",
        "Check that {first}’s screen shows the same code. If it does, you know you’re talking to {first}.",
    ),
    (
        "verification.body.later",
        "Compare codes the next time you’re both online or nearby to be sure this is really {first}.",
    ),
    ("details.copy_id", "Copy {first}’s ID"),
    ("details.received.one", "Received from {first}: 1 file"),
    ("details.received.other", "Received from {first}: {count} files"),
    ("details.remove_note", "Keeps your conversation. {first} can send you a new request."),
    ("details.block_note", "{first} can’t reach you or send requests until you unblock."),
    ("details.unblock_note", "{first} can reach you and send requests again."),
    ("details.history.action", "Delete chat history…"),
    ("details.history.note", "Clears this chat on this computer."),
    ("details.history.note.friend", "Clears this chat on this computer. {first} stays your friend."),
    ("details.history.confirm.title", "Delete your chat history with {first}?"),
    // The question is these sentences in order: what goes, where the person stays, the files received, and, for
    // a host whose AI chat may read Friends chats (assistant.chats), the answers there that quoted this chat.
    (
        "details.history.confirm.goes",
        "Your messages and file history with {first} are deleted from this computer, and anything still waiting to go \
         to {first} won’t be sent.",
    ),
    ("details.history.confirm.stays.friend", "{first} stays your friend and keeps their own copy of the chat."),
    ("details.history.confirm.stays.blocked", "{first} stays blocked and keeps their own copy of the chat."),
    ("details.history.confirm.stays", "{first} keeps their own copy of the chat."),
    ("details.history.confirm.files", "Files you received stay where they were saved."),
    (
        "details.history.confirm.assistant",
        "AI chat answers that quoted this chat stay in Chats until you delete them there.",
    ),
    ("auto_accept.title", "Accept files from {first} automatically"),
    (
        "auto_accept.body",
        "Files from {first} download without asking. They’re saved where other received files go and never open by themselves.",
    ),
    ("key_change.title", "{first}’s key changed"),
    (
        "key_change.body",
        "This happens when {first} resets Friends or starts over on a new computer or phone. If you’re not sure it’s \
         really them, compare codes before you continue.",
    ),
    ("key_change.accept", "Continue with the new key"),
    // Profile
    ("profile.title", "Your profile and ID"),
    ("profile.name.label", "Name friends see"),
    ("profile.picture.choose", "Change picture…"),
    ("profile.picture.own", "Use your own picture…"),
    ("profile.id.label", "Your ID"),
    ("profile.add.label", "Add someone by ID"),
    ("profile.add.placeholder", "Their ID"),
    ("profile.add.button", "Send request"),
    ("profile.add.hint", "Two words, like amber\u{2011}falcon."),
    // Settings
    ("settings.name.label", "Your name"),
    ("settings.name.note", "The name your friends see."),
    ("settings.id.note", "People can add you with it."),
    ("settings.received.label", "Save received files to"),
    ("settings.received.note", ""),
    ("settings.received.note.fallback.downloads", "The last file couldn’t be saved here, so it went to Downloads."),
    (
        "settings.received.note.fallback.kept",
        "The last file couldn’t be saved here, so {app} kept it. Open it from its chat.",
    ),
    ("settings.received.change", "Change…"),
    ("settings.received.default", "Downloads"),
    ("settings.received.note.ios", "In the Files app, under On My iPhone."),
    ("error.received_folder.missing", "That folder can’t be found or opened. Choose another folder."),
    ("error.received_folder.not_allowed", "Files can’t be saved in that folder. Choose another folder."),
    ("settings.auto.label", "Accept files automatically"),
    ("settings.auto.action", "Choose friends…"),
    ("settings.auto.note.some", "From {names}. Everyone else asks first."),
    ("settings.auto.note.only", "From {names}."),
    ("settings.auto.note.all", "From every friend."),
    ("settings.auto.note.none", "Off. Every file waits for you to accept it."),
    ("settings.auto.note.no_friends", "Turn it on for a friend in their details."),
    ("settings.auto.others.one", "1 other"),
    ("settings.auto.others.other", "{count} others"),
    ("settings.history.label", "Conversation history"),
    ("settings.history.note", "Stored on this computer. Deleting it keeps your friends and the files you received."),
    ("settings.history.action", "Delete history…"),
    ("settings.history.confirm.title", "Delete all conversation history?"),
    (
        "settings.history.confirm.body",
        "Your messages and file history with every friend are deleted from this computer, and anything still waiting \
         to go won’t be sent. You keep your friends, and they keep their own copies of your chats. Files you received \
         stay where they were saved.",
    ),
    // Only for a host whose AI chat may read Friends chats (assistant.chats): answers there that quoted a friend
    // are the host's, not Friends', so deleting here leaves them, and saying nothing would be untrue from the
    // person's side (wave-4 security re-check).
    (
        "settings.history.confirm.body.assistant",
        "Your messages and file history with every friend are deleted from this computer, and anything still waiting \
         to go won’t be sent. You keep your friends, and they keep their own copies of your chats. Files you received \
         stay where they were saved. AI chat answers that quoted your chats stay in Chats until you delete them there.",
    ),
    ("settings.history.confirm.button", "Delete History"),
    ("settings.reset.label", "Start over"),
    // Settings' Nearby line: whether Friends can find people nearby, and what fixes it when it cannot.
    ("settings.nearby.label", "Nearby"),
    ("settings.nearby.note.identity", "Nearby starts once you reset Friends."),
    (
        "settings.nearby.note.not_asked",
        "Allow {app} to find people nearby. The first time, you’re asked whether it may use your local network and \
         Bluetooth.",
    ),
    (
        "settings.nearby.note.denied",
        "Local Network and Bluetooth access are off for {app}, so nobody nearby appears. Turn them on in System \
         Settings › Privacy & Security.",
    ),
    (
        "settings.nearby.note.network_denied",
        "Local Network access is off for {app}, so people on your Wi-Fi won’t appear. Turn it on in System Settings \
         › Privacy & Security.",
    ),
    (
        "settings.nearby.note.bluetooth_denied",
        "Bluetooth access is off for {app}, so people nearby without Wi-Fi won’t appear. Turn it on in System \
         Settings › Privacy & Security.",
    ),
    ("settings.nearby.note.wifi_off", "Wi-Fi is off. Turn it on to find people on your network and close by."),
    (
        "settings.nearby.note.radios_off",
        "Wi-Fi and Bluetooth are off. Turn on Wi-Fi to find people on your network and close by, or Bluetooth to find \
         people nearby without Wi-Fi.",
    ),
    ("settings.nearby.note.bluetooth_off", "Bluetooth is off. People nearby without Wi-Fi won’t appear."),
    ("settings.nearby.note.failed", "Nearby isn’t working right now."),
    (
        "settings.nearby.note.unsupported.network",
        "This computer can’t look for people on your network. {app} finds people nearby over Bluetooth.",
    ),
    (
        "settings.nearby.note.unsupported.bluetooth",
        "This computer can’t use Bluetooth. {app} finds people nearby on your network.",
    ),
    ("settings.nearby.note.unsupported.both", "{app} can’t find people nearby on this computer."),
    ("settings.nearby.note.ready", "{app} can find people nearby on your network and over Bluetooth."),
    ("settings.reset.note", "You get a new ID, and every friend has to add you again."),
    ("settings.reset.action", "Reset Friends…"),
    ("settings.reset.confirm.title", "Reset Friends?"),
    (
        "settings.reset.confirm.body",
        "This deletes your friends and conversations from this computer and gives you a new ID. Every friend has to \
         add you again. Files you received stay where they were saved.",
    ),
    (
        "settings.reset.confirm.body.assistant",
        "This deletes your friends and conversations from this computer and gives you a new ID. Every friend has to \
         add you again. Files you received stay where they were saved. AI chat answers that quoted your conversations stay \
         in Chats until you delete them there.",
    ),
    ("settings.reset.confirm.button", "Reset Friends"),
    // A phone or tablet (`files.share`): where history is kept and what deleting it removes, in its own words. Only
    // the portable core serves one.
    ("settings.history.note.phone", "Stored on this device. Deleting it keeps your friends and the files you received."),
    (
        "settings.history.note.devices.phone",
        "Stored on all your devices. Deleting it keeps your friends and the files you received.",
    ),
    (
        "settings.history.confirm.body.phone",
        "Your messages and file history with every friend are deleted from this device, and anything still waiting \
         to go won’t be sent. You keep your friends, and they keep their own copies of your chats. Files you received \
         stay where they were saved.",
    ),
    (
        "settings.history.confirm.body.assistant.phone",
        "Your messages and file history with every friend are deleted from this device, and anything still waiting \
         to go won’t be sent. You keep your friends, and they keep their own copies of your chats. Files you received \
         stay where they were saved. AI chat answers that quoted your chats stay in Chats until you delete them there.",
    ),
    (
        "settings.history.confirm.body.devices.phone",
        "Your messages and file history, with every friend and in You, are deleted from this device, and from your \
         other devices as soon as they connect. Anything still waiting to go won’t be sent. You keep your friends, \
         and they keep their own copies of your chats. Files you received stay where they were saved.",
    ),
    (
        "settings.history.confirm.body.assistant.devices.phone",
        "Your messages and file history, with every friend and in You, are deleted from this device, and from your \
         other devices as soon as they connect. Anything still waiting to go won’t be sent. You keep your friends, \
         and they keep their own copies of your chats. Files you received stay where they were saved. AI chat answers \
         that quoted your chats stay in Chats until you delete them there.",
    ),
    (
        "settings.reset.confirm.body.phone",
        "This deletes your friends and conversations from this device and gives you a new ID. Every friend has to \
         add you again. Files you received stay where they were saved.",
    ),
    (
        "settings.reset.confirm.body.assistant.phone",
        "This deletes your friends and conversations from this device and gives you a new ID. Every friend has to \
         add you again. Files you received stay where they were saved. AI chat answers that quoted your conversations \
         stay in Chats until you delete them there.",
    ),
    // Search
    ("search.sender.you", "You"),
    ("search.empty", "No messages or files match."),
];

pub(super) const ERRORS: &[(&str, &str)] = &[
    ("error.invalid_field.text", "This message is too long. Split it into shorter messages."),
    ("error.invalid_field.query", "Searches can be up to 200 characters."),
    ("error.not_found", "This isn’t here anymore."),
    ("error.not_allowed", "That can’t be done right now."),
    ("error.rate_limited", "Too many at once. Try again in a moment."),
    ("error.rate_limited.seconds", "Too many at once. Try again in {seconds} seconds."),
    (
        "error.identity_unavailable",
        "Friends can’t open your identity on this computer. Reset Friends in Settings to start again.",
    ),
    ("error.name_invalid", "Names can be 1 to 40 characters, without line breaks."),
    ("error.id_invalid", "That isn’t a Friends ID. IDs are two words, like amber\u{2011}falcon."),
    ("error.id_is_yours", "That’s your own ID."),
    ("error.already_friends", "You’re already friends."),
    ("error.already_friends.name", "{name} is already your friend."),
    ("error.blocked", "You blocked this person. Unblock them first."),
    ("error.blocked.name", "You blocked {name}. Unblock them first."),
    ("error.not_friends", "You’re not friends anymore. Add them again to send messages."),
    ("error.not_friends.name", "You’re not friends with {name} anymore. Add them again to send messages."),
    ("error.file_missing", "A file can’t be found or opened. Nothing was sent."),
    ("error.file_missing.file", "{file} can’t be found or opened. Nothing was sent."),
    ("error.folder_not_supported", "Folders can’t be sent yet."),
    ("error.folder_not_supported.file", "Folders can’t be sent yet."),
    ("error.too_many_files", "Too many files at once. Nothing was sent."),
    ("error.too_many_files.max", "You can send up to {max} files at once. Nothing was sent."),
    ("error.source_changed", "A file changed since you attached it. Attach it again to send the current version."),
    ("error.source_changed.file", "{file} changed since you attached it. Attach it again to send the current version."),
    ("error.disk_full", "There isn’t enough space on this computer. Free up some space, then try again."),
    ("error.disk_full.size", "There isn’t enough space on this computer. Free up {size}, then try again."),
    (
        "error.disk_full.file",
        "There isn’t enough space on this computer for {file}. Free up some space, then accept it again.",
    ),
    (
        "error.disk_full.file_size",
        "There isn’t enough space on this computer for {file}. Free up {size}, then accept it again.",
    ),
    (
        "error.disk_full.sending",
        "There isn’t enough space on this computer to send {file}. Free up some space, then try again.",
    ),
    ("error.picture_invalid", "That picture can’t be used. Choose a picture under 5 MB."),
    ("error.scope_invalid", "The assistant’s access to this chat has ended. Ask again."),
    ("error.stale", "This changed in the meantime. Have another look."),
    // Cancel pressed on a message that left meanwhile (cancel_message): it was not withdrawn, and this says why.
    ("error.stale.message_delivered", "{first} already has it, so it can’t be cancelled."),
    ("error.stale.message_sending", "It’s already on its way to {first}, so it can’t be cancelled."),
    // Written to a connection that dropped before their Mac answered: queued again, but it may have arrived.
    ("error.stale.message_sent", "{first} may already have it, so it can’t be cancelled."),
    ("error.internal", "Something went wrong in Friends. Try again."),
    (
        "error.internal.identity_not_removed",
        "Nothing was reset: Friends couldn’t remove your old ID from this computer. Make sure it’s unlocked, then \
         try again.",
    ),
    // Before this computer reaches friends online: true nearby and, once it does, online too.
    (
        "add_by_id.sent",
        "Request sent to {id}. They’ll get it as soon as Friends reaches them, and you’ll be friends once they \
         accept.",
    ),
    // Once this computer reaches friends online: the request also travels through the Friends host, from and to
    // any computer of either person.
    (
        "add_by_id.sent.online",
        "Request sent to {id}. They’ll get it while {apps} is open for both of you, and you’ll be friends once they \
         accept.",
    ),
];
