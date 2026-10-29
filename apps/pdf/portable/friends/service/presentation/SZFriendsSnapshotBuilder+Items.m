// Shenzhen Friends snapshot builder: conversation items (messages, transfers, events, day separators). The list
// row's preview of the latest one is in +Previews.
//
// Status words are about what happens to the person's message ("Sends when Priya is nearby"), and "Delivered"
// means it reached their Mac, never that it was read (brief § Interface). Transfer estimates appear only on slow
// routes, where the person may prefer to wait for a faster one.

#import "service/presentation/SZFriendsPresentationDevices.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/presentation/SZFriendsMentions.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

// A message shows its time only this long after the one before it: a burst of messages reads as one exchange, and
// each time line it drops leaves room for another message in a 640 pt dropdown (UX critique, density).
static const NSTimeInterval SZFriendsMessageTimeGap = 5 * 60;

static NSString *TransferStateName(NSInteger state) {
    switch (state) {
    case SZFriendsTransferStateQueued: return @"queued";
    case SZFriendsTransferStateOffered: return @"offered";
    case SZFriendsTransferStateWaitingForYou: return @"waiting_for_you";
    case SZFriendsTransferStateSending: return @"sending";
    case SZFriendsTransferStateReceiving: return @"receiving";
    case SZFriendsTransferStateDelivered: return @"delivered";
    case SZFriendsTransferStateReceived: return @"received";
    case SZFriendsTransferStateDeclined: return @"declined";
    case SZFriendsTransferStateCancelled: return @"cancelled";
    default: return @"failed";
    }
}

static NSString *OutboxStateName(NSInteger state) {
    switch (state) {
    case SZFriendsOutboxStateQueued: return @"queued";
    case SZFriendsOutboxStateConnecting: return @"connecting";
    case SZFriendsOutboxStateSending: return @"sending";
    case SZFriendsOutboxStateDelivered: return @"delivered";
    default: return @"failed";
    }
}

// A status inserted into a spoken template that ends the sentence itself ("{status}."): one period, not two, and none
// after an ellipsis ("Connecting to Priya…").
static NSString *WithoutFinalPeriod(NSString *text) {
    return [text hasSuffix:@"."] || [text hasSuffix:@"\u2026"] ? [text substringToIndex:text.length - 1] : text;
}

// A status said in the middle of a sentence ("You, 17:58, connecting to Priya: ..."): the ellipsis would be a pause.
static NSString *WithoutEllipsis(NSString *text) {
    return [text hasSuffix:@"\u2026"] ? [text substringToIndex:text.length - 1] : text;
}

static BOOL EndsSentence(NSString *text) {
    if (text.length == 0) return YES;
    unichar last = [text characterAtIndex:text.length - 1];
    return last == '.' || last == '!' || last == '?' || last == 0x2026 || last == 0x3002 || last == 0xFF01 ||
           last == 0xFF1F;
}

@implementation SZFriendsSnapshotBuilder (SZFriendsItems)

#pragma mark - Items

- (NSArray *)segmentsForText:(NSString *)text {
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeLink error:NULL];
    __block NSUInteger cursor = 0;
    // Links become segments the person can open; Friends never fetches a preview of them (brief § Product).
    [detector enumerateMatchesInString:text
                               options:0
                                 range:NSMakeRange(0, text.length)
                            usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
                              (void)flags;
                              (void)stop;
                              NSString *scheme = match.URL.scheme.lowercaseString;
                              if (!scheme || ![@[ @"http", @"https", @"mailto" ] containsObject:scheme])
                                  return;
                              NSRange before = NSMakeRange(cursor, match.range.location - cursor);
                              if (before.length) [segments addObject:@{@"text" : [text substringWithRange:before]}];
                              [segments addObject:@{
                                  @"text" : [text substringWithRange:match.range],
                                  @"url" : match.URL.absoluteString
                              }];
                              cursor = NSMaxRange(match.range);
                            }];
    if (cursor < text.length || segments.count == 0) [segments addObject:@{@"text" : [text substringFromIndex:cursor]}];
    return segments;
}

// "Via the assistant" on what this person's assistant sent, "Via Kenji's assistant" on what the friend's did; nil
// when nobody's assistant was involved (PROTOCOL.md § Views, conversation).
- (nullable NSString *)assistantLabelForItem:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person {
    if (!item.viaAssistant) return nil;
    if (item.outgoing) return [self.strings text:@"item.assistant.out"];
    return [self.strings text:@"item.assistant.in" values:@{@"first" : [self firstNameForPerson:person]}];
}

// An outgoing message's status object ({state, label}), the same in its conversation and in message_status; nil for
// an incoming message, and for one the store has no delivery record of, where no word would be true. A cancelled
// message has no delivery record any more, but the person withdrew it, so that is what it says.
- (nullable NSDictionary *)statusForMessage:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person {
    if (!item.outgoing || item.kind != SZFriendsItemFactsKindMessage) return nil;
    NSDictionary *you = [self youStatusForMessage:item person:person]; // You: on every computer yet? (+Devices)
    if (you) return you;
    if (item.cancelled) return @{@"state" : @"cancelled", @"label" : [self.strings text:@"message.status.cancelled"]};
    if (item.outboxState < 0) return nil;
    NSString *state = OutboxStateName(item.outboxState);
    NSString *key = [@"message.status." stringByAppendingString:state];
    if (item.outboxState == SZFriendsOutboxStateFailed)
        key = [self key:key forFailure:item.failureReason person:person];
    if (item.outboxState == SZFriendsOutboxStateQueued) {
        // Waiting for the friend: online too once the helper reaches friends online, and connecting while it tries.
        key = [self waitingKeyInFamily:@"message.status" person:person];
        if ([key hasSuffix:@".connecting"]) state = @"connecting";
    }
    NSString *label = [self.strings text:key values:@{@"first" : [self firstNameForPerson:person]}];
    return @{@"state" : state, @"label" : label};
}

- (NSDictionary<NSString *, id> *)buildMessageStatusWithMessages:(NSArray<SZFriendsItemFacts *> *)messages
                                                          people:(NSDictionary<NSString *, SZFriendsPersonFacts *> *)
                                                                     people {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray arrayWithCapacity:messages.count];
    for (SZFriendsItemFacts *message in messages) {
        SZFriendsPersonFacts *person = message.conversationID ? people[message.conversationID] : nil;
        NSDictionary *status = person ? [self statusForMessage:message person:person] : nil;
        if (status) [rows addObject:@{@"message_id" : message.itemID, @"status" : status}];
    }
    return @{@"messages" : rows};
}

// `showsTime`: the message carries its time line (SZFriendsMessageTimeGap); its spoken label always says the time.
- (NSDictionary *)messageItem:(SZFriendsItemFacts *)item
                       person:(SZFriendsPersonFacts *)person
                    showsTime:(BOOL)showsTime {
    SZFriendsStrings *s = self.strings;
    // Mentions resolved for this reader (PROTOCOL.md § Mentions); spoken labels read the plain words, "@Mei Lin".
    SZFriendsResolvedText *resolved = [self resolvedText:item.text ?: @""];
    NSString *text = resolved.plain;
    NSString *clock = [s clockLabelForDate:item.sentAt];
    NSString *assistant = [self assistantLabelForItem:item person:person];
    // Every spoken template names the time right after who sent it, so the assistant is said there too:
    // "You, 09:14, via the assistant, delivered: ...".
    NSString *time = assistant ? [NSString stringWithFormat:@"%@, %@", clock, [s spokenFragment:assistant]] : clock;
    NSDictionary *status = [self statusForMessage:item person:person];
    NSMutableArray *actions = [NSMutableArray array];
    NSString *spoken;
    if (item.outgoing && !status) {
        // The store has no delivery record for it (SZFriendsPresentation.h): say nothing rather than guess.
        spoken = [s text:@"message.spoken.out_plain" values:@{@"time" : time, @"text" : text}];
    } else if (item.outgoing) {
        BOOL failed = !item.cancelled && item.outboxState == SZFriendsOutboxStateFailed;
        // Cancel only while nothing has left this Mac (cancel_message): once it is being written it may already be on
        // the friend's Mac, and offering Cancel then would promise what the helper cannot do. So too once it was
        // written to a session that dropped before the friend's Mac answered: queued again, but maybe already there.
        BOOL waiting = !item.cancelled && !item.outboxWritten &&
                       (item.outboxState == SZFriendsOutboxStateQueued ||
                        item.outboxState == SZFriendsOutboxStateConnecting);
        NSString *label = status[@"label"];
        if (failed && [self canRetryFailure:item.failureReason person:person])
            [actions addObject:[self action:@"retry_item" label:[s text:@"action.try_again"] style:@"link"]];
        if (waiting) [actions addObject:[self action:@"cancel_message" label:[s text:@"static.cancel"] style:@"link"]];
        // A short status reads inline ("delivered"); a sentence about when it will go, or that it never will, reads
        // after the message.
        BOOL sentence = item.cancelled || [status[@"state"] isEqualToString:@"queued"] ||
                        item.outboxState == SZFriendsOutboxStateFailed;
        if (sentence)
            spoken = [s text:@"message.spoken.out_sentence"
                      values:@{@"time" : time,
                               @"text" : EndsSentence(text) ? text : [text stringByAppendingString:@"."],
                               @"status" : WithoutFinalPeriod(label)}];
        else
            spoken = [s text:@"message.spoken.out"
                      values:@{@"time" : time, @"status" : [s spokenFragment:WithoutEllipsis(label)], @"text" : text}];
    } else {
        spoken = [s text:@"message.spoken.in" values:@{@"sender" : [self titleForPerson:person], @"time" : time,
                                                       @"text" : text}];
    }
    NSMutableDictionary *message = [@{
        @"kind" : @"message",
        @"item_id" : item.itemID,
        @"direction" : item.outgoing ? @"out" : @"in",
        @"text" : resolved.markdown,
        // People type Markdown; the host renders it (PROTOCOL.md § Views, conversation), and `segments` stays the
        // plain-text form for a host without a renderer.
        @"text_format" : @"markdown",
        @"segments" : resolved.segments,
        @"time_label" : showsTime ? clock : [NSNull null],
        @"status" : status ?: [NSNull null],
        @"assistant_label" : assistant ?: [NSNull null],
        @"actions" : actions,
        @"accessibility_label" : spoken
    } mutableCopy];
    // Only where a mention shows as a link: views match a click on one against `url`.
    if (resolved.mentions) message[@"mentions"] = resolved.mentions;
    return message;
}

// Open (for a format this app opens) and Show in Finder, for a file that is on this computer.
- (NSArray *)fileActionsForItem:(SZFriendsItemFacts *)item {
    SZFriendsStrings *s = self.strings;
    NSMutableArray *actions = [NSMutableArray array];
    NSString *extension = item.fileExtension.length ? item.fileExtension : item.fileName.pathExtension;
    extension = extension.lowercaseString;
    if ([self.audience.openFormats containsObject:extension]) {
        NSMutableDictionary *open = [self action:@"open_file" label:[s text:@"action.open"] style:@"link"];
        open[@"path"] = item.localPath;
        [actions addObject:open];
    }
    NSMutableDictionary *show = [self action:@"show_file"
                                       label:[s text:@"action.show_in" values:@{@"app" : self.audience.revealIn}]
                                       style:@"link"];
    show[@"path"] = item.localPath;
    [actions addObject:show];
    return actions;
}

// ADR 0019: the question shows only in views that declared transfers.boost, which know its two actions.
- (BOOL)asksBoost:(SZFriendsItemFacts *)item {
    return item.boostStage == 1 && [self.audience.capabilities containsObject:@"transfers.boost"];
}

// The Wi-Fi Direct boost's words for the transfer's note, or nil to keep the usual one (same keys as the Rust core).
- (nullable NSString *)boostNoteForItem:(SZFriendsItemFacts *)item first:(NSString *)first {
    SZFriendsStrings *s = self.strings;
    NSString *network = item.boostNetwork.length
                            ? [s text:@"transfer.boost.network" values:@{@"name" : item.boostNetwork}]
                            : [s text:@"transfer.boost.your_wifi"];
    NSMutableDictionary *values = [@{
        @"first" : first,
        @"device" : [s text:@"transfer.boost.device.computer"], // a computer, never "Mac", in shared words
        @"network" : network,
    } mutableCopy];
    switch (item.boostStage) {
    case 1:
        if (![self asksBoost:item]) return nil;
        values[@"slow"] = [s durationLabelForSeconds:item.boostBluetoothSeconds];
        values[@"fast"] = [s durationLabelForSeconds:item.boostDirectSeconds];
        return [s text:@"transfer.boost.ask" values:values];
    case 2: return [s text:@"transfer.boost.connecting" values:values];
    case 3:
        if (!item.boostLeavesWiFi) return [s text:@"transfer.boost.direct"];
        return [s text:item.boostOverEthernet ? @"transfer.boost.direct.ethernet" : @"transfer.boost.direct.away"
                values:values];
    case 4: return [s text:@"transfer.boost.rejoining" values:values];
    case 5:
        values[@"place"] = [s text:@"transfer.boost.place.menu"];
        return [s text:@"transfer.boost.rejoin_failed" values:values];
    default: return nil;
    }
}

- (NSArray *)actionsForTransfer:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    // A file this person sent from another of their computers, copied here: it is here to open, nothing to send.
    if (item.outgoing && item.localPath.length) return [self fileActionsForItem:item];
    NSMutableArray *actions = [NSMutableArray array];
    switch (item.transferState) {
    case SZFriendsTransferStateWaitingForYou:
        [actions addObject:[self action:@"accept_offer" label:[s text:@"action.accept"] style:@"primary"]];
        [actions addObject:[self action:@"decline_offer" label:[s text:@"action.decline"] style:@"secondary"]];
        break;
    case SZFriendsTransferStateQueued:
    case SZFriendsTransferStateOffered:
    case SZFriendsTransferStateSending:
    case SZFriendsTransferStateReceiving:
        if ([self asksBoost:item]) {
            [actions addObject:[self action:@"boost_transfer" label:[s text:@"transfer.boost.go"] style:@"primary"]];
            [actions addObject:[self action:@"skip_boost" label:[s text:@"transfer.boost.not_now"] style:@"secondary"]];
        }
        [actions addObject:[self action:@"cancel_transfer" label:[s text:@"static.cancel"] style:@"link"]];
        break;
    case SZFriendsTransferStateReceived:
        if (item.localPath.length) [actions addObjectsFromArray:[self fileActionsForItem:item]];
        break;
    case SZFriendsTransferStateFailed: {
        // An incoming file can be fetched again only when its bytes arrived damaged (ADR 0001: the download
        // starts over); for any other failure the sender has to offer it again.
        BOOL retry = item.outgoing || [item.failureReason isEqualToString:SZFriendsFailureDigestMismatch];
        if (retry && [self canRetryFailure:item.failureReason person:person])
            [actions addObject:[self action:@"retry_item" label:[s text:@"action.try_again"] style:@"link"]];
        break;
    }
    default: break;
    }
    // Someone who sent a file through a link and is not a friend: Add, as a mention of them would offer it.
    NSString *key = person.identityKey ? SZFriendsMentionKeyString(person.identityKey) : nil;
    if (person.linkContact && person.relation == SZFriendsPersonRelationRemoved && !item.outgoing && key &&
        person.friendsID.length) {
        NSDictionary *who = @{@"first" : [self firstNameForPerson:person]};
        NSMutableDictionary *add = [self action:@"add_from_mention" label:[s text:@"transfer.action.add" values:who]
                                          style:@"link"];
        add[@"friends_id"] = person.friendsID;
        add[@"identity_key"] = key;
        add[@"name"] = SZFriendsMentionName(person.name, person.friendsID);
        [actions addObject:add];
    }
    return actions;
}

// PROTOCOL.md transfer thumbnail: the PNG views load in place of the type icon, or null when there is none.
- (id)thumbnailForTransfer:(SZFriendsItemFacts *)item {
    if (item.thumbnailPath.length == 0 || item.thumbnailWidth == 0 || item.thumbnailHeight == 0) return [NSNull null];
    return @{
        @"path" : item.thumbnailPath,
        @"width" : @(item.thumbnailWidth),
        @"height" : @(item.thumbnailHeight),
        @"source" : item.thumbnailFromSender ? @"sender" : @"local"
    };
}

- (NSDictionary *)transferItem:(SZFriendsItemFacts *)item person:(SZFriendsPersonFacts *)person {
    SZFriendsStrings *s = self.strings;
    NSString *name = item.fileName ?: @"";
    NSString *kindLabel = [s kindLabelForFileName:name extension:item.fileExtension];
    NSString *size = [s sizeLabelForBytes:item.fileSize];
    NSInteger state = item.transferState;
    BOOL automatic = item.acceptedAutomatically && !item.outgoing;
    BOOL moving = state == SZFriendsTransferStateSending || state == SZFriendsTransferStateReceiving;
    BOOL waiting = state == SZFriendsTransferStateWaitingForYou || state == SZFriendsTransferStateOffered;
    uint64_t remaining = item.fileSize > item.bytesDone ? item.fileSize - item.bytesDone : 0;
    // Floor, so the bar and the percentage never claim 100% before the digest has been checked.
    long percent = item.fileSize ? (long)floor((double)item.bytesDone * 100.0 / (double)item.fileSize) : 0;
    percent = MIN(percent, 100L);
    BOOL timed = moving && item.bytesPerSecond > 0;
    // On the relay the time left never assumes more than the relay allows (SZFriendsStrings estimateBytesPerSecond).
    double rate = [s estimateBytesPerSecond:item.bytesPerSecond route:item.transferRoute];
    NSString *verb = state == SZFriendsTransferStateSending ? @"sending" : @"receiving";
    NSString *direction = item.outgoing ? @"out" : @"in";
    NSString *note = [self boostNoteForItem:item first:[self firstNameForPerson:person]];
    if (note == nil && (waiting || moving)) {
        note = [s transferEstimateForRemainingBytes:remaining bytesPerSecond:item.bytesPerSecond
                                              route:item.transferRoute];
    }
    NSString *noteSpoken = waiting ? [s transferEstimateAccessibilityForRemainingBytes:remaining
                                                                        bytesPerSecond:item.bytesPerSecond
                                                                                 route:item.transferRoute]
                                   : nil;
    NSMutableDictionary<NSString *, NSString *> *values = [@{
        @"first" : [self firstNameForPerson:person],
        @"sender" : [self titleForPerson:person],
        @"file" : name,
        @"kind" : kindLabel,
        @"size" : size,
        @"percent" : [NSString stringWithFormat:@"%ld", percent],
        @"auto" : automatic ? [@", " stringByAppendingString:[s text:@"transfer.auto"]] : @"",
        @"note" : noteSpoken ? [@", " stringByAppendingString:noteSpoken] : @"",
        @"left" : @"",
        @"extra" : @""
    } mutableCopy];
    if (timed) {
        values[@"duration"] = [s durationLabelForSeconds:remaining / rate];
        values[@"left"] = [@", " stringByAppendingString:
                                     [s text:@"transfer.left.spoken"
                                      values:@{@"duration" : [s durationAccessibilityLabelForSeconds:
                                                                    remaining / rate]}]];
    }

    NSString *statusKey = [@"transfer.status." stringByAppendingString:TransferStateName(state)];
    BOOL finishing = item.finishing && state == SZFriendsTransferStateReceiving;
    if (finishing) {
        statusKey = @"transfer.finishing";
    } else if (moving) {
        statusKey = [NSString stringWithFormat:@"transfer.status.%@%@", verb, timed ? @"_timed" : @""];
    } else if (state == SZFriendsTransferStateWaitingForYou && item.askedBecauseDiskLow) {
        statusKey = @"transfer.status.disk_low";
        values[@"extra"] = [@". " stringByAppendingString:[s text:@"transfer.disk_low.spoken"]];
    } else if (state == SZFriendsTransferStateQueued && item.outgoing) {
        statusKey = [self waitingKeyInFamily:@"transfer.status" person:person];
    } else if (state == SZFriendsTransferStateDeclined || state == SZFriendsTransferStateFailed) {
        statusKey = [NSString stringWithFormat:@"%@.%@", statusKey, direction];
    }
    BOOL failed = state == SZFriendsTransferStateFailed;
    if (failed) statusKey = [self key:statusKey forFailure:item.failureReason person:person];
    // A received file says which folder it is in; one the helper kept in its own folder stays "Received".
    NSString *folder = item.savedToDownloads ? [s text:@"settings.received.default"] : item.savedFolderName;
    BOOL saved = state == SZFriendsTransferStateReceived && !item.outgoing && item.localPath.length && folder.length;
    if (saved) {
        statusKey = @"transfer.status.received.saved";
        values[@"folder"] = folder;
    }
    NSString *status = [s text:statusKey values:values];
    values[@"status"] = WithoutFinalPeriod(status); // the spoken templates end the sentence themselves
    NSString *spokenKey = [NSString stringWithFormat:@"transfer.spoken.%@.%@", direction, TransferStateName(state)];
    if (failed) spokenKey = [self key:spokenKey forFailure:item.failureReason person:person];
    if (saved) spokenKey = @"transfer.spoken.in.received.saved";
    if (finishing) spokenKey = @"transfer.spoken.in.finishing";
    NSString *assistant = [self assistantLabelForItem:item person:person];
    // Every spoken template lists "{file}, {kind}, {size}", so the assistant is said right after the file's facts.
    NSMutableDictionary<NSString *, NSString *> *said = [values mutableCopy];
    if (assistant) said[@"size"] = [NSString stringWithFormat:@"%@, %@", size, [s spokenFragment:assistant]];
    NSString *spoken = [s text:spokenKey values:said];

    NSString *meta = [s text:@"transfer.meta" values:@{@"kind" : kindLabel, @"size" : size}];
    if (automatic)
        meta = [s text:@"preview.with_status" values:@{@"text" : meta, @"status" : [s text:@"transfer.auto"]}];
    id progress = [NSNull null];
    if (finishing)
        progress = @{
            @"fraction" : @1.0,
            @"determinate" : SZFriendsBool(YES),
            @"accessibility_label" : [s text:@"transfer.progress.finishing"]
        };
    else if (moving)
        progress = @{
            @"fraction" : @(percent / 100.0),
            @"determinate" : SZFriendsBool(item.fileSize > 0),
            @"accessibility_label" : [s text:[@"transfer.progress." stringByAppendingString:verb] values:values]
        };
    // Received here, or sent from another of this person's computers and copied here (only a copy has a path).
    BOOL here = item.localPath.length && (item.outgoing || state == SZFriendsTransferStateReceived);
    NSString *extension = item.fileExtension.length ? item.fileExtension.lowercaseString : nil;
    NSDictionary *transfer = @{
        @"kind" : @"transfer",
        @"item_id" : item.itemID,
        @"transfer_id" : item.transferID ?: item.itemID,
        @"direction" : direction,
        @"file" : @{
            @"name" : name,
            @"kind_label" : kindLabel,
            @"size_label" : size,
            @"size_bytes" : @(item.fileSize),
            @"path" : here ? item.localPath : [NSNull null],
            @"type_identifier" : item.fileTypeIdentifier.length ? item.fileTypeIdentifier : [NSNull null],
            @"extension" : extension ?: [NSNull null]
        },
        @"thumbnail" : [self thumbnailForTransfer:item],
        @"meta_label" : meta,
        @"state" : TransferStateName(state),
        @"status_label" : status,
        @"route_note" : note ?: [NSNull null],
        @"progress" : progress,
        @"actions" : [self actionsForTransfer:item person:person],
        @"assistant_label" : assistant ?: [NSNull null],
        @"time_label" : [s clockLabelForDate:item.sentAt],
        @"accessibility_label" : spoken
    };
    // A file on another of the person's computers, one copying to them (+Devices), or one moved or deleted (+Again).
    return [self transferWhereItIs:transfer item:item person:person];
}

- (NSArray<NSDictionary<NSString *, id> *> *)itemsForPerson:(SZFriendsPersonFacts *)person
                                                      items:(NSArray<SZFriendsItemFacts *> *)items
                                            highlightItemID:(NSString *)highlightItemID
                                                        now:(NSDate *)now {
    SZFriendsStrings *s = self.strings;
    // Display order is the sender's timestamp, then the id (ADR 0001), whatever order the store returned.
    NSArray<SZFriendsItemFacts *> *ordered =
        [items sortedArrayUsingComparator:^NSComparisonResult(SZFriendsItemFacts *a, SZFriendsItemFacts *b) {
      NSComparisonResult order = [a.sentAt compare:b.sentAt];
      return order != NSOrderedSame ? order : [a.itemID compare:b.itemID];
    }];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSDate *previous = nil, *previousMessage = nil;
    for (SZFriendsItemFacts *item in ordered) {
        NSMutableDictionary *entry;
        BOOL newDay = !previous || ![s date:item.sentAt isSameDayAs:previous];
        // The first message under a day separator always shows its time, even a minute after midnight.
        if (newDay) previousMessage = nil;
        if (item.kind == SZFriendsItemFactsKindMessage) {
            BOOL showsTime = !previousMessage ||
                             fabs([item.sentAt timeIntervalSinceDate:previousMessage]) >= SZFriendsMessageTimeGap;
            entry = [[self messageItem:item person:person showsTime:showsTime] mutableCopy];
            previousMessage = item.sentAt;
        } else if (item.kind == SZFriendsItemFactsKindTransfer) {
            entry = [[self transferItem:item person:person] mutableCopy];
        } else {
            NSString *text = [self eventTextForItem:item person:person];
            if (!text) continue;
            entry = [@{
                @"kind" : @"event",
                @"item_id" : item.itemID,
                @"text" : text,
                @"time_label" : [s clockLabelForDate:item.sentAt],
                @"accessibility_label" :
                    [s text:@"event.spoken"
                     values:@{@"text" : text, @"moment" : [s momentAccessibilityPhraseForDate:item.sentAt now:now]}]
            } mutableCopy];
        }
        if (newDay) {
            NSString *day = [s dayLabelForDate:item.sentAt now:now];
            [result addObject:@{
                @"kind" : @"day",
                @"item_id" : [s dayItemIDForDate:item.sentAt],
                @"label" : day,
                @"highlighted" : @NO,
                @"accessibility_label" : [s dayAccessibilityLabelForDate:item.sentAt now:now]
            }];
        }
        previous = item.sentAt;
        entry[@"highlighted"] = SZFriendsBool(highlightItemID && [item.itemID isEqualToString:highlightItemID]);
        [result addObject:entry];
    }
    return result;
}

@end
