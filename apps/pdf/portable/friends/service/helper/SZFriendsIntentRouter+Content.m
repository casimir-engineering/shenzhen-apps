// Intents about content: messages, files and their transfers, retries, local search, deleting and resetting.

#import "service/helper/SZFriendsIntentRouter.h"

#import <sodium.h>

#import "service/helper/SZFriendsHostCheckIn.h"
#import "service/helper/nearby/SZFriendsNearbyDevices.h"

// PROTOCOL.md § Limits.
static const NSUInteger SZFriendsMessageBytesMax = 32768;
static const NSUInteger SZFriendsFilesPerSendMax = 100;
static const NSUInteger SZFriendsAttachmentsMax = 20;
static const NSUInteger SZFriendsSearchLimitDefault = 20;
static const NSUInteger SZFriendsSearchLimitMax = 50;

@implementation SZFriendsIntentRouter (Content)

#pragma mark - Sending

// The client token makes Send safe to retry after a reconnect (PROTOCOL.md § Intents, Idempotency).
- (nullable NSString *)clientTokenIn:(NSDictionary *)intent reply:(SZFriendsIntentReply)reply
                          connection:(SZFriendsIPCConnection *)connection {
    NSString *token = intent[@"client_token"];
    if (!SZFriendsJSONIsString(token) || token.length < 16 || token.length > 64) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"client_token"} connection:connection];
        return nil;
    }
    return token;
}

// `via_assistant` (PROTOCOL.md § Intents, Via the assistant): NO when absent. Only a client whose app has an
// assistant at all (it declared assistant.chats or assistant.drafts) may say its assistant wrote something, so no
// other app can put "Via the assistant" on what a person typed. Returns NO after replying.
- (BOOL)viaAssistantIn:(NSDictionary *)intent value:(BOOL *)value reply:(SZFriendsIntentReply)reply
            connection:(SZFriendsIPCConnection *)connection {
    id flag = intent[@"via_assistant"];
    *value = NO;
    if (flag == nil || flag == [NSNull null]) return YES;
    if (!SZFriendsJSONIsBool(flag)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"via_assistant"} connection:connection];
        return NO;
    }
    NSSet<NSString *> *capabilities = connection.client.capabilities;
    if ([flag boolValue] && ![capabilities containsObject:@"assistant.chats"] &&
        ![capabilities containsObject:@"assistant.drafts"]) {
        [self fail:reply code:@"not_allowed" details:@{@"field" : @"via_assistant"} connection:connection];
        return NO;
    }
    *value = [flag boolValue];
    return YES;
}

- (BOOL)checkCanSendTo:(SZFriendsPersonRecord *)person reply:(SZFriendsIntentReply)reply
            connection:(SZFriendsIPCConnection *)connection {
    if (person.relation == SZFriendsRelationFriend) return YES;
    NSString *code = person.relation == SZFriendsRelationBlocked ? @"blocked" : @"not_friends";
    [self fail:reply code:code details:nil connection:connection];
    return NO;
}

// Snapshots every file before offering any: one bad file sends none (PROTOCOL.md § Intents, Files). Returns the
// staged transfers, or nil after replying. The transfer area checks existence, folders, revisions and space; its
// error codes are the protocol's (SZFriendsStoreProtocolErrorCode).
- (nullable NSArray<SZFriendsTransferRecord *> *)stageFiles:(id)files
                                                      field:(NSString *)field
                                                        max:(NSUInteger)max
                                             conversationID:(NSString *)conversationID
                                                      reply:(SZFriendsIntentReply)reply
                                                 connection:(SZFriendsIPCConnection *)connection {
    if (![files isKindOfClass:[NSArray class]]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : field} connection:connection];
        return nil;
    }
    if ([files count] > max) {
        [self fail:reply code:@"too_many_files" details:@{@"max" : @(max)} connection:connection];
        return nil;
    }
    NSMutableArray<NSDictionary *> *checked = [NSMutableArray array];
    for (NSUInteger i = 0; i < [files count]; i++) {
        NSDictionary *file = files[i];
        NSString *path = [file isKindOfClass:[NSDictionary class]] ? file[@"path"] : nil;
        id name = [file isKindOfClass:[NSDictionary class]] ? file[@"display_name"] : nil;
        SZFriendsRevision *revision = nil;
        if (!SZFriendsJSONIsString(path) || ![path hasPrefix:@"/"] || (name != nil && !SZFriendsJSONIsString(name)) ||
            ![self parseRevision:file[@"revision"] into:&revision]) {
            NSString *where = [NSString stringWithFormat:@"%@[%lu]", field, (unsigned long)i];
            [self fail:reply code:@"invalid_field" details:@{@"field" : where} connection:connection];
            return nil;
        }
        [checked addObject:@{@"path" : path, @"name" : name ?: [NSNull null], @"revision" : revision ?: [NSNull null]}];
    }
    NSMutableArray<SZFriendsTransferRecord *> *staged = [NSMutableArray array];
    for (NSDictionary *file in checked) {
        NSError *error = nil;
        id name = file[@"name"], revision = file[@"revision"];
        SZFriendsTransferRecord *record =
            [self.services.transfers stageOutgoingFileAtPath:file[@"path"]
                                                 displayName:name == [NSNull null] ? nil : name
                                                    revision:revision == [NSNull null] ? nil : revision
                                              conversationID:conversationID
                                                       error:&error];
        if (record == nil) {
            for (SZFriendsTransferRecord *done in staged) {
                [self.services.transfers discardStagedTransfer:done.transferID error:NULL];
            }
            [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:@{@"path" : file[@"path"]}
                connection:connection];
            return nil;
        }
        [staged addObject:record];
    }
    return staged;
}

- (BOOL)parseRevision:(id)object into:(SZFriendsRevision *_Nullable *_Nonnull)revision {
    *revision = nil;
    if (object == nil || object == [NSNull null]) return YES;
    if (![object isKindOfClass:[NSDictionary class]]) return NO;
    NSString *source = object[@"source"], *document = object[@"document_id"], *revisionID = object[@"revision_id"];
    id size = object[@"size"], label = object[@"label"], sha = object[@"sha256"];
    if (!SZFriendsJSONIsString(source) || !SZFriendsJSONIsString(document) || !SZFriendsJSONIsString(revisionID) ||
        !SZFriendsJSONIsInteger(size) || [size longLongValue] < 0) {
        return NO;
    }
    SZFriendsRevision *parsed = [[SZFriendsRevision alloc] init];
    parsed.source = source;
    parsed.documentID = document;
    parsed.revisionID = revisionID;
    parsed.size = [size unsignedLongLongValue];
    if (SZFriendsJSONIsString(label)) parsed.label = label;
    if (SZFriendsJSONIsString(sha)) {
        // Exactly 64 hex digits: no prefix, separators or whitespace.
        const char *hex = [sha UTF8String];
        NSMutableData *digest = [NSMutableData dataWithLength:32];
        size_t length = 0;
        const char *end = NULL;
        if (strlen(hex) != 64 || sodium_hex2bin(digest.mutableBytes, 32, hex, 64, NULL, &length, &end) != 0 ||
            length != 32 || end != hex + 64) {
            return NO;
        }
        parsed.sha256 = digest;
    } else if (sha != nil && sha != [NSNull null]) {
        return NO;
    }
    *revision = parsed;
    return YES;
}

// One offer per file: each transfer's history item and the outbox entry that delivers it, committed together.
// Both carry the transfer id, which is how the store joins an item to its delivery state and how Try again finds
// the entry (SZFriendsOutbox.h, Offer).
- (NSArray<NSString *> *)offerTransfers:(NSArray<SZFriendsTransferRecord *> *)transfers
                         conversationID:(NSString *)conversationID
                            clientToken:(nullable NSString *)token
                           viaAssistant:(BOOL)viaAssistant {
    NSMutableArray *identifiers = [NSMutableArray array];
    for (SZFriendsTransferRecord *transfer in transfers) {
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.viaAssistant = viaAssistant;
        item.itemID = transfer.transferID;
        item.conversationID = conversationID;
        item.kind = SZFriendsItemKindTransfer;
        item.direction = SZFriendsDirectionOutgoing;
        item.sentAt = [NSDate date];
        item.receivedAt = item.sentAt;
        item.transferID = transfer.transferID;
        [self enqueueKind:SZFriendsOutboxKindOffer conversationID:conversationID item:item clientToken:token];
        [identifiers addObject:transfer.transferID];
    }
    // The offers are queued already; previews are made off this queue and follow them, never holding them back.
    [self.services.nearby makeThumbnailsForTransfers:identifiers];
    return identifiers;
}

// What an earlier send under this client token produced, for a retry after a reconnect; nil when there was none.
- (nullable NSDictionary *)earlierResultForToken:(NSString *)token includeMessage:(BOOL)includeMessage {
    NSArray<SZFriendsOutboxEntry *> *entries = [self.services.outbox entriesWithClientToken:token];
    if (entries.count == 0) return nil;
    NSMutableArray *transferIDs = [NSMutableArray array];
    NSString *messageID = nil;
    for (SZFriendsOutboxEntry *entry in entries) {
        if (entry.kind == SZFriendsOutboxKindOffer && entry.itemID != nil) [transferIDs addObject:entry.itemID];
        if (entry.kind == SZFriendsOutboxKindMessage) messageID = entry.itemID;
    }
    if (!includeMessage) return @{@"transfer_ids" : transferIDs};
    return @{@"message_id" : messageID ?: @"", @"transfer_ids" : transferIDs};
}

- (void)intent_send_message:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    BOOL viaAssistant = NO;
    if (person == nil || ![self checkCanSendTo:person reply:reply connection:connection] ||
        ![self viaAssistantIn:intent value:&viaAssistant reply:reply connection:connection]) {
        return;
    }
    NSString *text = intent[@"text"];
    id attachments = intent[@"attachments"];
    BOOL hasAttachments = [attachments isKindOfClass:[NSArray class]] && [attachments count] > 0;
    BOOL tooLong = SZFriendsJSONIsString(text) &&
                   [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > SZFriendsMessageBytesMax;
    if (!SZFriendsJSONIsString(text) || tooLong || (text.length == 0 && !hasAttachments)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"text"} connection:connection];
        return;
    }
    NSString *token = [self clientTokenIn:intent reply:reply connection:connection];
    if (token == nil) return;
    if ([self isYou:person]) { // to our own computers, never through the outbox (+Devices)
        text = [self textWithMentionsIn:intent text:text reply:reply connection:connection];
        if (text != nil) {
            [self sendToYouText:text attachments:attachments token:token viaAssistant:viaAssistant
                     connection:connection reply:reply];
        }
        return;
    }
    NSDictionary *earlier = [self earlierResultForToken:token includeMessage:YES];
    if (earlier != nil) {
        // Sent before the reconnect: answer with what was sent instead of sending twice.
        reply(earlier, nil, nil, nil);
        return;
    }
    // The friends its @ chips name, written in as mentions (PROTOCOL.md § Mentions).
    text = [self textWithMentionsIn:intent text:text reply:reply connection:connection];
    if (text == nil) return;
    NSArray<SZFriendsTransferRecord *> *staged = @[];
    if (attachments != nil && attachments != [NSNull null]) {
        staged = [self stageFiles:attachments field:@"attachments" max:SZFriendsAttachmentsMax
                   conversationID:person.conversationID reply:reply connection:connection];
        if (staged == nil) return;
    }
    SZFriendsItemRecord *message = [[SZFriendsItemRecord alloc] init];
    message.itemID = SZFriendsNewIdentifier();
    message.conversationID = person.conversationID;
    message.kind = SZFriendsItemKindMessage;
    message.direction = SZFriendsDirectionOutgoing;
    message.sentAt = [NSDate date];
    message.receivedAt = message.sentAt;
    message.text = text;
    message.viaAssistant = viaAssistant;
    NSError *error = nil;
    if (![self enqueueKind:SZFriendsOutboxKindMessage conversationID:person.conversationID item:message
               clientToken:token error:&error]) {
        for (SZFriendsTransferRecord *done in staged) {
            [self.services.transfers discardStagedTransfer:done.transferID error:NULL];
        }
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    NSArray *transferIDs = [self offerTransfers:staged conversationID:person.conversationID clientToken:token
                                   viaAssistant:viaAssistant];
    [self succeed:reply result:@{@"message_id" : message.itemID, @"transfer_ids" : transferIDs}];
}

- (void)intent_send_files:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                    reply:(SZFriendsIntentReply)reply {
    SZFriendsPersonRecord *person = [self personForIntent:intent reply:reply connection:connection];
    BOOL viaAssistant = NO;
    if (person == nil || ![self checkCanSendTo:person reply:reply connection:connection] ||
        ![self viaAssistantIn:intent value:&viaAssistant reply:reply connection:connection]) {
        return;
    }
    NSString *token = [self clientTokenIn:intent reply:reply connection:connection];
    if (token == nil) return;
    id files = intent[@"files"];
    if (![files isKindOfClass:[NSArray class]] || [files count] == 0) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"files"} connection:connection];
        return;
    }
    if ([self isYou:person]) {
        [self sendFilesToYou:files viaAssistant:viaAssistant connection:connection reply:reply];
        return;
    }
    NSDictionary *earlier = [self earlierResultForToken:token includeMessage:NO];
    if (earlier != nil) {
        reply(earlier, nil, nil, nil); // offered before a reconnect: the same transfers, not new ones
        return;
    }
    NSArray *staged = [self stageFiles:files field:@"files" max:SZFriendsFilesPerSendMax
                        conversationID:person.conversationID reply:reply connection:connection];
    if (staged == nil) return;
    NSArray *transferIDs = [self offerTransfers:staged conversationID:person.conversationID clientToken:token
                                   viaAssistant:viaAssistant];
    [self succeed:reply result:@{@"transfer_ids" : transferIDs}];
}

#pragma mark - Transfers

- (nullable SZFriendsTransferRecord *)transferForIntent:(NSDictionary *)intent reply:(SZFriendsIntentReply)reply
                                             connection:(SZFriendsIPCConnection *)connection {
    NSString *identifier = [self requiredString:@"transfer_id" in:intent maxLength:64 reply:reply
                                     connection:connection];
    if (identifier == nil) return nil;
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:identifier];
    if (transfer == nil) [self fail:reply code:@"not_found" details:@{@"field" : @"transfer_id"} connection:connection];
    return transfer;
}

- (void)intent_cancel_transfer:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    // Cancel after Get: the file stays on the computer that has it (+Devices).
    NSString *requested = SZFriendsJSONIsString(intent[@"transfer_id"]) ? intent[@"transfer_id"] : nil;
    if (requested != nil && [self.services.nearby cancelFetchOfFile:requested]) {
        [self succeed:reply result:nil];
        return;
    }
    SZFriendsTransferRecord *transfer = [self transferForIntent:intent reply:reply connection:connection];
    if (transfer == nil) return;
    // What already arrived cannot be retracted: the transfer area answers Stale for a settled transfer.
    NSError *error = nil;
    if (![self.services.transfers cancelTransfer:transfer.transferID error:&error]) {
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    // The other side learns of it from a CANCEL the session sends; the payload names the transfer.
    [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:transfer.conversationID
              payload:@{@"frame" : @"cancel", @"transfer_id" : transfer.transferID}];
    [self.services.nearby transferChanged:transfer.transferID];
    [self succeed:reply result:nil];
}

- (void)answerOffer:(NSDictionary *)intent accept:(BOOL)accept connection:(SZFriendsIPCConnection *)connection
              reply:(SZFriendsIntentReply)reply {
    SZFriendsTransferRecord *transfer = [self transferForIntent:intent reply:reply connection:connection];
    if (transfer == nil) return;
    if (transfer.outgoing) {
        [self fail:reply code:@"not_allowed" details:nil connection:connection];
        return;
    }
    NSError *error = nil;
    BOOL done = accept ? [self.services.transfers acceptTransfer:transfer.transferID automatically:NO error:&error]
                       : [self.services.transfers declineTransfer:transfer.transferID error:&error];
    if (!done) {
        // Stale when the offer was withdrawn meanwhile; disk_full leaves it waiting so the person can free space.
        NSString *code = SZFriendsStoreProtocolErrorCode(error);
        if ([code isEqualToString:@"disk_full"]) {
            [self failDiskFullForTransfer:transfer reply:reply connection:connection];
            return;
        }
        [self fail:reply code:code details:nil connection:connection];
        return;
    }
    [self enqueueKind:SZFriendsOutboxKindAnswer conversationID:transfer.conversationID
              payload:@{@"frame" : @"offer_reply", @"transfer_id" : transfer.transferID, @"accept" : @(accept)}];
    [self.services.nearby transferChanged:transfer.transferID];
    [self succeed:reply result:nil];
}

// The message names the file ("Not enough space to download Site photos.pdf"); the wire details carry only the
// sizes, since the view needs nothing more and the name is already in the snapshot.
- (void)failDiskFullForTransfer:(SZFriendsTransferRecord *)transfer
                          reply:(SZFriendsIntentReply)reply
                     connection:(SZFriendsIPCConnection *)connection {
    uint64_t needed = transfer.size > transfer.verifiedBytes ? transfer.size - transfer.verifiedBytes : 0;
    uint64_t available = self.services.transfers.freeBytesProvider(self.services.paths.stateDirectory);
    NSDictionary *details = @{@"needed_bytes" : @(needed), @"available_bytes" : @(available)};
    NSMutableDictionary *forMessage = [details mutableCopy];
    forMessage[@"file_name"] = transfer.fileName;
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    reply(nil, @"disk_full", [strings messageForErrorCode:@"disk_full" details:forMessage], details);
}

- (void)intent_accept_offer:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                      reply:(SZFriendsIntentReply)reply {
    [self answerOffer:intent accept:YES connection:connection reply:reply];
}

- (void)intent_decline_offer:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    [self answerOffer:intent accept:NO connection:connection reply:reply];
}

- (void)intent_retry_item:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                    reply:(SZFriendsIntentReply)reply {
    NSString *itemID = [self requiredString:@"item_id" in:intent maxLength:64 reply:reply connection:connection];
    if (itemID == nil) return;
    NSError *error = nil;
    SZFriendsOutboxEntry *entry = [self.services.outbox entryForItemID:itemID];
    if (entry != nil && entry.state == SZFriendsOutboxStateFailed) {
        // Never delivered: Try again requeues the entry, and an offer's transfer moves with it.
        if (![self.services.outbox applyEvent:SZFriendsOutboxEventRetry toEntry:entry.entryID error:&error]) {
            [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
            return;
        }
        [self.services.nearby outboxChangedForConversation:entry.conversationID];
        [self succeed:reply result:nil];
        return;
    }
    // A transfer that failed after acceptance (digest mismatch, source gone) resumes through the transfer area.
    SZFriendsTransferRecord *transfer = [self.services.transfers transferWithID:itemID];
    if (transfer != nil && transfer.state == SZFriendsTransferStateFailed) {
        if (![self.services.transfers retryTransfer:itemID error:&error]) {
            [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
            return;
        }
        [self.services.nearby transferChanged:itemID];
        [self succeed:reply result:nil];
        return;
    }
    NSString *code = (entry != nil || transfer != nil) ? @"stale" : @"not_found";
    [self fail:reply code:code details:@{@"field" : @"item_id"} connection:connection];
}

#pragma mark - Search, delete, reset

- (void)intent_search_messages:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                         reply:(SZFriendsIntentReply)reply {
    NSString *query = intent[@"query"];
    if (!SZFriendsJSONIsString(query) || query.length > 200) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"query"} connection:connection];
        return;
    }
    id conversationID = intent[@"conversation_id"];
    NSArray<NSString *> *scope = nil;
    if (conversationID != nil && conversationID != [NSNull null]) {
        if ([self personForIntent:intent reply:reply connection:connection] == nil) return;
        scope = @[ conversationID ];
    }
    id limitValue = intent[@"limit"];
    NSUInteger limit = SZFriendsSearchLimitDefault;
    if (limitValue != nil) {
        if (!SZFriendsJSONIsInteger(limitValue)) {
            [self fail:reply code:@"invalid_field" details:@{@"field" : @"limit"} connection:connection];
            return;
        }
        limit = (NSUInteger)MAX(1, MIN((long long)SZFriendsSearchLimitMax, [limitValue longLongValue]));
    }
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // One more than asked, so the reply can say whether there are more. Never touches the network.
    NSArray<SZFriendsSearchHit *> *hits =
        trimmed.length > 0 ? [self.services.store searchFor:trimmed conversationIDs:scope limit:limit + 1] : @[];
    NSMutableArray<SZFriendsSearchHitFacts *> *facts = [NSMutableArray array];
    for (SZFriendsSearchHit *hit in hits) {
        if (facts.count == limit) break;
        SZFriendsSearchHitFacts *fact = [[SZFriendsSearchHitFacts alloc] init];
        fact.conversationID = hit.conversationID;
        fact.itemID = hit.itemID;
        fact.sentAt = hit.sentAt;
        fact.outgoing = hit.direction == SZFriendsDirectionOutgoing;
        fact.text = hit.text;
        fact.matchRanges = hit.matchRanges;
        [facts addObject:fact];
    }
    SZFriendsFactsPass *pass = [[SZFriendsFactsPass alloc] initWithServices:self.services now:[NSDate date]];
    NSMutableDictionary *people = [NSMutableDictionary dictionary];
    for (SZFriendsPersonFacts *person in pass.people) people[person.conversationID] = person;
    SZFriendsSnapshotBuilder *builder = [self.publisher stateForConnection:connection].builder;
    builder.mentionDirectory = pass.mentionDirectory; // excerpts show each mention as "@Name"
    reply([builder searchResultWithHits:facts people:people more:hits.count > limit now:pass.now], nil, nil, nil);
}

- (void)intent_delete_history:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                        reply:(SZFriendsIntentReply)reply {
    id conversationID = intent[@"conversation_id"];
    if (conversationID == [NSNull null]) conversationID = nil;
    if (conversationID != nil && [self personForIntent:intent reply:reply connection:connection] == nil) return;
    // With another device of ours, the deletion reaches every one of them (sync); otherwise it is the store's alone.
    SZFriendsNearbyService *nearby = self.services.nearby;
    BOOL erased = nearby ? [nearby eraseHistoryInConversation:conversationID]
                         : [self.services.store deleteHistoryInConversation:conversationID error:NULL];
    if (!erased) {
        [self fail:reply code:@"internal" details:nil connection:connection];
        return;
    }
    [self.services.nearby historyDeleted];
    [self succeed:reply result:nil];
}

- (void)intent_reset_friends:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    if (![intent[@"confirm"] isEqual:@"reset"]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"confirm"} connection:connection];
        return;
    }
    SZFriendsHelperCheckIn *checkIn = self.services.checkIn;
    // Off the air while the host releases the old identity and the reset runs, and until it has succeeded.
    [self.services.nearby suspendForReset];
    __weak SZFriendsIntentRouter *weakSelf = self;
    void (^reset)(void) = ^{
        SZFriendsIntentRouter *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (![strongSelf.services resetFriendsWithError:NULL]) {
            [strongSelf fail:reply code:@"internal" details:nil connection:connection];
            return;
        }
        // Nothing of the old identity stays on the air; the host meets the new one.
        [strongSelf.services.nearby identityDidReset];
        [strongSelf.services.checkIn start];
        reply(@{}, nil, nil, nil);
        // Every view now shows someone who no longer exists: all clients reconnect and subscribe again.
        if (strongSelf.onReset) strongSelf.onReset();
    };
    // The host forgets the old identity and frees its ID first (ADR 0005 step 6), best effort and bounded.
    if (checkIn != nil) [checkIn releaseIdentityWithCompletion:reset];
    else reset();
}

@end
