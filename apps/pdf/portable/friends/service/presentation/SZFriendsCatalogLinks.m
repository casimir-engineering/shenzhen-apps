// Shenzhen Friends strings catalog, English: friend and download links (PROTOCOL.md § Links). Merged into the catalog
// with the other parts (SZFriendsEnglishCatalog), and written by the same rules: for the person reading, about what
// happens.
//
// Two readers. The person who makes links reads "Your links" in their profile and the message after copying one. The
// person who opened someone's link in this app reads its card, the message after pressing Add or Download, and, later,
// the row of whoever sent them a file. Requests by Friends ID travel only between computers that are nearby, so the
// words after Add say when the request can arrive.

#import "service/presentation/SZFriendsPresentationPrivate.h"

NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogLinks(void) {
    return @{
        // "Your links", in the profile.
        @"links.title" : @"Your links",
        @"links.friend.label" : @"Your friend link",
        @"links.friend.note" : @"Whoever opens it can add you without waiting for you to accept. Reset it if it "
                               @"reached someone it shouldn’t have.",
        @"links.friend.reset" : @"Reset link",
        @"links.friend.reset.confirm.title" : @"Reset your friend link?",
        @"links.friend.reset.confirm.body" : @"The link you shared stops working. Friends you already have stay "
                                             @"friends.",
        @"links.friend.reset.confirm.button" : @"Reset link",
        @"links.downloads.label" : @"Download links",
        @"links.downloads.empty" : @"Download links you copy show here, with how many times each was downloaded.",
        @"links.downloads.none" : @"No downloads yet",
        @"links.downloads.count.one" : @"1 download",
        @"links.downloads.count.other" : @"{count} downloads",
        @"links.expires.today" : @"Expires today",
        @"links.expires.tomorrow" : @"Expires tomorrow",
        @"links.expires.days.one" : @"Expires in 1 day",
        @"links.expires.days.other" : @"Expires in {count} days",
        @"links.revoke" : @"Revoke",
        // The card a link opens on.
        @"link.friend.title" : @"Add {name}?",
        @"link.friend.subtitle" : @"Friends ID {id}",
        @"link.friend.note" : @"{name} made this link, so you’ll be friends as soon as your request reaches "
                              @"{name}.",
        @"link.friend.already" : @"You’re already friends with {name}",
        @"link.friend.add" : @"Add",
        @"link.download.title" : @"Download this file?",
        @"link.download.note" : @"It comes straight from the computer of the person who shared it, while "
                                @"{apps} is open there.",
        @"link.download.action" : @"Download",
        // After pressing.
        @"link.request_sent" : @"Request sent to {name}. They get it as soon as Friends reaches them, and you’re "
                               @"friends as soon as it arrives.",
        @"link.request_sent.online" : @"Request sent to {name}. It reaches them while {apps} is open for both of you, "
                                      @"and you’re friends as soon as it does.",
        @"link.receiving" : @"Receiving {file} from {name}. You’ll find it in your chat with {first} once it "
                            @"arrives.",
        @"link.receiving.anonymous" : @"Receiving {file}. You’ll find it in Friends once it arrives.",
        @"link.made" : @"Download link copied. It works until {date}, whenever this computer is on with {apps} "
                       @"open.",
        // History and rows.
        @"event.received_through_link" : @"Sent you {file} through a link",
        @"event.added_through_your_link" : @"Added through your link",
        @"event.added_through_their_link" : @"Added through {first}’s link",
        @"composer.note.link_contact" : @"Add {first} as a friend to send messages.",
        @"transfer.action.add" : @"Add {first}",
        // Errors of the link intents.
        @"error.not_found.link" : @"This link no longer works. Ask for a new one.",
        @"error.invalid_field.payload" : @"This link isn’t complete. Copy the whole link and open it again.",
        @"error.link_offline" : @"The computer this file comes from isn’t online right now. It can send the file while "
                                @"{apps} is open there.",
        @"error.link_changed" : @"The file changed after this link was made. Ask for a new link.",
        @"error.link_failed" : @"The file couldn’t be received. Try again.",
        @"error.too_many_links" : @"You have 50 download links already. Revoke one to make another.",
    };
}
