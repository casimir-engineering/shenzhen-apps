// Shenzhen Friends strings catalog, English, part two: transfers, requests, the composer, Nearby, details, the
// profile, Settings, search and reply error messages. Conventions are in SZFriendsCatalog.m.

#import "service/presentation/SZFriendsPresentationPrivate.h"


static NSDictionary<NSString *, NSString *> *TransferAndConversationEntries(void) {
    return @{
        // Transfers
        @"transfer.meta" : @"{kind} · {size}",
        @"transfer.left.spoken" : @"{duration} left",
        @"transfer.disk_low.spoken" : @"There wasn’t enough free space to accept it automatically.",
        @"transfer.status.queued" : @"Sends when {first} is nearby",
        @"transfer.status.queued_online" : @"Sends when {first} is online or nearby",
        @"transfer.status.connecting" : @"Connecting to {first}…",
        @"transfer.status.offered" : @"Waiting for {first} to accept",
        @"transfer.status.waiting_for_you" : @"Waiting for you to accept",
        @"transfer.status.disk_low" : @"Waiting for you. There wasn’t enough free space to accept it automatically.",
        @"transfer.status.sending" : @"Sending · {percent}%",
        @"transfer.status.sending_timed" : @"Sending · {percent}% · {duration} left",
        @"transfer.status.receiving" : @"Receiving · {percent}%",
        @"transfer.status.receiving_timed" : @"Receiving · {percent}% · {duration} left",
        @"transfer.status.delivered" : @"Delivered to {first}",
        @"transfer.status.received" : @"Received",
        @"transfer.status.received.saved" : @"Saved to {folder}",
        @"transfer.status.declined.out" : @"{first} declined",
        @"transfer.status.declined.in" : @"You declined",
        @"transfer.status.cancelled" : @"Cancelled",
        @"transfer.status.failed.out" : @"Not sent",
        @"transfer.status.failed.in" : @"Didn’t arrive",
        // Failure keys from the store (SZFriendsOutbox.h, SZFriendsTransfers.h); others keep the two lines above.
        @"transfer.status.failed.out.not_delivered_30_days" : @"Not delivered. Stopped trying after 30 days.",
        @"transfer.status.failed.out.refused" : @"{first} couldn’t receive this file",
        @"transfer.status.failed.out.refused.removed" : @"Not sent because you removed {first}",
        @"transfer.status.failed.out.refused.blocked" : @"Not sent because you blocked {first}",
        // The version bound when it was sent is gone; sending the file again sends what is there now.
        @"transfer.status.failed.out.source_missing" : @"Not sent because this version of the file is no longer "
                                                       @"available",
        @"transfer.status.failed.out.digest_mismatch" : @"Arrived damaged for {first}, so it wasn’t saved",
        @"transfer.status.failed.in.digest_mismatch" : @"Arrived damaged, so it wasn’t saved",
        @"transfer.progress.sending" : @"Sending, {percent} percent",
        @"transfer.progress.receiving" : @"Receiving, {percent} percent",
        // Every block arrived; the whole file is checked before it is saved (PROTOCOL.md § Fast transfers).
        @"transfer.finishing" : @"Finishing…",
        @"transfer.progress.finishing" : @"Finishing",
        // The Wi-Fi Direct boost (ADR 0019): the question on a device that would lose its only Internet, and the notes
        // after.
        @"transfer.boost.ask" : @"Go faster? {first} isn’t on your Wi-Fi, so this is going over Bluetooth ({slow}). "
                                @"Leave {network} for {fast} to connect to {first} directly. Your {device} rejoins it "
                                @"by itself when it’s done.",
        @"transfer.boost.network" : @"“{name}”",
        @"transfer.boost.your_wifi" : @"your Wi-Fi",
        @"transfer.boost.go" : @"Go faster",
        @"transfer.boost.not_now" : @"Not now",
        @"transfer.boost.connecting" : @"Connecting directly to {first}…",
        @"transfer.boost.direct" : @"Going directly over Wi-Fi",
        @"transfer.boost.direct.away" : @"Going directly over Wi-Fi. Your {device} rejoins {network} when it’s done.",
        @"transfer.boost.direct.ethernet" : @"Going directly over Wi-Fi. Your {device} stays online over Ethernet "
                                            @"meanwhile, and rejoins {network} when it’s done.",
        @"transfer.boost.rejoining" : @"Rejoining {network}…",
        @"transfer.boost.rejoin_failed" : @"Your {device} didn’t get back on {network} by itself. Choose it in {place}.",
        @"transfer.boost.device.mac" : @"Mac",
        @"transfer.boost.device.computer" : @"computer",
        @"transfer.boost.place.mac" : @"the Wi-Fi menu",
        @"transfer.boost.place.computer" : @"Wi-Fi settings",
        @"transfer.spoken.in.finishing" : @"{sender} sent {file}, {kind}, {size}{auto}, finishing",
        @"transfer.spoken.in.waiting_for_you" : @"{sender} wants to send you {file}, {kind}, {size}{note}{extra}",
        @"transfer.spoken.in.receiving" : @"{sender} is sending {file}, {kind}, {size}{auto}, {percent} percent "
                                          @"received{left}",
        @"transfer.spoken.in.received" : @"{sender} sent {file}, {kind}, {size}{auto}, received",
        @"transfer.spoken.in.received.saved" : @"{sender} sent {file}, {kind}, {size}{auto}, saved to {folder}",
        @"transfer.spoken.in.declined" : @"{sender} offered {file}, {kind}, {size}, you declined",
        @"transfer.spoken.in.cancelled" : @"{sender} offered {file}, {kind}, {size}, cancelled",
        @"transfer.spoken.in.failed" : @"{sender} offered {file}, {kind}, {size}, it didn’t arrive",
        @"transfer.spoken.in.failed.digest_mismatch" : @"{sender} sent {file}, {kind}, {size}. It arrived damaged, so "
                                                       @"it wasn’t saved",
        // States an incoming file never has; worded plainly in case the store reports one.
        @"transfer.spoken.in.queued" : @"{sender} offered {file}, {kind}, {size}",
        @"transfer.spoken.in.offered" : @"{sender} offered {file}, {kind}, {size}",
        @"transfer.spoken.in.sending" : @"{sender} is sending {file}, {kind}, {size}",
        @"transfer.spoken.in.delivered" : @"{sender} sent {file}, {kind}, {size}",
        @"transfer.spoken.out.queued" : @"You are sending {file}, {kind}, {size}. {status}.",
        @"transfer.spoken.out.offered" : @"You offered {file}, {kind}, {size}. {status}.",
        @"transfer.spoken.out.sending" : @"You are sending {file}, {kind}, {size}, {percent} percent sent{left}",
        @"transfer.spoken.out.delivered" : @"You sent {file}, {kind}, {size}, delivered to {first}",
        @"transfer.spoken.out.declined" : @"You offered {file}, {kind}, {size}, {first} declined",
        @"transfer.spoken.out.cancelled" : @"You offered {file}, {kind}, {size}, cancelled",
        @"transfer.spoken.out.failed" : @"You tried to send {file}, {kind}, {size}. {status}.",
        // States an outgoing file never has.
        @"transfer.spoken.out.waiting_for_you" : @"You offered {file}, {kind}, {size}",
        @"transfer.spoken.out.receiving" : @"You are sending {file}, {kind}, {size}",
        @"transfer.spoken.out.received" : @"You sent {file}, {kind}, {size}",

        // Requests
        @"request.title.incoming" : @"{title} wants to be friends",
        @"request.title.outgoing" : @"Request sent to {title}",
        @"request.found_nearby" : @"Found you nearby",
        @"request.by_id" : @"Sent to your ID",
        @"request.sent" : @"Request sent",
        @"request.sent_at" : @"Sent {moment}",
        @"request.code_prompt.incoming" : @"Before you accept, check that {first}’s screen shows the same code.",
        @"request.code_prompt.outgoing" : @"Check that {first}’s screen shows the same code.",
        @"request.code_later" : @"A code to compare appears when you’re both online or nearby.",
        @"request.footnote.incoming" : @"Once you accept, {first} can message you and send you files. You decide on "
                                       @"each file unless you turn on automatic acceptance for {first}.",
        @"request.footnote.outgoing" : @"You’ll be friends once {first} accepts.",
        // An answer to the person's own Add by ID that the Friends server could not confirm: anyone nearby who heard
        // the request could have sent it, so it waits like a request (wave-4 security re-check, Add by ID).
        @"request.title.answer" : @"{title} answered your request",
        @"request.asked_for" : @"You asked for {id}",
        @"request.footnote.answer" : @"Friends couldn’t confirm that {id} belongs to {first}. Anyone nearby could "
                                     @"have answered your request, so accept only if the codes on both screens "
                                     @"match.",

        // Composer
        @"composer.placeholder" : @"Message {first}",
        @"composer.send" : @"Send",
        // The hint under the composer, in words a newcomer follows: "Type # to attach, @ to mention someone, or drop
        // files here" (the keys are shown emphasised; the parts depend on what the host offers).
        @"composer.hint.type" : @"Type",
        @"composer.hint.or" : @"or",
        @"composer.hint.attach" : @"to attach",
        @"composer.hint.assistant" : @"to ask the assistant",
        @"composer.hint.drop" : @"drop files here",
        @"composer.hint.drop_alone" : @"Drop files here to send them",
        // When queued messages go is static.queued_note (SZFriendsCatalog.m), shared with the hosts' own surfaces.
        @"composer.note.blocked" : @"You blocked {first}. Unblock them in their details to send messages.",
        @"composer.note.removed" : @"You’re no longer friends. Add {first} again to send messages.",
        @"composer.note.key_change" : @"{first}’s key changed. Check it in their details before sending.",
        // They answered, but no way to connect worked just now, the relay included. Nothing is lost: it all waits, and
        // the helper tries again.
        @"composer.note.unreachable" : @"Couldn’t connect to {first} just now. Friends keeps trying, and sends what’s "
                                       @"waiting as soon as it can.",
    };
}

static NSDictionary<NSString *, NSString *> *NearbyEntries(void) {
    return @{
        @"visibility.visible.title" : @"You’re visible to people nearby",
        @"visibility.visible.body" : @"Anyone nearby can see your name and picture and send you a request.",
        @"visibility.stop" : @"Stop",
        @"visibility.start" : @"Make myself visible for 5 minutes",
        @"visibility.hidden.body" : @"Friends you’ve added show up here on their own. Other people need to make "
                                    @"themselves visible.",
        @"method.network.not_asked" : @"Starts when you open Friends",
        @"method.network.starting" : @"Starting…",
        @"method.network.working" : @"Looking on your network and over Wi-Fi",
        @"method.network.denied" : @"Local Network access is off for {app}",
        @"method.network.radio_off" : @"Wi-Fi is off",
        @"method.network.unavailable" : @"Can’t look on your network right now",
        @"method.bluetooth.not_asked" : @"Starts when you open Friends",
        @"method.bluetooth.starting" : @"Starting…",
        @"method.bluetooth.working" : @"Looking over Bluetooth",
        @"method.bluetooth.denied" : @"Bluetooth access is off for {app}",
        @"method.bluetooth.radio_off" : @"Bluetooth is off",
        @"method.bluetooth.unavailable" : @"Bluetooth isn’t working right now",
        @"method.network.unsupported" : @"This computer can’t look on your network",
        @"method.bluetooth.unsupported" : @"This computer can’t use Bluetooth",
        // Without an identity nothing runs, and the list's banner says how to start again.
        @"method.identity_unavailable" : @"Starts once you reset Friends",
        @"visibility.unavailable.identity" : @"Reset Friends to be visible to people nearby.",
        // Nothing asked for access yet: Allow starts Nearby, and the system asks the first time.
        @"alert.not_asked.title" : @"Find people near you",
        @"alert.not_asked.body" : @"Click Allow to start looking. The first time, you’re asked whether {app} may use "
                                  @"your local network and Bluetooth.",
        @"nearby.allow" : @"Allow",
        @"nearby.try_again" : @"Try Again",
        @"note.bluetooth_unsupported" : @"This computer can’t use Bluetooth. People nearby without Wi-Fi won’t "
                                        @"appear.",
        @"note.bluetooth_not_asked" : @"Bluetooth hasn’t started yet.",
        @"nearby.empty.unavailable.body.identity" : @"Reset Friends to find people nearby on this computer.",
        @"alert.network_denied.title" : @"{app} can’t find people on your network",
        @"alert.network_denied.body" : @"Turn on Local Network for {app} in System Settings › Privacy & Security. "
                                       @"Until then, people on your Wi-Fi won’t appear.",
        @"alert.wifi_off.title" : @"Wi-Fi is off",
        @"alert.wifi_off.body" : @"Turn on Wi-Fi to find people on your network and close by.",
        // Both radios off: one card names both, since nothing about Bluetooth shows under a card unless it works.
        @"alert.radios_off.title" : @"Wi-Fi and Bluetooth are off",
        @"alert.radios_off.body" : @"Turn on Wi-Fi to find people on your network and close by, or Bluetooth to find "
                                   @"people nearby without Wi-Fi.",
        @"alert.network_unavailable.title" : @"{app} can’t find people on your network right now",
        @"alert.network_unavailable.body" : @"People on your Wi-Fi won’t appear until it works again.",
        @"settings_link.privacy" : @"Open Privacy Settings",
        @"settings_link.wifi" : @"Open Wi-Fi Settings",
        @"settings_link.bluetooth" : @"Open Bluetooth settings",
        @"note.still_bluetooth" : @"Still looking over Bluetooth.",
        @"note.bluetooth_off" : @"Bluetooth is off. People nearby without Wi-Fi won’t appear.",
        @"note.bluetooth_denied" : @"Bluetooth access is off for {app}. People nearby without Wi-Fi won’t appear.",
        @"note.bluetooth_unavailable" : @"Bluetooth isn’t working. People nearby without Wi-Fi won’t appear.",
        @"nearby.still_looking" : @"Still looking",
        @"nearby.subtitle.lan" : @"On your network",
        @"nearby.subtitle.p2p_wifi" : @"Over direct Wi-Fi",
        @"nearby.subtitle.bluetooth" : @"Over Bluetooth · messages fine, files slower",
        @"nearby.subtitle.visible" : @"Visible now",
        @"nearby.subtitle.no_name" : @"No name set",
        @"nearby.status.friend" : @"Friend",
        @"nearby.status.request_sent" : @"Request sent",
        @"nearby.request" : @"Request",
        @"nearby.empty.searching.title" : @"Looking for people nearby…",
        @"nearby.empty.nobody.title" : @"Nobody visible nearby",
        // The visibility line above already says who shows up; this answers whether to wait.
        @"nearby.empty.nobody.body" : @"{app} keeps looking while it’s open.",
        @"nearby.empty.unavailable.title" : @"Nearby isn’t working right now",
    };
}

static NSDictionary<NSString *, NSString *> *PeopleAndSettingsEntries(void) {
    return @{
        // Friend details
        @"verification.verified" : @"Verified",
        @"verification.verified_on" : @"Verified: you compared codes {day}",
        @"verification.unverified" : @"Not verified",
        @"verification.codes_match" : @"The codes match",
        @"verification.body.compare" : @"Check that {first}’s screen shows the same code. If it does, you know you’re "
                                       @"talking to {first}.",
        @"verification.body.later" : @"Compare codes the next time you’re both online or nearby to be sure this is "
                                     @"really {first}.",
        @"details.copy_id" : @"Copy {first}’s ID",
        @"details.received.one" : @"Received from {first}: 1 file",
        @"details.received.other" : @"Received from {first}: {count} files",
        @"details.remove_note" : @"Takes {first} off your list. {first} can send you a new request.",
        @"details.block_note" : @"{first} can’t reach you or send requests until you unblock.",
        @"details.unblock_note" : @"{first} can reach you and send requests again.",
        @"details.history.action" : @"Delete chat history…",
        @"details.history.note" : @"Clears this chat on this computer.",
        @"details.history.note.friend" : @"Clears this chat on this computer. {first} stays your friend.",
        @"details.history.confirm.title" : @"Delete your chat history with {first}?",
        // The question is these sentences in order: what goes, where the person stays, the files received, and, for
        // a host whose AI chat may read Friends chats (assistant.chats), the answers there that quoted this chat.
        @"details.history.confirm.goes" : @"Your messages and file history with {first} are deleted from this "
                                          @"computer, and anything still waiting to go to {first} won’t be sent.",
        @"details.history.confirm.stays.friend" : @"{first} stays your friend and keeps their own copy of the chat.",
        @"details.history.confirm.stays.blocked" : @"{first} stays blocked and keeps their own copy of the chat.",
        @"details.history.confirm.stays" : @"{first} keeps their own copy of the chat.",
        @"details.history.confirm.files" : @"Files you received stay where they were saved.",
        @"details.history.confirm.assistant" : @"AI chat answers that quoted this chat stay in Chats until you delete "
                                               @"them there.",
        @"auto_accept.title" : @"Accept files from {first} automatically",
        @"auto_accept.body" : @"Files from {first} download without asking. They’re saved where other received files "
                              @"go and never open by themselves.",
        @"key_change.title" : @"{first}’s key changed",
        @"key_change.body" : @"This happens when {first} resets Friends or starts over on a new computer or phone. If "
                             @"you’re not sure it’s really them, compare codes before you continue.",
        @"key_change.accept" : @"Continue with the new key",

        // Profile
        @"profile.title" : @"Your profile and ID",
        @"profile.name.label" : @"Name friends see",
        @"profile.picture.choose" : @"Change picture…",
        @"profile.picture.own" : @"Use your own picture…",
        @"profile.id.label" : @"Your ID",
        @"profile.add.label" : @"Add someone by ID",
        @"profile.add.placeholder" : @"Their ID",
        @"profile.add.button" : @"Send request",
        @"profile.add.hint" : @"Two words, like amber\u2011falcon.",

        // Settings
        @"settings.name.label" : @"Your name",
        @"settings.name.note" : @"The name your friends see.",
        @"settings.id.note" : @"People can add you with it.",
        @"settings.received.label" : @"Save received files to",
        @"settings.received.note" : @"",
        @"settings.received.note.fallback.downloads" : @"The last file couldn’t be saved here, so it went to Downloads.",
        @"settings.received.note.fallback.kept" : @"The last file couldn’t be saved here, so {app} kept it. Open it from "
                                                  @"its chat.",
        @"settings.received.default" : @"Downloads",
        @"settings.received.change" : @"Change…",
        @"settings.auto.label" : @"Accept files automatically",
        @"settings.auto.action" : @"Choose friends…",
        @"settings.auto.note.some" : @"From {names}. Everyone else asks first.",
        @"settings.auto.note.only" : @"From {names}.",
        @"settings.auto.note.all" : @"From every friend.",
        @"settings.auto.note.none" : @"Off. Every file waits for you to accept it.",
        @"settings.auto.note.no_friends" : @"Turn it on for a friend in their details.",
        @"settings.auto.others.one" : @"1 other",
        @"settings.auto.others.other" : @"{count} others",
        @"settings.history.label" : @"Conversation history",
        @"settings.history.note" : @"Stored on this computer. Deleting it keeps your friends and the files you "
                                   @"received.",
        @"settings.history.action" : @"Delete history…",
        @"settings.history.confirm.title" : @"Delete all conversation history?",
        @"settings.history.confirm.body" : @"Your messages and file history with every friend are deleted from this "
                                           @"computer, and anything still waiting to go won’t be sent. You keep your "
                                           @"friends, and they keep their own copies of your chats. Files you "
                                           @"received stay where they were saved.",
        // Only for a host whose AI chat may read Friends chats (assistant.chats): answers there that quoted a friend
        // are the host's, not Friends', so deleting here leaves them, and saying nothing would be untrue from the
        // person's side (wave-4 security re-check).
        @"settings.history.confirm.body.assistant" : @"Your messages and file history with every friend are deleted "
                                                     @"from this computer, and anything still waiting to go won’t be "
                                                     @"sent. You keep your friends, and they keep their own copies of "
                                                     @"your chats. Files you received stay where they were saved. AI "
                                                     @"chat answers that quoted your chats stay in Chats until you "
                                                     @"delete them there.",
        @"settings.history.confirm.button" : @"Delete History",
        @"settings.reset.label" : @"Start over",
        // Settings' Nearby line: whether Friends can find people nearby, and what fixes it when it cannot.
        @"settings.nearby.label" : @"Nearby",
        @"settings.nearby.note.identity" : @"Nearby starts once you reset Friends.",
        @"settings.nearby.note.not_asked" : @"Allow {app} to find people nearby. The first time, you’re asked "
                                            @"whether it may use your local network and Bluetooth.",
        @"settings.nearby.note.denied" : @"Local Network and Bluetooth access are off for {app}, so nobody nearby "
                                         @"appears. Turn them on in System Settings › Privacy & Security.",
        @"settings.nearby.note.network_denied" : @"Local Network access is off for {app}, so people on your Wi-Fi "
                                                 @"won’t appear. Turn it on in System Settings › Privacy & Security.",
        @"settings.nearby.note.bluetooth_denied" : @"Bluetooth access is off for {app}, so people nearby without "
                                                   @"Wi-Fi won’t appear. Turn it on in System Settings › Privacy & "
                                                   @"Security.",
        @"settings.nearby.note.wifi_off" : @"Wi-Fi is off. Turn it on to find people on your network and close by.",
        @"settings.nearby.note.radios_off" : @"Wi-Fi and Bluetooth are off. Turn on Wi-Fi to find people on your "
                                             @"network and close by, or Bluetooth to find people nearby without Wi-Fi.",
        @"settings.nearby.note.bluetooth_off" : @"Bluetooth is off. People nearby without Wi-Fi won’t appear.",
        @"settings.nearby.note.failed" : @"Nearby isn’t working right now.",
        @"settings.nearby.note.unsupported.network" : @"This computer can’t look for people on your network. {app} "
                                                      @"finds people nearby over Bluetooth.",
        @"settings.nearby.note.unsupported.bluetooth" : @"This computer can’t use Bluetooth. {app} finds people "
                                                        @"nearby on your network.",
        @"settings.nearby.note.unsupported.both" : @"{app} can’t find people nearby on this computer.",
        @"settings.nearby.note.ready" : @"{app} can find people nearby on your network and over Bluetooth.",
        @"settings.reset.note" : @"You get a new ID, and every friend has to add you again.",
        @"settings.reset.action" : @"Reset Friends…",
        @"settings.reset.confirm.title" : @"Reset Friends?",
        @"settings.reset.confirm.body" : @"This deletes your friends and conversations from this computer and gives "
                                         @"you a new ID. Every friend has to add you again. Files you received stay "
                                         @"where they were saved.",
        @"settings.reset.confirm.body.assistant" : @"This deletes your friends and conversations from this computer "
                                                   @"and gives you a new ID. Every friend has to add you again. Files "
                                                   @"you received stay where they were saved. AI chat answers that "
                                                   @"quoted your conversations stay in Chats until you delete them "
                                                   @"there.",
        @"settings.reset.confirm.button" : @"Reset Friends",

        // Search
        @"search.sender.you" : @"You",
        @"search.empty" : @"No messages or files match.",
    };
}

static NSDictionary<NSString *, NSString *> *ErrorEntries(void) {
    return @{
        @"error.invalid_field.text" : @"This message is too long. Split it into shorter messages.",
        @"error.invalid_field.query" : @"Searches can be up to 200 characters.",
        @"error.not_found" : @"This isn’t here anymore.",
        @"error.not_allowed" : @"That can’t be done right now.",
        @"error.rate_limited" : @"Too many at once. Try again in a moment.",
        @"error.rate_limited.seconds" : @"Too many at once. Try again in {seconds} seconds.",
        @"error.identity_unavailable" : @"Friends can’t open your identity on this computer. Reset Friends in Settings "
                                        @"to start again.",
        @"error.name_invalid" : @"Names can be 1 to 40 characters, without line breaks.",
        @"error.id_invalid" : @"That isn’t a Friends ID. IDs are two words, like amber\u2011falcon.",
        @"error.id_is_yours" : @"That’s your own ID.",
        @"error.already_friends" : @"You’re already friends.",
        @"error.already_friends.name" : @"{name} is already your friend.",
        @"error.blocked" : @"You blocked this person. Unblock them first.",
        @"error.blocked.name" : @"You blocked {name}. Unblock them first.",
        @"error.not_friends" : @"You’re not friends anymore. Add them again to send messages.",
        @"error.not_friends.name" : @"You’re not friends with {name} anymore. Add them again to send messages.",
        @"error.file_missing" : @"A file can’t be found or opened. Nothing was sent.",
        // set_received_folder: the folder the person picked in Settings' Change….
        @"error.received_folder.missing" : @"That folder can’t be found or opened. Choose another folder.",
        @"error.received_folder.not_allowed" : @"Files can’t be saved in that folder. Choose another folder.",
        @"error.file_missing.file" : @"{file} can’t be found or opened. Nothing was sent.",
        @"error.folder_not_supported" : @"Folders can’t be sent yet.",
        @"error.folder_not_supported.file" : @"Folders can’t be sent yet.",
        @"error.too_many_files" : @"Too many files at once. Nothing was sent.",
        @"error.too_many_files.max" : @"You can send up to {max} files at once. Nothing was sent.",
        @"error.source_changed" : @"A file changed since you attached it. Attach it again to send the current version.",
        @"error.source_changed.file" : @"{file} changed since you attached it. Attach it again to send the current "
                                       @"version.",
        @"error.disk_full" : @"There isn’t enough space on this computer. Free up some space, then try again.",
        @"error.disk_full.size" : @"There isn’t enough space on this computer. Free up {size}, then try again.",
        @"error.disk_full.file" : @"There isn’t enough space on this computer for {file}. Free up some space, then "
                                  @"accept it again.",
        @"error.disk_full.file_size" : @"There isn’t enough space on this computer for {file}. Free up {size}, then "
                                       @"accept it again.",
        @"error.disk_full.sending" : @"There isn’t enough space on this computer to send {file}. Free up some space, "
                                     @"then try again.",
        @"error.picture_invalid" : @"That picture can’t be used. Choose a picture under 5 MB.",
        @"error.scope_invalid" : @"The assistant’s access to this chat has ended. Ask again.",
        @"error.stale" : @"This changed in the meantime. Have another look.",
        // Cancel pressed on a message that left meanwhile (cancel_message): it was not withdrawn, and this says why.
        @"error.stale.message_delivered" : @"{first} already has it, so it can’t be cancelled.",
        @"error.stale.message_sending" : @"It’s already on its way to {first}, so it can’t be cancelled.",
        // Written to a connection that dropped before their computer answered: queued again, but it may have arrived.
        @"error.stale.message_sent" : @"{first} may already have it, so it can’t be cancelled.",
        @"error.internal" : @"Something went wrong in Friends. Try again.",
        @"error.internal.identity_not_removed" : @"Nothing was reset: Friends couldn’t remove your old ID from this "
                                                 @"computer. Make sure it’s unlocked, then try again.",
        // Before this computer reaches friends online: true nearby and, once it does, online too.
        @"add_by_id.sent" : @"Request sent to {id}. They’ll get it as soon as Friends reaches them, and you’ll be "
                            @"friends once they accept.",
        // Once this computer reaches friends online: the request also travels through the Friends host, from and to
        // any computer of either person.
        @"add_by_id.sent.online" : @"Request sent to {id}. They’ll get it while {apps} is open for both of you, and "
                                   @"you’ll be friends once they accept.",
    };
}

NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogViews(void) {
    NSMutableDictionary *entries = [TransferAndConversationEntries() mutableCopy];
    [entries addEntriesFromDictionary:NearbyEntries()];
    [entries addEntriesFromDictionary:PeopleAndSettingsEntries()];
    [entries addEntriesFromDictionary:ErrorEntries()];
    return entries;
}
