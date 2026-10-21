// Intents about system notifications (PROTOCOL.md § Notifications, ADR 0017): which conversation each client shows,
// this Mac's switches, asking the system, and a test home's clicks and replies. The notifier decides; this file only
// tells it what the clients say.

#import "service/helper/SZFriendsIntentRouter.h"

#import "service/notify/SZFriendsNotify.h"

@implementation SZFriendsIntentRouter (Notifications)

// The notifier, or nil after replying unknown_intent: a helper without one does not announce `notifications`.
- (nullable SZFriendsNotifier *)notifierFor:(SZFriendsIntentReply)reply
                                connection:(SZFriendsIPCConnection *)connection {
    SZFriendsNotifier *notifier = self.services.notifier;
    if (notifier == nil) [self fail:reply code:@"unknown_intent" details:nil connection:connection];
    return notifier;
}

// The app the person uses Friends from now: where a click on a notification opens (activate, open_conversation, a
// non-null set_focus). Its bundle comes from the client's own process, never from what the client says.
- (void)rememberNotificationTargetFor:(SZFriendsIPCConnection *)connection {
    SZFriendsClientContext *client = connection.client;
    SZFriendsNotifier *notifier = self.services.notifier;
    if (client == nil || notifier == nil) return;
    SZFriendsPeerCredentials credentials = connection.peerCredentials;
    NSString *bundle = SZFriendsNotifyBundlePath(SZFriendsPeerExecutablePath(&credentials));
    [notifier rememberAppID:client.appID urlScheme:client.urlScheme appPath:bundle];
}

- (void)intent_set_focus:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                   reply:(SZFriendsIntentReply)reply {
    if ([self notifierFor:reply connection:connection] == nil) return;
    id conversationID = intent[@"conversation_id"];
    if (conversationID == nil) conversationID = [NSNull null];
    if (conversationID != [NSNull null] &&
        (!SZFriendsJSONIsString(conversationID) || [conversationID length] == 0 || [conversationID length] > 64)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"conversation_id"} connection:connection];
        return;
    }
    SZFriendsClientState *state = [self.publisher stateForConnection:connection];
    state.focusedConversationID = conversationID == [NSNull null] ? nil : conversationID;
    if (state.focusedConversationID != nil) [self rememberNotificationTargetFor:connection];
    reply(@{}, nil, nil, nil);
}

- (void)intent_set_notifications:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                           reply:(SZFriendsIntentReply)reply {
    SZFriendsNotifier *notifier = [self notifierFor:reply connection:connection];
    if (notifier == nil) return;
    for (NSString *field in @[ @"enabled", @"preview", @"background" ]) {
        id value = intent[field];
        if (value != nil && value != [NSNull null] && !SZFriendsJSONIsBool(value)) {
            [self fail:reply code:@"invalid_field" details:@{@"field" : field} connection:connection];
            return;
        }
    }
    // `background` is a phone's (Android): a Mac has nothing to keep running.
    if (SZFriendsJSONIsBool(intent[@"enabled"])) notifier.settings.enabled = [intent[@"enabled"] boolValue];
    if (SZFriendsJSONIsBool(intent[@"preview"])) notifier.settings.preview = [intent[@"preview"] boolValue];
    [self succeed:reply result:nil];
}

- (void)intent_allow_notifications:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                             reply:(SZFriendsIntentReply)reply {
    SZFriendsNotifier *notifier = [self notifierFor:reply connection:connection];
    if (notifier == nil) return;
    // The system shows its own prompt the first time; afterwards it answers at once with what the person chose.
    [notifier askWithCompletion:^{ [self succeed:reply result:nil]; }];
}

- (void)intent_test_notification_response:(NSDictionary *)intent connection:(SZFriendsIPCConnection *)connection
                                    reply:(SZFriendsIntentReply)reply {
    SZFriendsNotifier *notifier = self.services.notifier;
    // Test homes only: anywhere else this intent does not exist.
    if (notifier == nil || !notifier.testHome) {
        [self fail:reply code:@"unknown_intent" details:nil connection:connection];
        return;
    }
    NSString *key = [self requiredString:@"key" in:intent maxLength:128 reply:reply connection:connection];
    if (key == nil) return;
    NSString *action = intent[@"action"];
    if (![action isEqual:@"open"] && ![action isEqual:@"reply"]) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"action"} connection:connection];
        return;
    }
    id text = intent[@"text"];
    if ([action isEqual:@"reply"] && (!SZFriendsJSONIsString(text) || [text length] == 0)) {
        [self fail:reply code:@"invalid_field" details:@{@"field" : @"text"} connection:connection];
        return;
    }
    if (![notifier respondToKey:key action:action text:SZFriendsJSONIsString(text) ? text : nil]) {
        [self fail:reply code:@"not_found" details:@{@"field" : @"key"} connection:connection];
        return;
    }
    [self succeed:reply result:nil];
}

// Reply on a message notification: sent as send_message sends it, then the conversation is read (ADR 0017 § Reply).
- (void)sendNotificationReply:(NSString *)text inConversation:(NSString *)conversationID {
    NSMutableString *token = [NSMutableString string];
    NSData *bytes = [SZFriendsHelperServices randomBytes:16];
    for (NSUInteger i = 0; i < bytes.length; i++) [token appendFormat:@"%02x", ((const uint8_t *)bytes.bytes)[i]];
    NSDictionary *intent =
        @{@"type" : @"send_message", @"conversation_id" : conversationID, @"text" : text, @"client_token" : token};
    // No client asked: the reply has nowhere to go but the log.
    SZFriendsIPCConnection *none = nil;
    [self connection:none
        handleIntent:intent
               reply:^(NSDictionary *result, NSString *errorCode, NSString *message, NSDictionary *details) {
                   (void)result, (void)message, (void)details;
                   if (errorCode != nil) {
                       SZFriendsHelperLog(@"a reply from a notification was not sent: %@", errorCode);
                       return;
                   }
                   [self.services.store markConversationRead:conversationID error:NULL];
                   [self.publisher publishAllImmediately];
               }];
}

@end
