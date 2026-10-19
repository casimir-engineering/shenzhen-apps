// Shenzhen Friends snapshot builder: friend details and the person's own profile page.
//
// A friend's new key is never accepted silently (brief § Identity and keys): details shows the key change with an
// explicit choice. Comparison codes show only while a live session has one, because a code compared against a
// stale screen proves nothing.

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/identity/SZFriendsIdentity.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsDetails)

- (NSDictionary *)verificationForPerson:(SZFriendsPersonFacts *)person now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSDictionary *who = @{@"first" : [self firstNameForPerson:person]};
    if (person.verified) {
        NSString *label = person.verifiedAt
                              ? [s text:@"verification.verified_on"
                                 values:@{@"day" : [s dayPhraseForDate:person.verifiedAt now:now]}]
                              : [s text:@"verification.verified"];
        return @{@"state" : @"verified", @"label" : label, @"body" : [NSNull null], @"comparison_code" : [NSNull null],
                 @"action" : [NSNull null]};
    }
    SZFriendsShownRoute shown = [self shownRouteForPerson:person];
    BOOL live = shown == SZFriendsShownRouteLocal || shown == SZFriendsShownRouteOnline;
    NSString *code = live && person.comparisonCode.length == 6 ? person.comparisonCode : nil;
    id action = [NSNull null];
    if (code && person.relation == SZFriendsPersonRelationFriend)
        action = [self action:@"mark_verified" label:[s text:@"verification.codes_match"] style:@"primary"];
    return @{
        @"state" : @"unverified",
        @"label" : [s text:@"verification.unverified"],
        @"body" : [s text:code ? @"verification.body.compare" : @"verification.body.later" values:who],
        @"comparison_code" : code ? [s groupedComparisonCode:code] : [NSNull null],
        @"action" : action
    };
}

// Delete chat history… for one person, asking first. The question says what goes (messages, the file history and
// anything still waiting to go, from this Mac) and what stays (the person where they are, their own copy, files
// received, and AI chat answers when this host's AI chat may have quoted the chat), as Settings' question does for
// every chat.
- (NSMutableDictionary *)deleteHistoryActionForPerson:(SZFriendsPersonFacts *)person values:(NSDictionary *)who {
    SZFriendsStrings *s = self.strings;
    BOOL friend = person.relation == SZFriendsPersonRelationFriend;
    BOOL blocked = person.relation == SZFriendsPersonRelationBlocked;
    NSString *stays = friend ? @"details.history.confirm.stays.friend"
                      : blocked ? @"details.history.confirm.stays.blocked"
                                : @"details.history.confirm.stays";
    // On several computers the chat goes from every one of them (ADR 0014), and the words say so (+Devices).
    NSString *every = self.deletesOnEveryComputer ? @".devices" : @"";
    NSString *goes = [@"details.history.confirm.goes" stringByAppendingString:every];
    NSMutableArray<NSString *> *body = [NSMutableArray arrayWithObjects:
        [s text:goes values:who], [s text:stays values:who],
        [s text:@"details.history.confirm.files" values:who], nil];
    if ([self.audience.capabilities containsObject:@"assistant.chats"])
        [body addObject:[s text:@"details.history.confirm.assistant" values:who]];
    NSMutableDictionary *confirm = [[self confirmWithTitle:@"details.history.confirm.title"
                                                      body:@"details.history.confirm.goes"
                                              confirmLabel:@"settings.history.confirm.button"
                                                    values:who
                                               destructive:YES] mutableCopy];
    confirm[@"body"] = [body componentsJoinedByString:@" "];
    NSMutableDictionary *action = [self action:@"delete_history" label:[s text:@"details.history.action"]
                                         style:@"destructive"];
    NSString *note = friend ? @"details.history.note.friend" : @"details.history.note";
    action[@"note"] = [s text:[note stringByAppendingString:every] values:who];
    action[@"confirm"] = confirm;
    return action;
}

- (NSDictionary<NSString *, id> *)buildDetailsForPerson:(SZFriendsPersonFacts *)person
                                  waitingElsewhere:(NSInteger)waitingElsewhere
                                               now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSString *first = [self firstNameForPerson:person];
    NSDictionary *who = @{@"first" : first, @"app" : self.audience.revealIn};
    BOOL blocked = person.relation == SZFriendsPersonRelationBlocked;
    BOOL friend = person.relation == SZFriendsPersonRelationFriend;
    // Counted like the conversation's arrow: rows waiting in the list other than this person's, which waits in the
    // conversation the arrow leads to, so its own row makes the others "more".
    NSString *waitingKey = [self personWaits:person] ? @"back.conversation.more_waiting" : @"back.conversation.waiting";
    NSString *backLabel = waitingElsewhere > 0 ? [s text:waitingKey count:waitingElsewhere values:who]
                                               : [s text:@"back.conversation" values:who];
    id received = [NSNull null];
    if (person.receivedFileCount > 0) {
        id show = [NSNull null];
        if (person.receivedRevealPath.length) {
            NSString *label = [s text:@"action.show_in" values:@{@"app" : self.audience.revealIn}];
            NSMutableDictionary *action = [self action:@"show_file" label:label style:@"link"];
            action[@"path"] = person.receivedRevealPath;
            show = action;
        }
        received = @{
            @"label" : [s text:@"details.received" count:person.receivedFileCount values:who],
            @"count" : @(person.receivedFileCount),
            @"action" : show
        };
    }
    id keyChange = [NSNull null];
    if (person.keyChangePending && !blocked) {
        keyChange = @{
            @"title" : [s text:@"key_change.title" values:who],
            @"body" : [s text:@"key_change.body" values:who],
            @"actions" : @[
                [self action:@"accept_key_change" label:[s text:@"key_change.accept"] style:@"primary"],
                [self blockActionNaming:first label:[s text:@"action.block" values:who]]
            ]
        };
    }
    // Deleting this chat's history comes first: it is the lightest of these and leaves the person where they are.
    NSMutableArray *actions = [NSMutableArray arrayWithObject:[self deleteHistoryActionForPerson:person values:who]];
    if (blocked) {
        NSMutableDictionary *unblock = [self action:@"unblock" label:[s text:@"action.unblock" values:who]
                                              style:@"secondary"];
        unblock[@"note"] = [s text:@"details.unblock_note" values:who];
        [actions addObject:unblock];
    } else {
        if (friend) {
            // Ending a friendship cannot be undone from this side (the friend must ask again), so it asks first.
            NSMutableDictionary *remove = [self action:@"remove_friend" label:[s text:@"action.remove"]
                                                 style:@"destructive"];
            remove[@"note"] = [s text:@"details.remove_note" values:who];
            remove[@"confirm"] = [self confirmWithTitle:@"action.remove.confirm.title"
                                                   body:@"action.remove.confirm.body"
                                           confirmLabel:@"action.remove.confirm.button"
                                                 values:who
                                            destructive:YES];
            [actions addObject:remove];
        }
        NSMutableDictionary *block = [self blockActionNaming:first label:[s text:@"action.block" values:who]];
        block[@"note"] = [s text:@"details.block_note" values:who];
        [actions addObject:block];
    }
    BOOL hasID = person.friendsID.length > 0;
    BOOL confirmed = hasID && person.friendsIDConfirmed;
    return @{
        @"conversation_id" : person.conversationID,
        @"title" : [self titleForPerson:person],
        @"back" : @{
            @"badge_count" : @(MAX(waitingElsewhere, 0)),
            @"badge_label" : [s badgeLabelForCount:waitingElsewhere],
            @"accessibility_label" : backLabel
        },
        @"avatar" : [self avatarForPerson:person],
        @"route" : [self routeForPerson:person],
        @"friends_id" : hasID ? person.friendsID : [NSNull null],
        @"id_label" : hasID ? [s text:@"id.label" values:@{@"id" : [s displayID:person.friendsID]}] : [NSNull null],
        @"id_confirmed" : SZFriendsBool(confirmed),
        @"id_confirmed_label" : confirmed ? [s text:@"id.confirmed"] : [NSNull null],
        @"copy_id_accessibility_label" : hasID ? [s text:@"details.copy_id" values:who] : [NSNull null],
        @"verification" : [self verificationForPerson:person now:now],
        @"auto_accept" : @{
            @"available" : SZFriendsBool(friend),
            @"enabled" : SZFriendsBool(friend && person.autoAccept),
            @"title" : [s text:@"auto_accept.title" values:who],
            @"body" : [s text:@"auto_accept.body" values:who]
        },
        @"received" : received,
        @"key_change" : keyChange,
        @"actions" : actions
    };
}

- (NSDictionary<NSString *, id> *)buildProfileWithFacts:(SZFriendsProfileFacts *)profile
                                  waitingElsewhere:(NSInteger)waitingElsewhere {
    SZFriendsStrings *s = self.strings;
    NSString *name = [profile.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *state, *note;
    if (profile.identityState == SZFriendsIdentityFactsStateUnavailable) {
        state = @"unavailable";
        note = [s text:@"id.unavailable"];
    } else if (profile.friendsIDState == SZFriendsIDStateReserved) {
        state = @"reserved";
        note = [s text:@"id.reserved"];
    } else if (profile.friendsIDState == SZFriendsIDStateChanged) {
        state = @"changed";
        NSDictionary *ids =
            @{@"id" : [s displayID:profile.friendsID], @"old" : [s displayID:profile.previousFriendsID]};
        note = profile.previousFriendsID.length ? [s text:@"banner.id_changed" values:ids] : [s text:@"id.changed"];
    } else {
        state = @"unreserved";
        note = [self idNoteForProfile:profile];
    }
    SZFriendsPicture *picture = profile.picture;
    BOOL animal = picture.kind == SZFriendsPictureKindAnimal;
    NSInteger set = self.animalSet ? self.animalSet.version : (animal ? picture.animalSet : 1);
    NSMutableDictionary *data = [@{
        @"title" : [s text:@"profile.title"],
        @"back" : [self backToFriendsWithCount:waitingElsewhere thisRowWaits:NO],
        @"name" : @{
            @"label" : [s text:@"profile.name.label"],
            @"value" : name.length ? name : [NSNull null],
            @"placeholder" : [s text:@"name.placeholder"],
            @"max_length" : @40 // PROTOCOL.md § Limits
        },
        @"picture" : @{
            @"avatar" : [self avatarForPicture:picture seed:profile.friendsID
                                   displayName:name.length ? name : profile.friendsID],
            @"choose_label" : [s text:@"profile.picture.choose"],
            @"own_picture_label" : [s text:@"profile.picture.own"],
            @"animal_set" : @(set),
            @"selected_index" : animal ? @(picture.animalIndex) : [NSNull null]
        },
        @"id" : @{
            @"label" : [s text:@"profile.id.label"],
            @"friends_id" : profile.friendsID,
            @"state" : state,
            @"note" : note,
            @"copy_label" : [s text:@"static.copy"],
            // No QR in M1: nothing on a Mac or a phone can open what it would encode yet, so a code to scan would
            // invite something that does nothing (UX critique). PROTOCOL.md § profile keeps the fields for later.
            @"qr_label" : [NSNull null],
            @"qr_payload" : [NSNull null]
        },
        @"add" : @{
            @"label" : [s text:@"profile.add.label"],
            @"placeholder" : [s text:@"profile.add.placeholder"],
            @"button_label" : [s text:@"profile.add.button"],
            @"hint" : [s text:@"profile.add.hint"]
        }
    } mutableCopy];
    id links = [self linksSectionWithFacts:profile.links];
    if (links != nil) data[@"links"] = links;
    return data;
}

@end
