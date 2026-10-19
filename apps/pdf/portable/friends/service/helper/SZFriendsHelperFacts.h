// Turns what the store holds into the fact objects the presentation layer builds snapshots from.
//
// Internal to the helper. One pass per publish: every subscription published in that pass reads the same facts,
// so two windows never show a badge and a list computed from different moments, and each store query runs once.

#import <Foundation/Foundation.h>

#import "service/helper/SZFriendsHelperServices.h"
#import "service/presentation/SZFriendsPresentationDevices.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsFactsPass : NSObject
- (instancetype)initWithServices:(SZFriendsHelperServices *)services now:(NSDate *)now NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, readonly) NSDate *now;
// Store order: latest interaction first. Empty without a store.
@property(nonatomic, readonly) NSArray<SZFriendsPersonFacts *> *people;
// Each person's newest item, keyed by item id (SZFriendsPersonFacts.lastPreviewItemID): what list rows describe.
@property(nonatomic, readonly) NSDictionary<NSString *, SZFriendsItemFacts *> *previewItems;
@property(nonatomic, readonly) SZFriendsProfileFacts *profile;
// The same profile with "Your links" filled in, for the profile view only (the links service is made for it).
- (SZFriendsProfileFacts *)profileWithLinks;
@property(nonatomic, readonly) SZFriendsNearbyFacts *nearby;
// What mentions resolve against in this pass's snapshots: the same people and profile (PROTOCOL.md § Mentions).
@property(nonatomic, readonly) SZFriendsMentionDirectory *mentionDirectory;
// What the helper announces now (SZFriendsHelperCapabilityList): every snapshot of the pass is worded for it.
@property(nonatomic, readonly) NSSet<NSString *> *helperCapabilities;
// The profile's computers, You and files on another computer (PROTOCOL.md § Devices), while the helper announces
// "devices"; nil otherwise. `people` never holds You: its row comes from here.
@property(nonatomic, readonly, nullable) SZFriendsDevicesFacts *devices;

- (nullable SZFriendsPersonFacts *)personWithConversationID:(NSString *)conversationID;
// Rows waiting for this person's answer (requests, offers, key changes), not counting `conversationID`: the
// count on a back arrow.
- (NSInteger)waitingCountExcluding:(nullable NSString *)conversationID;
// The newest `window` items, oldest first.
- (NSArray<SZFriendsItemFacts *> *)itemsInConversation:(NSString *)conversationID
                                                window:(NSUInteger)window
                                            hasEarlier:(BOOL *)hasEarlier;
// This person's outgoing messages among `messageIDs`, in that order (message_status). Not cached: each subscription
// asks for its own few ids.
- (NSArray<SZFriendsItemFacts *> *)outgoingMessagesWithIDs:(NSArray<NSString *> *)messageIDs;
@end

// The helper capabilities a welcome announces now (PROTOCOL.md § Capabilities), in a stable order. `online` joins once
// the host has said it takes online messages; snapshots follow it from then on, also on connections whose welcome
// came before.
NSArray<NSString *> *SZFriendsHelperCapabilityList(SZFriendsHelperServices *services);

// One item's facts, with the outbox state and transfer record the presentation needs beside the history row.
SZFriendsItemFacts *SZFriendsItemFactsFromRecord(SZFriendsItemRecord *record, SZFriendsHelperServices *services);

NS_ASSUME_NONNULL_END
