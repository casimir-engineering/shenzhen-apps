// The AI chat cards for friends_send_message (ai-agent-capabilities.md § 1): one card per message, from the moment
// the assistant writes it until Friends reports it delivered, and what the person's clicks on it do.
//
//   Message for Mei   "Not sent yet. Check it, then press Send."         Send, Discard   (every message starts here;
//                                                                        SPDFMacFriendsNotSentYetNote, as `/` says)
//   Message for Mei   "Sending…"
//   Message for Mei   Friends' own condition ("Messages and files send when Mei is nearby with ShenzhenPDF,
//                     Shenzhen Files or Shenzhen 3D open.") and "Show opens your chat with Mei, where you can see
//                     when it arrives."; on its way, Friends' own status ("Connecting to Mei…")
//                                                                        Show, and Cancel while queued or connecting
//                                                                        when the helper has messages.cancel
//   Sent to Mei       Friends' own words ("Delivered")                    Show            (once Friends reports it)
//   Not sent to Mei   why: discarded, cancelled, refused, not delivered
//
// Every card shows the recipient, the text exactly as it goes (as literal characters, SPDFMacAIActivityBodyStyleKey)
// and the files. Send queues that same text, so what the person approved is what Friends receives. The words about
// delivery are Friends' own (its queued_note static string and message_status labels), so the card and the Friends
// conversation never disagree about when a message goes.
//
// Handlers live only while a chat stays open (SPDFMacAIChatActivity.h), but a message waiting for Send must keep
// working after its request ends and after its chat is closed and reopened, until the person acts. So this object,
// which lives as long as the window's chat, keeps every card it may still act on, and -restoreCardsInActivity:,
// called whenever the chat changes, gives a reopened card back its state, actions and handler. Unsettled cards stay
// "running": a chat reopened after the app quit, when nothing here remembers them, shows their interrupted status,
// which never mentions a button that is no longer there.

#import <Foundation/Foundation.h>
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacFriendsSendProvider.h"

NS_ASSUME_NONNULL_BEGIN

// A queued card's words, pure so tests can read them. `condition`: Friends' own sentence for when queued messages go
// (the queued_note static string, {first} filled with `name`), nil when this helper has none. `show`: the card
// offers Show.
NSString* SPDFMacFriendsQueuedStatus(NSString* name, NSString* _Nullable condition, BOOL show);
// Friends' queued_note for `name`, or nil when the helper has not said it.
NSString* _Nullable SPDFMacFriendsQueuedCondition(id<SPDFMacFriendsIntentSender> _Nullable sender, NSString* name);

typedef void (^SPDFMacFriendsSendOutcome)(SPDFMacFriendsSendRecord* _Nullable record, NSString* _Nullable errorCode,
                                          NSString* _Nullable errorMessage);

@interface SPDFMacFriendsSendCards : NSObject
- (instancetype)initWithSender:(id<SPDFMacFriendsIntentSender> _Nullable (^)(void))sender NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Show: opens the Friends dropdown at the message. No Show without it.
@property(nonatomic, copy, nullable) void (^showMessage)(NSString* conversationID, NSString* messageID);
// A card that waits for the person: nothing reaches Friends until they press Send. nil when the chat cannot show
// another card, and then nothing will be sent.
- (nullable NSString*)proposePlan:(SPDFMacFriendsSendPlan*)plan activity:(id<SPDFMacAIActivityReporting>)activity;
// The person pressed Send somewhere other than a card (a `/` proposal above the friend's composer, where Friends
// itself shows the message once it has it): queues exactly `plan` with via_assistant and no card. `outcome` runs
// once, on the main thread, with the record Friends accepted or its error code and message.
- (void)queuePlan:(SPDFMacFriendsSendPlan*)plan sender:(id<SPDFMacFriendsIntentSender>)sender
          outcome:(SPDFMacFriendsSendOutcome)outcome;
// The chat was shown, reopened or changed: cards in it get back their actions, and queued messages in it are watched
// for Friends' delivery status while it stays open. Cheap when nothing changed.
- (void)restoreCardsInActivity:(nullable SPDFMacAIChatActivity*)activity;
@end

NS_ASSUME_NONNULL_END
