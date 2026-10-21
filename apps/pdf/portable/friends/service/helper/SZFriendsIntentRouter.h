// The helper's dispatch layer: every intent from every client, routed to the service areas through their
// public headers, with snapshots pushed from the presentation layer before each reply.
//
// Internal to the helper. PROTOCOL.md § Intents and § Replies and errors are the contract; field limits are its
// § Limits. Handlers live in categories by subject (+Profile, +People, +Content, +Cancel, +Mentions) so each file stays
// readable.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsSubscriptions.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsIntentRouter : NSObject <SZFriendsIntentHandler>
- (instancetype)initWithServices:(SZFriendsHelperServices *)services
                       publisher:(SZFriendsPublisher *)publisher NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// welcome.capabilities and welcome.strings for this client (the server fills the frozen fields).
- (NSDictionary<NSString *, id> *)welcomeForClient:(SZFriendsClientContext *)client;

// A client sent `disable`; the lifecycle decides whether the helper exits.
@property(nonatomic, copy, nullable) void (^onDisable)(SZFriendsIPCConnection *connection);
// Reset Friends finished, or the identity became readable again; every client must reconnect and subscribe again
// (goodbye `reset`), so each gets the capabilities and views of a helper that has an identity now.
@property(nonatomic, copy, nullable) void (^onReset)(void);
// An identity exists now where there was none (Reset Friends, or SZFriendsHelperServices -retryIdentity): the helper
// creates and starts Nearby and the host check-in, which an identity-unavailable helper never had.
@property(nonatomic, copy, nullable) void (^onIdentityAvailable)(void);
@end

// Shared by the handler categories.
@interface SZFriendsIntentRouter ()
@property(nonatomic, readonly) SZFriendsHelperServices *services;
@property(nonatomic, readonly) SZFriendsPublisher *publisher;
// Replies with an error and the catalog's message for this client.
- (void)fail:(SZFriendsIntentReply)reply
        code:(NSString *)code
     details:(nullable NSDictionary<NSString *, id> *)details
  connection:(SZFriendsIPCConnection *)connection;
// Publishes every snapshot the intent changed, then replies.
- (void)succeed:(SZFriendsIntentReply)reply result:(nullable NSDictionary<NSString *, id> *)result;
// A required string field; nil after replying invalid_field when absent, not a string, empty or too long.
- (nullable NSString *)requiredString:(NSString *)key
                                   in:(NSDictionary *)intent
                            maxLength:(NSUInteger)maxLength
                                reply:(SZFriendsIntentReply)reply
                           connection:(SZFriendsIPCConnection *)connection;
// The person named by intent.conversation_id; nil after replying invalid_field or not_found.
- (nullable SZFriendsPersonRecord *)personForIntent:(NSDictionary *)intent
                                              reply:(SZFriendsIntentReply)reply
                                         connection:(SZFriendsIPCConnection *)connection;
// A history event ("now_friends", "blocked"...) in a conversation, now.
- (void)recordEvent:(NSString *)eventKind inConversation:(NSString *)conversationID;
// Queues an outbox entry for the session layer to deliver, with the history item it delivers in the same
// transaction (messages, offers).
- (BOOL)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
               item:(SZFriendsItemRecord *)item
        clientToken:(nullable NSString *)clientToken
              error:(NSError **)error;
- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
               item:(SZFriendsItemRecord *)item
        clientToken:(nullable NSString *)clientToken;
// Queues an entry with no history item (answers, cancellations, presence secrets). `payload` is what the session
// layer needs to build the frame later, kept as JSON in the entry's opaque payload: {"frame": "accept"} or
// {"frame": "decline"} for a friend request, {"frame": "cancel"} to withdraw ours, {"frame": "offer_reply",
// "transfer_id", "accept"} for a file, {"frame": "cancel", "transfer_id"} to stop one. PresenceSecret entries carry
// none: the session sends the store's current secret, so a rotation in between is never undone.
- (void)enqueueKind:(SZFriendsOutboxKind)kind
     conversationID:(NSString *)conversationID
            payload:(nullable NSDictionary<NSString *, id> *)payload;
@end

// History (SZFriendsIntentRouter+Content.m).
@interface SZFriendsIntentRouter (Content)
// delete_history's deletion of one conversation's history, or all of it for nil: on every computer of the person's
// when sync runs. NO when it failed.
- (BOOL)eraseHistoryInConversation:(nullable NSString *)conversationID;
@end

// Mentions (SZFriendsIntentRouter+Mentions.m, PROTOCOL.md § Mentions).
@interface SZFriendsIntentRouter (Mentions)
// send_message's text as it is sent: every Friends link the person typed made plain text, then each U+FFFC replaced by
// the mention of the friend `mentions` names in its place. Nil after replying when `mentions` does not fit the text,
// names someone who cannot be mentioned, or makes the text too long.
- (nullable NSString *)textWithMentionsIn:(NSDictionary *)intent
                                     text:(NSString *)text
                                    reply:(SZFriendsIntentReply)reply
                               connection:(SZFriendsIPCConnection *)connection;
@end

// The person's computers (SZFriendsIntentRouter+Devices.m, PROTOCOL.md § Devices).
@interface SZFriendsIntentRouter (Devices)
- (BOOL)isYou:(SZFriendsPersonRecord *)person;
// send_message and send_files to You: stored here, carried to our other computers by sync.
- (void)sendToYouText:(NSString *)text
          attachments:(nullable id)attachments
                token:(NSString *)token
         viaAssistant:(BOOL)viaAssistant
           connection:(SZFriendsIPCConnection *)connection
                reply:(SZFriendsIntentReply)reply;
- (void)sendFilesToYou:(id)files
          viaAssistant:(BOOL)viaAssistant
            connection:(SZFriendsIPCConnection *)connection
                 reply:(SZFriendsIntentReply)reply;
// not_allowed with its words when another of the person's computers removed this one: YES after replying.
- (BOOL)refusesOnRemovedComputer:(SZFriendsIntentReply)reply connection:(SZFriendsIPCConnection *)connection;
@end

// System notifications (SZFriendsIntentRouter+Notifications.m, PROTOCOL.md § Notifications).
@interface SZFriendsIntentRouter (Notifications)
// The client's app becomes where a notification's click opens (activate, open_conversation, a non-null set_focus).
- (void)rememberNotificationTargetFor:(SZFriendsIPCConnection *)connection;
// Reply on a message notification: sent in the conversation as send_message would, which is then read.
- (void)sendNotificationReply:(NSString *)text inConversation:(NSString *)conversationID;
@end

NS_ASSUME_NONNULL_END
