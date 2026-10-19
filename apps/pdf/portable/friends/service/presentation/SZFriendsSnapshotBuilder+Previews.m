// Shenzhen Friends snapshot builder: the words items and list rows share. The list row's preview of the latest item
// ("Sends when Priya is nearby · Supplier contract v3.pdf"), event text, the outgoing status a row and a spoken label
// share, and which failures Try again can still change. Split from +Items so each file stays under the size cap.

#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

// Long previews are cut so a list snapshot never carries whole 32 KB messages; views truncate visually anyway.
static const NSUInteger SZFriendsPreviewLength = 120;

// Failures that trying again cannot change: the other Mac turned the item down, or the file to send is gone (the
// person attaches or drops it again instead). Unknown keys keep Try again, as a failure without a reason always has.
static BOOL RetryCanWork(NSString *failureReason) {
    return ![failureReason isEqualToString:SZFriendsFailureRefused] &&
           ![failureReason isEqualToString:SZFriendsFailureSourceMissing];
}

@implementation SZFriendsSnapshotBuilder (SZFriendsPreviews)

#pragma mark - Words shared by items and previews

// `key` with the failure's own words when the catalog has them ("message.status.failed.not_delivered_30_days"),
// otherwise `key` itself, whose general words stay true for any failure. Remove and block withdraw whatever was still
// waiting to go and the store records it as refused, so a refusal toward someone removed or blocked gets words about
// what the person did ("...refused.removed") rather than about the other Mac.
- (NSString *)key:(NSString *)key forFailure:(NSString *)failureReason person:(SZFriendsPersonFacts *)person {
    if (!failureReason.length) return key;
    NSDictionary<NSString *, NSString *> *catalog = SZFriendsEnglishCatalog();
    NSString *specific = [NSString stringWithFormat:@"%@.%@", key, failureReason];
    NSString *ended = person.relation == SZFriendsPersonRelationRemoved   ? @"removed"
                      : person.relation == SZFriendsPersonRelationBlocked ? @"blocked"
                                                                          : nil;
    if (ended && [failureReason isEqualToString:SZFriendsFailureRefused]) {
        NSString *own = [NSString stringWithFormat:@"%@.%@", specific, ended];
        if (catalog[own]) return own;
    }
    return catalog[specific] ? specific : key;
}

// Try again sends to the person, so it shows only while sending to them can work: not to someone blocked or no
// longer a friend, and not past a key change they have not reviewed (the composer is disabled for the same reasons).
- (BOOL)canRetryFailure:(NSString *)failureReason person:(SZFriendsPersonFacts *)person {
    return person.relation == SZFriendsPersonRelationFriend && !person.keyChangePending && RetryCanWork(failureReason);
}

- (NSString *)previewText:(NSString *)text {
    NSCharacterSet *spaces = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSArray<NSString *> *words = [text componentsSeparatedByCharactersInSet:spaces];
    NSString *collapsed = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]]
        componentsJoinedByString:@" "];
    if (collapsed.length <= SZFriendsPreviewLength) return collapsed;
    NSRange keep = [collapsed rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, SZFriendsPreviewLength)];
    return [[collapsed substringWithRange:keep] stringByAppendingString:@"…"];
}

// A catalog phrase inside a spoken label, lowered only when it does not open with the person's name or ID:
// "You are now friends" becomes "you are now friends", "Mei's key changed" stays as it is.
- (NSString *)spokenPhrase:(NSString *)phrase person:(SZFriendsPersonFacts *)person {
    NSString *first = [self firstNameForPerson:person];
    if ((first.length && [phrase hasPrefix:first]) || (person.friendsID.length && [phrase hasPrefix:person.friendsID]))
        return phrase;
    return [self.strings spokenFragment:phrase];
}

- (NSString *)eventTextForItem:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person {
    NSString *kind = item.eventKind ?: @"";
    // Only kinds with a catalog entry are shown; the header makes a new kind add its words here first.
    NSString *key = [@"event." stringByAppendingString:kind];
    if (!SZFriendsEnglishCatalog()[key]) return nil;
    NSMutableDictionary *values = [@{@"first" : [self firstNameForPerson:person]} mutableCopy];
    NSString *file = item.eventArguments[@"file"];
    if ([file isKindOfClass:NSString.class]) values[@"file"] = file;
    return [self.strings text:key values:values];
}

// The outgoing status suffix a list row and a spoken label share; nil when nothing needs saying.
- (NSString *)statusKeyForItem:(SZFriendsItemFacts *)item {
    if (item.kind == SZFriendsItemFactsKindMessage) {
        if (!item.outgoing) return nil;
        if (item.cancelled) return @"cancelled";
        if (item.outboxState == SZFriendsOutboxStateQueued) return @"queued";
        if (item.outboxState == SZFriendsOutboxStateFailed) return @"failed";
        return nil;
    }
    switch (item.transferState) {
    case SZFriendsTransferStateQueued: return @"queued";
    case SZFriendsTransferStateOffered: return @"offered";
    case SZFriendsTransferStateSending: return @"sending";
    case SZFriendsTransferStateReceiving: return @"receiving";
    case SZFriendsTransferStateDeclined: return item.outgoing ? @"declined_by_them" : @"declined_by_you";
    case SZFriendsTransferStateCancelled: return @"cancelled";
    case SZFriendsTransferStateFailed: return item.outgoing ? @"failed" : @"didnt_arrive";
    case SZFriendsTransferStateReceived: return item.acceptedAutomatically ? @"auto" : nil;
    case SZFriendsTransferStateWaitingForYou: return @"waiting";
    default: return nil;
    }
}

- (NSString *)previewForItem:(SZFriendsItemFacts *)item
                      person:(SZFriendsPersonFacts *)person
                      spoken:(NSString **)spoken
               explainsRoute:(BOOL *)explainsRoute {
    SZFriendsStrings *s = self.strings;
    NSDictionary *who = @{@"first" : [self firstNameForPerson:person]};
    *explainsRoute = NO;
    if (!item) {
        *spoken = @"";
        return @"";
    }
    if (item.kind == SZFriendsItemFactsKindEvent) {
        NSString *text = [self eventTextForItem:item person:person] ?: @"";
        *spoken = [self spokenPhrase:text person:person];
        return text;
    }
    BOOL message = item.kind == SZFriendsItemFactsKindMessage;
    // A mention previews as "@Name", never as its link (PROTOCOL.md § Mentions).
    NSString *content = message ? [self previewText:[self plainTextOf:item.text ?: @""]] : (item.fileName ?: @"");
    NSString *status = [self statusKeyForItem:item];
    *explainsRoute = [status isEqualToString:@"queued"];
    NSString *visual = content, *said = content;
    if (item.outgoing) {
        visual = [s text:@"preview.you" values:@{@"text" : content}];
        said = [s text:message ? @"preview.you_said" : @"preview.you_sent" values:@{@"text" : content}];
    } else if (!message && [status isEqualToString:@"waiting"]) {
        visual = [s text:@"list.subtitle.offer" values:@{@"file" : content}];
        said = [s spokenFragment:visual];
        status = nil;
    }
    if (status) {
        // Status first, so a narrow row cut short still says whether it went; the status also says whose it is,
        // so "You:" goes ("Sends when Priya is nearby · Supplier contract v3.pdf"). Spoken, it follows the content.
        NSString *statusKey = [status isEqualToString:@"queued"]
                                  ? [self waitingKeyInFamily:@"preview.status" person:person]
                                  : [@"preview.status." stringByAppendingString:status];
        visual = [s text:@"preview.status_first" values:@{@"status" : [s text:statusKey values:who],
                                                           @"text" : content}];
        NSString *saidStatus = [s text:[statusKey stringByAppendingString:@".spoken"] values:who];
        said = [s text:@"preview.with_status.spoken" values:@{@"text" : said, @"status" : saidStatus}];
    }
    *spoken = said;
    return visual;
}

#pragma mark - Rows that refuse files

// Why a row will not take dragged files, said under the pointer (PROTOCOL.md list_row drop_refusal), or null when no
// file can be dragged in this client at all. Only called for rows that refuse.
- (id)dropRefusalForPerson:(SZFriendsPersonFacts *)person {
    if (![self.audience.capabilities containsObject:@"drop.files"]) return [NSNull null];
    NSString *key = @"list.drop_refusal.request";
    switch (person.relation) {
    case SZFriendsPersonRelationIncomingRequest:
    case SZFriendsPersonRelationOutgoingRequest: key = @"list.drop_refusal.request"; break;
    case SZFriendsPersonRelationRemoved: key = @"list.drop_refusal.removed"; break;
    case SZFriendsPersonRelationBlocked: key = @"list.drop_refusal.blocked"; break;
    case SZFriendsPersonRelationFriend: key = @"list.drop_refusal.key_change"; break;
    }
    return [self.strings text:key values:@{@"first" : [self firstNameForPerson:person]}];
}

@end
