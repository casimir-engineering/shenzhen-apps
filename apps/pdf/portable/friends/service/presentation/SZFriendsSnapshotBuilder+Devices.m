// One profile on several computers in snapshots (SZFriendsPresentationDevices.h, PROTOCOL.md § Devices). The reader is
// the person at one of their own computers: rows and labels speak of computers (this one, the others, when each last
// connected) and of where things go, never of how a computer belongs to the profile.

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsTransfers.h"

static NSString *const SZFriendsYouID = @"you";
static const NSUInteger SZFriendsDeviceNameMaxBytes = 64;

@implementation SZFriendsDeviceFacts
@end

@implementation SZFriendsDeviceFileFacts
@end

@implementation SZFriendsDevicesFacts

- (instancetype)init {
    if ((self = [super init])) {
        _computers = @[];
        _youItemsEverywhere = [NSSet set];
        _youCopying = @{};
        _files = @{};
        _now = [NSDate dateWithTimeIntervalSince1970:0];
    }
    return self;
}

@end

@implementation SZFriendsStrings (SZFriendsDevices)

- (nullable NSString *)devicesMessageForErrorCode:(NSString *)code reason:(NSString *)reason {
    NSDictionary<NSString *, NSString *> *keys = @{
        @"not_found/device" : @"error.not_found.device",
        @"not_found/fetch" : @"error.not_found.fetch",
        @"not_found/again" : @"error.not_found.again",
        @"name_invalid/empty" : @"error.name_invalid.device.empty",
        @"name_invalid/invalid" : @"error.name_invalid.device",
        @"not_allowed/device_removed" : @"error.not_allowed.device_removed",
    };
    NSString *key = keys[[NSString stringWithFormat:@"%@/%@", code, reason]];
    return key ? [self text:key] : nil;
}

@end

@implementation SZFriendsSnapshotBuilder (SZFriendsDevices)

- (BOOL)deletesOnEveryComputer {
    return self.devices.computers.count >= 2;
}

#pragma mark - Your computers

- (NSDictionary<NSString *, id> *)rowForDevice:(SZFriendsDeviceFacts *)device
                                       removed:(BOOL)removed
                                           now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    NSString *last, *spoken, *state = @"not_connected", *spokenKey = @"devices.accessibility.seen";
    if (device.thisComputer) {
        last = [s text:@"devices.last.this_computer"];
        state = @"connected";
        spokenKey = @"devices.accessibility.this_computer";
    } else if (device.connected) {
        last = [s text:@"devices.last.now"];
        state = @"connected";
        spokenKey = @"devices.accessibility.now";
    } else if (device.lastSeenAt == nil) {
        last = [s text:@"devices.last.never"];
        state = @"never_connected";
        spokenKey = @"devices.accessibility.never";
    } else {
        NSTimeInterval ago = MAX(0, [now timeIntervalSinceDate:device.lastSeenAt]);
        NSInteger minutes = MAX((NSInteger)1, (NSInteger)floor(ago / 60));
        if (ago < 3600) {
            last = [s text:@"devices.last.minutes" count:minutes values:nil];
            spoken = [s text:@"devices.last.minutes.spoken" count:minutes values:nil];
        } else {
            last = [s timeLabelForDate:device.lastSeenAt now:now];
            spoken = [s timeAccessibilityLabelForDate:device.lastSeenAt now:now];
        }
    }
    NSDictionary *values = @{@"name" : device.name, @"system" : device.system, @"last" : last, @"device" : device.name};
    NSMutableDictionary *said = [values mutableCopy];
    said[@"last"] = spoken ?: last;
    id remove = [NSNull null];
    if (!device.thisComputer && !removed) {
        NSMutableDictionary *action = [self action:@"revoke_device" label:[s text:@"devices.remove"]
                                             style:@"destructive"];
        action[@"device_id"] = device.deviceID;
        action[@"confirm"] = [self confirmWithTitle:@"devices.remove.confirm.title"
                                               body:@"devices.remove.confirm.body"
                                       confirmLabel:@"devices.remove.confirm.button"
                                             values:values
                                        destructive:YES];
        remove = action;
    }
    id rename = device.thisComputer && !removed ? @{
        @"label" : [s text:@"devices.rename.label"],
        @"placeholder" : [s text:@"devices.rename.placeholder"],
        @"button_label" : [s text:@"devices.rename.button"],
        @"max_bytes" : @(SZFriendsDeviceNameMaxBytes)
    } : [NSNull null];
    return @{
        @"device_id" : device.deviceID,
        @"name" : device.name,
        @"system" : device.system,
        @"last_connected" : last,
        @"detail" : [s text:@"devices.detail" values:values],
        @"this_computer" : SZFriendsBool(device.thisComputer),
        @"state" : state,
        @"accessibility_label" : [s text:spokenKey values:said],
        @"rename" : rename,
        @"remove" : remove
    };
}

- (NSDictionary<NSString *, id> *)devicesSectionWithFacts:(SZFriendsDevicesFacts *)facts now:(NSDate *)now {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (SZFriendsDeviceFacts *device in facts.computers) {
        [rows addObject:[self rowForDevice:device removed:facts.removed now:now]];
    }
    return @{@"title" : [self.strings text:@"devices.title"], @"note" : [self.strings text:@"devices.note"],
             @"rows" : rows};
}

#pragma mark - The list

- (NSDictionary<NSString *, id> *)removedBlock {
    NSMutableDictionary *action = [self action:@"reset_friends" label:[self.strings text:@"device_removed.action"]
                                         style:@"primary"];
    action[@"confirm"] = [self confirmWithTitle:@"device_removed.confirm.title"
                                           body:@"device_removed.confirm.body"
                                   confirmLabel:@"device_removed.confirm.button"
                                         values:nil
                                    destructive:YES];
    return @{@"title" : [self.strings text:@"device_removed.title"],
             @"body" : [self.strings text:@"device_removed.body"], @"action" : action};
}

- (id)dropRefusalOnRemovedComputer {
    BOOL drops = [self.audience.capabilities containsObject:@"drop.files"];
    return drops ? [self.strings text:@"device_removed.drop_refusal"] : [NSNull null];
}

// The person's own avatar, exactly as the list's footer draws it.
- (NSDictionary<NSString *, id> *)ownAvatarForYou:(SZFriendsPersonFacts *)you {
    NSString *name = [you.name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [self avatarForPicture:you.picture seed:you.friendsID ?: SZFriendsYouID
                      displayName:name.length ? name : (you.friendsID ?: @"")];
}

// What the You row says of its newest item: the message's words or the file's name.
- (nullable NSString *)youPreviewText:(nullable SZFriendsItemFacts *)item {
    if (item.kind == SZFriendsItemFactsKindTransfer) return item.fileName.length ? item.fileName : nil;
    if (item.kind != SZFriendsItemFactsKindMessage) return nil;
    NSString *text = [item.text stringByReplacingOccurrencesOfString:@"￼" withString:@""];
    NSArray *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    text = [[lines componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

- (NSDictionary<NSString *, id> *)youRowWithNow:(NSDate *)now mentions:(BOOL)mentions {
    SZFriendsStrings *s = self.strings;
    SZFriendsDevicesFacts *facts = self.devices;
    SZFriendsPersonFacts *you = facts.you;
    NSString *preview = [self youPreviewText:facts.youPreview];
    NSString *time = [s timeLabelForDate:you.lastInteractionAt now:now];
    NSString *spoken = preview ? [s text:@"you.row.accessibility"
                                   values:@{@"preview" : preview,
                                            @"time" : [s timeAccessibilityLabelForDate:you.lastInteractionAt now:now]}]
                               : [s text:@"you.row.accessibility.empty"];
    BOOL drops = [self.audience.capabilities containsObject:@"drop.files"];
    NSMutableDictionary *row = [@{
        @"conversation_id" : SZFriendsYouID,
        @"kind" : @"you",
        @"avatar" : [self ownAvatarForYou:you],
        @"title" : [s text:@"you.title"],
        @"subtitle" : preview ?: [s text:@"you.subtitle.empty"],
        @"time_label" : time,
        @"route" : [self routeForKind:SZFriendsRouteKindNone method:SZFriendsRouteMethodNone],
        @"unread" : SZFriendsBool(you.unreadCount > 0),
        @"waiting" : [NSNull null],
        @"blocked" : @NO,
        @"id_confirmed" : @NO,
        @"id_confirmed_label" : [NSNull null],
        @"style" : @"normal",
        @"drop_label" : drops && !facts.removed ? [s text:@"you.drop_label"] : [NSNull null],
        @"drop_refusal" : facts.removed ? [self dropRefusalOnRemovedComputer] : [NSNull null],
        @"accessibility_label" : spoken,
        @"actions" : @[]
    } mutableCopy];
    if (mentions) row[@"mentionable"] = @NO; // nobody mentions themselves
    if ([self.audience.capabilities containsObject:@"list.menu"]) row[@"menu"] = @[]; // nothing to remove
    return [self row:row foundWithMethods:nil]; // this computer is found nowhere
}

- (NSDictionary<NSString *, id> *)listWithDevices:(NSDictionary<NSString *, id> *)list
                                           people:(NSArray<SZFriendsPersonFacts *> *)people
                                            query:(NSString *)query
                                              now:(NSDate *)now {
    SZFriendsDevicesFacts *facts = self.devices;
    if (facts == nil) return list;
    NSMutableDictionary *result = [list mutableCopy];
    result[@"state"] = facts.removed ? @"device_removed" : @"normal";
    result[@"removed"] = facts.removed ? [self removedBlock] : [NSNull null];
    if (facts.removed || result[@"join_requests"] == nil) result[@"join_requests"] = @[];
    NSMutableDictionary<NSString *, NSDate *> *latest = [NSMutableDictionary dictionary];
    for (SZFriendsPersonFacts *person in people) latest[person.conversationID] = person.lastInteractionAt;
    NSMutableArray *rows = [NSMutableArray array];
    BOOL mentions = NO;
    for (NSDictionary *base in list[@"rows"]) {
        NSMutableDictionary *row = [base mutableCopy];
        row[@"kind"] = @"person";
        mentions = mentions || row[@"mentionable"] != nil;
        if (facts.removed) {
            row[@"drop_label"] = [NSNull null];
            row[@"drop_refusal"] = [self dropRefusalOnRemovedComputer];
        }
        [rows addObject:row];
    }
    SZFriendsPersonFacts *you = facts.you;
    NSString *youTitle = [self.strings text:@"you.title"];
    if (you != nil && [self name:youTitle friendsID:nil matchesQuery:query ?: @""]) {
        // Among the others by latest interaction, as every row is.
        NSUInteger index = 0;
        while (index < rows.count && [latest[rows[index][@"conversation_id"]] compare:you.lastInteractionAt] ==
                                         NSOrderedDescending) {
            index++;
        }
        [rows insertObject:[self youRowWithNow:now mentions:mentions] atIndex:index];
        result[@"empty"] = [NSNull null];
    }
    result[@"rows"] = rows;
    if ([result[@"name_prompt"] isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *prompt = [result[@"name_prompt"] mutableCopy];
        prompt[@"join_label"] = facts.joinOffered && !facts.removed ? [self.strings text:@"name_prompt.join"]
                                                                    : [NSNull null];
        result[@"name_prompt"] = prompt;
    }
    return result;
}

#pragma mark - Conversations

- (BOOL)isYou:(SZFriendsPersonFacts *)person {
    return [person.conversationID isEqualToString:SZFriendsYouID];
}

- (NSDictionary<NSString *, id> *)conversationWithDevices:(NSDictionary<NSString *, id> *)conversation
                                                   person:(SZFriendsPersonFacts *)person {
    SZFriendsDevicesFacts *facts = self.devices;
    if (facts == nil) return conversation;
    SZFriendsStrings *s = self.strings;
    NSMutableDictionary *result = [conversation mutableCopy];
    NSMutableDictionary *composer = [conversation[@"composer"] mutableCopy];
    if ([self isYou:person]) {
        result[@"header"] = @{
            @"title" : [s text:@"you.title"],
            @"subtitle" : [s text:@"you.header.subtitle"],
            @"route" : [self routeForKind:SZFriendsRouteKindNone method:SZFriendsRouteMethodNone],
            @"avatar" : [self ownAvatarForYou:person],
            @"details_available" : @NO,
            @"accessibility_label" : [s text:@"you.header.accessibility"]
        };
        result[@"request"] = [NSNull null];
        composer[@"placeholder"] = [s text:@"you.composer.placeholder"];
        // The note shows only while something here has not reached every computer yet.
        BOOL waiting = NO;
        for (NSDictionary *item in conversation[@"items"]) {
            if (![item[@"direction"] isEqual:@"out"]) continue;
            id status = item[@"status"];
            BOOL message = [status isKindOfClass:NSDictionary.class] && [status[@"state"] isEqual:@"queued"];
            BOOL file = [item[@"kind"] isEqual:@"transfer"] &&
                        ([item[@"state"] isEqual:@"queued"] || [item[@"state"] isEqual:@"sending"]);
            waiting = waiting || message || file;
        }
        composer[@"note"] = waiting ? [s text:@"you.composer.note.waiting"
                                         values:@{@"apps" : [s text:@"apps.with_friends"]}]
                                    : [NSNull null];
    }
    if (facts.removed) {
        // Chats stay readable; nothing is sent from here any more.
        composer[@"visible"] = @NO;
        composer[@"enabled"] = @NO;
        composer[@"accepts_drops"] = @NO;
    }
    result[@"composer"] = composer;
    return result;
}

- (nullable NSDictionary<NSString *, id> *)youStatusForMessage:(SZFriendsItemFacts *)item
                                                        person:(SZFriendsPersonFacts *)person {
    if (self.devices == nil || ![self isYou:person] || !item.outgoing || item.kind != SZFriendsItemFactsKindMessage) {
        return nil;
    }
    BOOL everywhere = [self.devices.youItemsEverywhere containsObject:item.itemID];
    NSString *state = everywhere ? @"delivered" : @"queued";
    return @{@"state" : state, @"label" : [self.strings text:[@"you.status." stringByAppendingString:state]]};
}

#pragma mark - Files

- (NSDictionary<NSString *, id> *)progressWithFraction:(double)fraction {
    long percent = MIN(100L, MAX(0L, (long)floor(fraction * 100.0)));
    return @{
        @"fraction" : @(percent / 100.0),
        @"determinate" : @YES,
        @"accessibility_label" : [self.strings text:@"transfer.progress.copying"
                                             values:@{@"percent" : [NSString stringWithFormat:@"%ld", percent]}]
    };
}

- (NSDictionary<NSString *, id> *)transferWithDevices:(NSDictionary<NSString *, id> *)transfer
                                                 item:(SZFriendsItemFacts *)item
                                               person:(SZFriendsPersonFacts *)person {
    SZFriendsDevicesFacts *facts = self.devices;
    if (facts == nil) return transfer;
    SZFriendsStrings *s = self.strings;
    NSString *transferID = transfer[@"transfer_id"];
    SZFriendsDeviceFileFacts *file = transferID ? facts.files[transferID] : nil;
    BOOL you = [self isYou:person] && item.outgoing;
    if (file == nil && !you) return transfer;
    NSDictionary *fileInfo = transfer[@"file"];
    NSMutableDictionary<NSString *, NSString *> *values = [@{
        @"sender" : item.outgoing ? @"" : [self titleForPerson:person],
        @"file" : fileInfo[@"name"] ?: @"",
        @"kind" : fileInfo[@"kind_label"] ?: @"",
        @"size" : fileInfo[@"size_label"] ?: @"",
        @"device" : file.deviceName ?: @"",
        @"apps" : [s text:@"apps.with_friends"]
    } mutableCopy];
    NSMutableDictionary *result = [transfer mutableCopy];
    NSString *state, *status;
    NSString *spokenKey = item.outgoing ? @"devices.spoken.transfer.out" : @"devices.spoken.transfer.in";
    id progress = [NSNull null];
    NSArray *actions = @[ [self action:@"cancel_transfer" label:[s text:@"static.cancel"] style:@"link"] ];
    double fraction = file ? file.fraction : [facts.youCopying[transferID] doubleValue];
    long percent = MIN(100L, MAX(0L, (long)floor(fraction * 100.0)));
    values[@"percent"] = [NSString stringWithFormat:@"%ld", percent];
    if (file != nil && !file.fetching) {
        state = @"on_device";
        status = [s text:@"transfer.status.on_device" values:values];
        actions = @[ [self action:@"fetch_from_device" label:[s text:@"transfer.action.fetch"] style:@"primary"] ];
    } else if (file != nil && file.holderConnected) {
        state = @"fetching";
        status = [s text:@"transfer.status.fetching" values:values];
        progress = [self progressWithFraction:fraction];
        spokenKey = @"devices.spoken.transfer.fetching";
    } else if (file != nil) {
        state = @"fetching";
        status = [s text:s.reachesOnline ? @"transfer.status.fetch_waiting.online" : @"transfer.status.fetch_waiting"
                  values:values];
    } else if ([transfer[@"state"] isEqual:@"failed"] || [transfer[@"state"] isEqual:@"cancelled"]) {
        return transfer; // a You file that will not go keeps its own words
    } else if (facts.youCopying[transferID] != nil) {
        state = @"sending";
        status = [s text:@"you.transfer.status.sending" values:values];
        progress = [self progressWithFraction:fraction];
        spokenKey = @"you.transfer.spoken.sending";
    } else if ([facts.youItemsEverywhere containsObject:item.itemID]) {
        state = @"delivered";
        status = [s text:@"you.transfer.status.delivered"];
        // Nothing left to stop: Open and Show where the copy is here, else nothing.
        actions = item.localPath.length ? transfer[@"actions"] : @[];
    } else {
        state = @"queued";
        status = [s text:@"you.transfer.status.queued"];
        spokenKey = @"you.transfer.spoken.queued";
    }
    // Said inside a sentence, except where the template makes it a sentence of its own; the template ends it.
    NSString *said = [spokenKey isEqualToString:@"you.transfer.spoken.queued"] ? status : [s spokenFragment:status];
    values[@"status"] = [said hasSuffix:@"."] ? [said substringToIndex:said.length - 1] : said;
    result[@"state"] = state;
    result[@"status_label"] = status;
    result[@"progress"] = progress;
    result[@"route_note"] = [NSNull null];
    result[@"actions"] = actions;
    result[@"accessibility_label"] = [s text:spokenKey values:values];
    return result;
}

@end
