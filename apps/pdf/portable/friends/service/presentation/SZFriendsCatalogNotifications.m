// Shenzhen Friends strings catalog, English: system notifications (PROTOCOL.md § Notifications, ADR 0017). Merged
// into the catalog with the other parts (SZFriendsEnglishCatalog), and written by the same rules.
//
// The reader glances at a banner while doing something else, or at a phone's lock screen: the title says who, the
// body says what, in as few words as the list would use. {name} is the friend's name as the list shows it, {file} a
// file's name, {device} a computer's or phone's own name, {count} a number, {app} the app Friends runs in.

#import "service/presentation/SZFriendsPresentationPrivate.h"

NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogNotifications(void) {
    return @{
        // Messages. The title is {name}; the body the message's text, or these when Show message text is off.
        @"notify.message.hidden.one" : @"New message",
        @"notify.message.hidden.other" : @"{count} new messages",
        @"notify.reply" : @"Reply",
        @"notify.reply.placeholder" : @"Message {name}",
        @"notify.reply.send" : @"Send",
        // Files. "more" counts the files after the first in the same batch.
        @"notify.file.offer" : @"{name} wants to send you {file}",
        @"notify.file.offer.more.one" : @"{name} wants to send you {file} and 1 more file",
        @"notify.file.offer.more.other" : @"{name} wants to send you {file} and {count} more files",
        @"notify.file.offer.hidden.one" : @"{name} wants to send you a file",
        @"notify.file.offer.hidden.other" : @"{name} wants to send you {count} files",
        @"notify.file.received" : @"{name} sent {file}",
        @"notify.file.received.more.one" : @"{name} sent {file} and 1 more file",
        @"notify.file.received.more.other" : @"{name} sent {file} and {count} more files",
        @"notify.file.received.hidden.one" : @"{name} sent a file",
        @"notify.file.received.hidden.other" : @"{name} sent {count} files",
        // Requests and links. The title is {name}.
        @"notify.request" : @"Wants to be friends",
        @"notify.accepted" : @"Accepted your friend request",
        @"notify.link.used" : @"Used your friend link, so you’re now friends",
        @"notify.link.added" : @"You’re now friends",
        // A computer or phone asking to join the person's profile: the title is the body here.
        @"notify.join.title" : @"{device} wants to join your profile",
        @"notify.join.body" : @"Approve it in Friends only if you’re setting it up now.",
        // Android's notification categories, as the phone's Settings lists them, and the quiet ongoing notification
        // while Stay reachable in the background is on.
        @"notify.channel.messages" : @"Messages",
        @"notify.channel.files" : @"Files",
        @"notify.channel.requests" : @"Requests",
        @"notify.channel.background" : @"Reachable in the background",
        @"notify.background.title" : @"Friends is reachable",
        @"notify.background.body" : @"Messages and files still arrive while {app} is closed.",
        @"notify.background.restart.title" : @"Friends stopped when your phone restarted",
        @"notify.background.restart.body" : @"Open {app} to get messages and files again.",
        // The list's card, before the system is asked (macOS, iOS).
        @"banner.notifications.text" : @"Get a notification when friends send you a message or a file.",
        @"banner.notifications.allow" : @"Turn On",
        @"banner.notifications.dismiss" : @"Not Now",
        // Settings › Notifications, this device only.
        @"settings.notifications.label" : @"Notifications",
        @"settings.notifications.enabled" : @"Show notifications",
        @"settings.notifications.preview" : @"Show message text",
        @"settings.notifications.preview.note" : @"When this is off, notifications say who sent something, not what "
                                                 @"it says.",
        @"settings.notifications.note.not_asked" : @"Friends hasn’t asked to show notifications yet.",
        @"settings.notifications.allow" : @"Allow",
        @"settings.notifications.note.denied.mac" : @"Notifications from Shenzhen Friends are off in System Settings.",
        @"settings.notifications.note.denied.phone" : @"Notifications from {app} are off in Settings.",
        @"settings.notifications.open_settings.mac" : @"Open System Settings",
        @"settings.notifications.open_settings.phone" : @"Open Settings",
        @"settings.notifications.note.denied.windows" : @"Notifications from Shenzhen Friends are off in Windows Settings.",
        @"settings.notifications.open_settings.windows" : @"Open Settings",
        @"settings.notifications.note.unavailable" : @"This computer has no notification service running, so Friends "
                                                     @"can’t show notifications.",
        @"settings.notifications.note.ios" : @"An iPhone gets messages and files only while {app} is open. Friends "
                                             @"has no server that could wake it.",
        @"settings.notifications.background.label" : @"Stay reachable in the background",
        @"settings.notifications.background.note" : @"Keeps Friends running while {app} is closed, so messages and "
                                                    @"files still arrive. This uses more battery all day, because "
                                                    @"your phone keeps looking for friends nearby and stays connected.",
    };
}
