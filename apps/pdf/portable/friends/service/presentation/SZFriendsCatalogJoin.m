// Shenzhen Friends strings catalog, English: joining a profile from a new computer (PROTOCOL.md § Joining). Merged
// into the catalog with the other parts (SZFriendsEnglishCatalog), and written by the same rules.
//
// Two readers. On a computer that already has the profile, the person sees a row they did not cause from here: they
// wonder whether it is them, and what Approve does; the row names the computer as it named itself and says to approve
// only a computer they are setting up. After Approve they wonder where the code goes. On the new computer the person
// wonders what to type, where to approve, and, after a code, whether it worked and what comes next.

#import "service/presentation/SZFriendsPresentationPrivate.h"

NSDictionary<NSString *, NSString *> *SZFriendsEnglishCatalogJoin(void) {
    return @{
        // The row on the person's other computers.
        @"join.row.title" : @"{device} wants to join your profile",
        @"join.row.subtitle" : @"{system} · Approve only if you’re setting up that computer now",
        @"join.row.approve" : @"Approve",
        @"join.row.deny" : @"Deny",
        @"join.row.deny.arm" : @"Deny?",
        @"join.row.deny.arm.accessibility" : @"Click again to deny {device}",
        @"join.row.accessibility" : @"{device} wants to join your profile, {system}",
        @"join.row.approved.title" : @"Type this code on {device}",
        @"join.row.approved.subtitle" : @"{system} · Waiting for the code",
        @"join.row.approved.note" : @"It works until {time}. Type it on that computer only, and never send it to "
                                    @"anyone.",
        @"join.row.approved.cancel" : @"Cancel",
        @"join.row.approved.accessibility" : @"Type the code {code} on {device}. It works until {time}.",
        // The new computer.
        @"join.title" : @"Use your existing profile",
        @"join.idle.message" : @"Type the Friends ID of the profile you already use on another computer. You’ll "
                               @"approve this computer there.",
        @"join.idle.placeholder" : @"Friends ID",
        @"join.idle.button" : @"Continue",
        @"join.waiting.title" : @"Approve this computer",
        @"join.waiting.message" : @"On a computer that uses {id}, open Friends in {apps} and choose Approve. "
                                  @"Then type the code it shows.",
        @"join.code.placeholder" : @"8-digit code",
        @"join.code.button" : @"Join",
        @"join.checking.message" : @"Checking the code with your other computer…",
        @"join.wrong_code" : @"That code didn’t match. Check the code on your other computer and type it again.",
        @"join.not_reached" : @"Your other computer didn’t answer. Open {apps} there, and type the code again.",
        @"join.denied.title" : @"This computer wasn’t approved",
        @"join.denied.message" : @"Your other computer chose Deny. Start again if you meant to approve it.",
        @"join.expired.title" : @"The code expired",
        @"join.expired.message" : @"A code works for 5 minutes. Start again to get a new one.",
        @"join.too_many.title" : @"Too many wrong codes",
        @"join.too_many.message" : @"After three wrong codes, the code stops working. Start again to get a new one.",
        @"join.start_again" : @"Start again",
        @"join.cancel" : @"Cancel",
        @"join.joined.title" : @"This computer now uses your profile",
        @"join.joined.message" : @"Your friends and chats arrive from your other computers while they’re nearby or "
                                 @"online.",
        @"join.unavailable.message" : @"This computer already has friends in Friends. To use your existing profile "
                                      @"here instead, choose Reset Friends in Settings first.",
        // Replies.
        @"error.not_found.join" : @"This request is no longer waiting. The other computer may have started again.",
        @"error.not_allowed.join" : @"This computer already has friends in Friends. Choose Reset Friends in Settings "
                                    @"to use your existing profile here.",
        @"error.invalid_field.code" : @"Type the 8 digits the other computer shows.",
    };
}
