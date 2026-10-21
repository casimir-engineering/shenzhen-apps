// A file the person moved or deleted, in snapshots (PROTOCOL.md § Getting a file again). The reader is the person who
// received it: the item says it is not where it was saved anymore and, for a file a friend sent that none of their
// computers holds, offers Get again from that friend, then says how it is coming or that the friend no longer has it.
// A file another of the person's computers still holds is shown by +Devices ("On Raph’s Mac mini" with Get).

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"

@implementation SZFriendsSnapshotBuilder (SZFriendsAgain)

- (NSDictionary<NSString *, id> *)transferWhereItIs:(NSDictionary<NSString *, id> *)transfer
                                              item:(SZFriendsItemFacts *)item
                                            person:(SZFriendsPersonFacts *)person {
    NSString *transferID = transfer[@"transfer_id"];
    BOOL onAnotherComputer = transferID != nil && self.devices.files[transferID] != nil;
    if (!item.fileMissing || onAnotherComputer) return [self transferWithDevices:transfer item:item person:person];
    SZFriendsStrings *s = self.strings;
    NSDictionary *fileInfo = transfer[@"file"];
    NSString *name = [self titleForPerson:person];
    NSMutableDictionary<NSString *, NSString *> *values = [@{
        @"sender" : item.outgoing ? @"" : name,
        @"file" : fileInfo[@"name"] ?: @"",
        @"kind" : fileInfo[@"kind_label"] ?: @"",
        @"size" : fileInfo[@"size_label"] ?: @"",
        @"device" : name,
        @"name" : name,
        @"apps" : [s text:@"apps.with_friends"]
    } mutableCopy];
    // Only a friend's own file comes back from them; anything else stays moved or deleted.
    BOOL fromFriend = !item.outgoing && person.relation == SZFriendsPersonRelationFriend &&
                      ![person.conversationID isEqualToString:@"you"];
    SZFriendsAgainState again = fromFriend ? item.again : SZFriendsAgainNone;
    long percent = MIN(100L, MAX(0L, (long)floor(item.againFraction * 100.0)));
    values[@"percent"] = [NSString stringWithFormat:@"%ld", percent];
    NSString *state = @"fetching", *status, *spokenKey = item.outgoing ? @"devices.spoken.transfer.out"
                                                                      : @"devices.spoken.transfer.in";
    id progress = [NSNull null];
    NSString *note = nil;
    NSArray *actions = @[ [self action:@"cancel_transfer" label:[s text:@"static.cancel"] style:@"link"] ];
    if (again == SZFriendsAgainGone) {
        state = @"gone";
        status = [s text:@"transfer.status.again_gone" values:values];
        spokenKey = @"devices.spoken.transfer.gone";
        actions = @[];
    } else if (again == SZFriendsAgainAsked && item.againConnected) {
        status = [s text:@"transfer.status.fetching" values:values];
        progress = [self progressWithFraction:item.againFraction];
        spokenKey = @"devices.spoken.transfer.fetching";
        // From the friend, like any file they send: a slow route says so, with the time left once it can tell.
        double arrived = MIN(MAX(item.againFraction, 0.0), 1.0) * (double)item.fileSize;
        uint64_t remaining = item.fileSize - MIN(item.fileSize, (uint64_t)arrived);
        note = [s transferEstimateForRemainingBytes:remaining bytesPerSecond:item.bytesPerSecond
                                              route:item.transferRoute];
    } else if (again == SZFriendsAgainAsked) {
        status = [s text:s.reachesOnline ? @"transfer.status.fetch_waiting.online" : @"transfer.status.fetch_waiting"
                  values:values];
    } else {
        state = @"missing";
        status = [s text:@"transfer.status.missing"];
        BOOL offered = fromFriend && [self.audience.capabilities containsObject:@"files.again"];
        actions = offered ? @[ [self action:@"fetch_from_friend" label:[s text:@"transfer.action.again"]
                                      style:@"primary"] ]
                          : @[];
    }
    // Said inside a sentence, except "gone", a sentence of its own; the templates end the sentence themselves.
    NSString *said = [state isEqualToString:@"gone"] ? status : [s spokenFragment:status];
    values[@"status"] = [said hasSuffix:@"."] ? [said substringToIndex:said.length - 1] : said;
    NSMutableDictionary *result = [transfer mutableCopy];
    result[@"state"] = state;
    result[@"status_label"] = status;
    result[@"progress"] = progress;
    result[@"route_note"] = note ?: [NSNull null];
    result[@"actions"] = actions;
    result[@"accessibility_label"] = [s text:spokenKey values:values];
    return result;
}

@end
