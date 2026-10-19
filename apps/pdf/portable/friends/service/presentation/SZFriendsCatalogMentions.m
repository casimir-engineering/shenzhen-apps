// Shenzhen Friends strings catalog, English: mentions (PROTOCOL.md § Mentions). Merged into the catalog with parts one
// and two (SZFriendsEnglishCatalog), and written by the same rules: for the person reading, about what happens.
//
// The person reading a mention sees someone named in a friend's message. Whether that someone is a friend, a stranger
// or the reader decides the words, and a stranger is always called by the name the sender wrote, never by an ID, so
// "{name}" below is that name.

#import "service/presentation/SZFriendsPresentationPrivate.h"

NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogMentions(void) {
    return @{
        // A mention's tooltip: who this is to the reader, before they click.
        @"mention.tooltip.friend" : @"Open your chat with {first}",
        @"mention.tooltip.stranger" : @"{name} isn’t your friend yet",
        @"mention.tooltip.requested" : @"You asked {name} to be friends",
        @"mention.tooltip.asked" : @"{name} wants to be friends",
        @"mention.tooltip.blocked" : @"You blocked {name}",
        @"mention.tooltip.moved" : @"This link no longer matches {name}",
        // The card a click on a stranger's mention opens: their name, their ID, and what the reader can do.
        @"mention.card.id" : @"Friends ID {id}",
        @"mention.card.requested" : @"Request sent",
        @"mention.card.asked" : @"Wants to be friends",
        @"mention.card.blocked" : @"Blocked",
        // The Friends host says the ID now belongs to another key: Add would reach someone else, so it is not offered.
        @"mention.card.moved" : @"This link no longer matches {name}: {id} belongs to someone else now.",
        @"mention.action.add" : @"Add",
        // Under the @ picker, for the person writing: what the friend they are writing to can do with the name.
        @"mention.note" : @"{first} can click the name to open their chat with that person, or to add them if they "
                          @"aren’t friends yet.",
        @"composer.hint.mention" : @"Mention",
        @"add_from_mention.sent" : @"Request sent to {name}. They’ll get it as soon as Friends reaches them, and "
                                   @"you’ll be friends once they accept.",
        @"add_from_mention.sent.online" : @"Request sent to {name}. They’ll get it while {apps} is open for both of "
                                          @"you, and you’ll be friends once they accept.",
        @"error.mention_mismatch" : @"This link no longer matches that person, so no request was sent.",
        @"error.mention_mismatch.name" : @"This link no longer matches {name}, so no request was sent.",
    };
}
