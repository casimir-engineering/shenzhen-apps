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
        @"join.row.subtitle" : @"{system} · Approve only if you’re setting it up now",
        @"join.row.approve" : @"Approve",
        @"join.row.deny" : @"Deny",
        @"join.row.deny.arm" : @"Deny?",
        @"join.row.deny.arm.accessibility" : @"Click again to deny {device}",
        @"join.row.accessibility" : @"{device} wants to join your profile, {system}",
        @"join.row.approved.title" : @"Type this code on {device}",
        @"join.row.approved.subtitle" : @"{system} · Waiting for the code",
        @"join.row.approved.note" : @"It works until {time}. Type it only on {device}, and never send it to anyone.",
        @"join.row.approved.cancel" : @"Cancel",
        @"join.row.approved.accessibility" : @"Type the code {code} on {device}. It works until {time}.",
        // The new computer.
        @"join.title" : @"Use your existing profile",
        @"join.idle.message" : @"Type the Friends ID you use on your other computer or phone. You’ll approve this "
                               @"computer there.",
        @"join.idle.placeholder" : @"Friends ID",
        @"join.idle.button" : @"Continue",
        @"join.waiting.title" : @"Approve this computer",
        @"join.waiting.message" : @"On your computer or phone that uses {id}, open Friends in {apps} and choose "
                                  @"Approve. Then type the code it shows.",
        @"join.code.placeholder" : @"8-digit code",
        @"join.code.button" : @"Join",
        @"join.checking.message" : @"Checking the code with your other computer or phone…",
        @"join.wrong_code" : @"That code didn’t match. Check the code on your other computer or phone and type it "
                             @"again.",
        @"join.not_reached" : @"Your other computer or phone didn’t answer. Open {apps} there, and type the code "
                              @"again.",
        @"join.denied.title" : @"This computer wasn’t approved",
        @"join.denied.message" : @"Your other computer or phone chose Deny. Start again if you meant to approve it.",
        @"join.expired.title" : @"The code expired",
        @"join.expired.message" : @"A code works for 5 minutes. Start again to get a new one.",
        @"join.too_many.title" : @"Too many wrong codes",
        @"join.too_many.message" : @"After three wrong codes, the code stops working. Start again to get a new one.",
        @"join.start_again" : @"Start again",
        @"join.cancel" : @"Cancel",
        @"join.joined.title" : @"This computer now uses your profile",
        @"join.joined.message" : @"Your friends and chats arrive from your other computers and phones while they’re "
                                 @"nearby or online.",
        @"join.unavailable.message" : @"You already have friends here. To use your existing profile instead, choose "
                                      @"Use my existing profile… in Settings.",
        // Offering it, in Settings and on the list of a computer with nothing else on it yet. The reader set up
        // Friends somewhere else first and wonders how to get those friends and chats here; joining replaces what
        // this computer has, so when it has anything to lose the confirmation says what goes. {id} is this
        // computer's own ID.
        @"join.offer.action" : @"Use my existing profile…",
        @"join.offer.note" : @"Already use Friends on another computer or phone? Bring your friends and chats from it "
                             @"here.",
        @"settings.join.label" : @"Your existing profile",
        @"join.offer.confirm.title" : @"Use your existing profile here?",
        @"join.offer.confirm.body" : @"This computer’s own ID, {id}, and its friends and chats are deleted from this "
                                     @"computer. Then you type your ID from your other computer or phone, approve "
                                     @"there, and your friends and chats come here. Files you received stay where "
                                     @"they were saved.",
        @"join.offer.confirm.body.assistant" :
            @"This computer’s own ID, {id}, and its friends and chats are deleted from this computer. Then you type "
            @"your ID from your other computer or phone, approve there, and your friends and chats come here. Files "
            @"you received stay where they were saved. AI chat answers that quoted your conversations stay in Chats "
            @"until you delete them there.",
        @"join.offer.confirm.button" : @"Delete and Continue",
        // Replies.
        @"error.not_found.join" : @"This request is no longer waiting. The other computer may have started again.",
        @"error.not_allowed.join" : @"You already have friends here. To use your existing profile instead, choose "
                                    @"Use my existing profile… in Settings.",
        @"error.invalid_field.code" : @"Type the 8 digits your other computer or phone shows.",
    };
}
