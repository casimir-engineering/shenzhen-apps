// Arriving and typed messages: every Friends link that is not a mention to keep becomes plain text
// (SZFriendsMentions.h, PROTOCOL.md § Mentions). SZFriendsMentions.m finds the links.

#import "service/presentation/SZFriendsMentions.h"

// `text` with each link `keep` refuses replaced by its words as plain text. Replacing can bring a new link together
// from the text around it ("[[a](szfriends:x)](szfriends:y)"), so the pass repeats until nothing refused is left; each
// pass removes characters, and after a few a text still forming links loses every bracket's power instead.
static NSString *Replaced(NSString *text, BOOL (^keep)(SZFriendsTextLink *link, NSUInteger mentionsKept)) {
    for (int pass = 0; pass < 4; pass++) {
        NSArray<SZFriendsTextLink *> *links = SZFriendsTextLinks(text);
        NSMutableString *result = [NSMutableString stringWithCapacity:text.length];
        NSUInteger cursor = 0, kept = 0;
        BOOL changed = NO;
        for (SZFriendsTextLink *link in links) {
            [result appendString:[text substringWithRange:NSMakeRange(cursor, link.range.location - cursor)]];
            if (keep(link, kept)) {
                kept++;
                [result appendString:[text substringWithRange:link.range]];
            } else {
                changed = YES;
                [result appendString:SZFriendsMarkdownLiteral(link.shownText)];
            }
            cursor = NSMaxRange(link.range);
        }
        if (!changed) return text;
        [result appendString:[text substringFromIndex:cursor]];
        text = result;
    }
    // Shown exactly as written, Markdown and all: nothing in it can be a link any more.
    return SZFriendsMarkdownLiteral(text);
}

NSString *SZFriendsMentionsChecked(NSString *text, BOOL (^validID)(NSString *friendsID)) {
    return Replaced(text, ^BOOL(SZFriendsTextLink *link, NSUInteger kept) {
      return link.isMention && kept < SZFriendsMentionsMax && validID(link.friendsID);
    });
}

NSString *SZFriendsMentionsNeutralized(NSString *text) {
    return Replaced(text, ^BOOL(SZFriendsTextLink *link, NSUInteger kept) {
      (void)link;
      (void)kept;
      return NO;
    });
}
