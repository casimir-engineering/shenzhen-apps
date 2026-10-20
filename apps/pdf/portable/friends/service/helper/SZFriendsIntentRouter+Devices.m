// Intents about the person's computers (PROTOCOL.md § Devices): removing and renaming a computer, Get on a file another
// computer holds, and sending to You, whose messages and files go to the person's own computers by sync and never
// through the outbox to anyone else.

#import "service/helper/SZFriendsIntentRouter.h"

#import <sodium.h>

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/store/SZFriendsStoreSync.h"

// Shared with +Content, which defines them.
@interface SZFriendsIntentRouter (ContentShared)
- (nullable NSArray<SZFriendsTransferRecord *> *)stageFiles:(id)files
                                                      field:(NSString *)field
                                                        max:(NSUInteger)max
                                             conversationID:(NSString *)conversationID
                                                      reply:(SZFriendsIntentReply)reply
                                                 connection:(SZFriendsIPCConnection *)connection;
@end

static const NSUInteger SZFriendsYouAttachmentsMax = 20;
static const NSUInteger SZFriendsYouFilesMax = 100;

@implementation SZFriendsIntentRouter (Devices)

#pragma mark - Errors

- (void)failDevices:(SZFriendsIntentReply)reply
               code:(NSString *)code
             reason:(nullable NSString *)reason
              field:(nullable NSString *)field
         connection:(SZFriendsIPCConnection *)connection {
    NSDictionary *details = field ? @{@"field" : field} : @{};
    SZFriendsStrings *strings = [self.publisher stateForConnection:connection].strings;
    NSString *message = reason ? [strings devicesMessageForErrorCode:code reason:reason] : nil;
    if (message != nil) reply(nil, code, message, details);
    else [self fail:reply code:code details:details connection:connection];
}

- (BOOL)refusesOnRemovedComputer:(SZFriendsIntentReply)reply connection:(SZFriendsIPCConnection *)connection {
    if (![self.services.nearby computeThisComputerRemoved]) return NO;
    [self failDevices:reply code:@"not_allowed" reason:@"device_removed" field:nil connection:connection];
    return YES;
}

#pragma mark - Computers

- (void)intent_revoke_device:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    NSString *deviceID = [self requiredString:@"device_id" in:intent maxLength:64 reply:reply connection:connection];
    if (deviceID == nil) return;
    NSString *code = [self.services.nearby revokeDeviceWithID:deviceID];
    if (code != nil) {
        [self failDevices:reply code:code reason:[code isEqualToString:@"not_found"] ? @"device" : nil
                    field:@"device_id" connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

- (void)intent_rename_device:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                       reply:(SZFriendsIntentReply)reply {
    id name = intent[@"name"];
    if (!SZFriendsJSONIsString(name)) {
        [self failDevices:reply code:@"name_invalid" reason:@"empty" field:@"name" connection:connection];
        return;
    }
    NSString *reason = nil;
    NSString *code = [self.services.nearby renameThisComputer:name reason:&reason];
    if (code != nil) {
        [self failDevices:reply code:code reason:reason field:@"name" connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

- (void)intent_fetch_from_device:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    NSString *transferID = [self requiredString:@"transfer_id" in:intent maxLength:64 reply:reply
                                     connection:connection];
    if (transferID == nil) return;
    NSString *code = [self.services.nearby fetchFileFromDevice:transferID];
    if (code != nil) {
        [self failDevices:reply code:code reason:[code isEqualToString:@"not_found"] ? @"fetch" : nil
                    field:@"transfer_id" connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

- (void)intent_fetch_from_friend:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    NSString *transferID = [self requiredString:@"transfer_id" in:intent maxLength:64 reply:reply
                                     connection:connection];
    if (transferID == nil) return;
    NSString *reason = nil;
    NSString *code = [self.services.nearby fetchFileFromFriend:transferID reason:&reason];
    if (code != nil) {
        [self failDevices:reply code:code reason:reason field:@"transfer_id" connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

#pragma mark - You

- (BOOL)isYou:(SZFriendsPersonRecord *)person {
    return [person.conversationID isEqualToString:SZFriendsYouConversationID];
}

// One id per client token, so a send retried after a reconnect finds what it already stored.
- (NSString *)youItemIDForToken:(NSString *)token {
    NSData *bytes = [token dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[16];
    crypto_generichash(digest, sizeof digest, bytes.bytes, bytes.length, NULL, 0);
    NSMutableString *hex = [NSMutableString stringWithString:@"y_"];
    for (size_t i = 0; i < sizeof digest; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (BOOL)storeYouItem:(SZFriendsItemRecord *)item error:(NSError **)error {
    item.conversationID = SZFriendsYouConversationID;
    item.direction = SZFriendsDirectionOutgoing;
    item.sentAt = item.sentAt ?: [NSDate date];
    item.receivedAt = item.sentAt;
    return [self.services.store insertItem:item error:error];
}

// Files staged for You: a history item each, held here, copied by our other computers whatever their size.
- (NSArray<NSString *> *)storeYouFiles:(NSArray<SZFriendsTransferRecord *> *)staged viaAssistant:(BOOL)viaAssistant {
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    for (SZFriendsTransferRecord *transfer in staged) {
        SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
        item.itemID = transfer.transferID;
        item.kind = SZFriendsItemKindTransfer;
        item.transferID = transfer.transferID;
        item.viaAssistant = viaAssistant;
        if ([self storeYouItem:item error:NULL]) [identifiers addObject:transfer.transferID];
    }
    if (identifiers.count > 0) [self.services.nearby makeThumbnailsForTransfers:identifiers];
    return identifiers;
}

- (void)sendToYouText:(NSString *)text
          attachments:(nullable id)attachments
                token:(NSString *)token
         viaAssistant:(BOOL)viaAssistant
           connection:(SZFriendsIPCConnection *)connection
                reply:(SZFriendsIntentReply)reply {
    if ([self refusesOnRemovedComputer:reply connection:connection]) return;
    NSString *itemID = [self youItemIDForToken:token];
    if ([self.services.store itemWithID:itemID inConversation:SZFriendsYouConversationID] != nil) {
        reply(@{@"message_id" : itemID, @"transfer_ids" : @[]}, nil, nil, nil); // sent before a reconnect
        return;
    }
    NSArray<SZFriendsTransferRecord *> *staged = @[];
    if (attachments != nil && attachments != [NSNull null]) {
        staged = [self stageFiles:attachments field:@"attachments" max:SZFriendsYouAttachmentsMax
                   conversationID:SZFriendsYouConversationID reply:reply connection:connection];
        if (staged == nil) return;
    }
    SZFriendsItemRecord *message = [[SZFriendsItemRecord alloc] init];
    message.itemID = itemID;
    message.kind = SZFriendsItemKindMessage;
    message.text = text;
    message.viaAssistant = viaAssistant;
    NSError *error = nil;
    if (text.length > 0 && ![self storeYouItem:message error:&error]) {
        for (SZFriendsTransferRecord *done in staged) {
            [self.services.transfers discardStagedTransfer:done.transferID error:NULL];
        }
        [self fail:reply code:SZFriendsStoreProtocolErrorCode(error) details:nil connection:connection];
        return;
    }
    NSArray *transferIDs = [self storeYouFiles:staged viaAssistant:viaAssistant];
    [self.services.nearby changed]; // captured and sent to our other computers while a session with one is live
    [self succeed:reply result:@{@"message_id" : text.length > 0 ? itemID : @"", @"transfer_ids" : transferIDs}];
}

- (void)sendFilesToYou:(id)files
          viaAssistant:(BOOL)viaAssistant
            connection:(SZFriendsIPCConnection *)connection
                 reply:(SZFriendsIntentReply)reply {
    if ([self refusesOnRemovedComputer:reply connection:connection]) return;
    NSArray<SZFriendsTransferRecord *> *staged = [self stageFiles:files field:@"files" max:SZFriendsYouFilesMax
                                                   conversationID:SZFriendsYouConversationID reply:reply
                                                       connection:connection];
    if (staged == nil) return;
    NSArray *transferIDs = [self storeYouFiles:staged viaAssistant:viaAssistant];
    [self.services.nearby changed];
    [self succeed:reply result:@{@"transfer_ids" : transferIDs}];
}

@end
