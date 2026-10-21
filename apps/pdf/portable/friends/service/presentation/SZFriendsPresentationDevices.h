// One profile on several computers, as the views show it (PROTOCOL.md § Devices): Your computers in the profile, a
// computer another one removed, the You conversation, files another computer holds, and Delete history saying where
// it deletes. Facts in, display-ready data out, like the rest of the builder (SZFriendsPresentation.h); the words are
// SZFriendsCatalogDevices.m's.
//
// The helper sets SZFriendsSnapshotBuilder.devices for an audience whose helper announces "devices"; with it nil every
// snapshot is the one-computer snapshot it always was.

#import "service/presentation/SZFriendsPresentation.h"

NS_ASSUME_NONNULL_BEGIN

// One computer of the profile as Your computers lists it.
@interface SZFriendsDeviceFacts : NSObject
@property(nonatomic, copy) NSString *deviceID;     // opaque, stable for the computer; revoke_device sends it back
@property(nonatomic, copy) NSString *name;         // "Raph’s Mac mini", as the computer named itself
@property(nonatomic, copy) NSString *system;       // "macOS 26.1"
@property(nonatomic) BOOL thisComputer;
@property(nonatomic) BOOL connected;               // a session with it is live now
@property(nonatomic, copy, nullable) NSDate *lastSeenAt; // the last session with it; nil: never reached from here
@end

// A file one of the person's other computers holds and this one does not have yet.
@interface SZFriendsDeviceFileFacts : NSObject
@property(nonatomic, copy) NSString *deviceName;   // the computer that has it
@property(nonatomic) BOOL fetching;                // the person pressed Get
@property(nonatomic) BOOL holderConnected;         // a session with that computer is live, so it copies now
@property(nonatomic) double fraction;              // how much arrived, while it copies
@end

@interface SZFriendsDevicesFacts : NSObject
// The pass's time: when each computer last connected is counted from it.
@property(nonatomic, copy) NSDate *now;
// This computer first, then the others by when they joined; removed computers are left out.
@property(nonatomic, copy) NSArray<SZFriendsDeviceFacts *> *computers;
// Another of the person's computers removed this one: it reads, and sends nothing.
@property(nonatomic) BOOL removed;
// Joining an existing profile can start at once: this computer has nobody in Friends and no other computer.
@property(nonatomic) BOOL joinOffered;
// Joining is offered after Reset Friends: this computer has no other computer, but people in Friends it would lose.
@property(nonatomic) BOOL joinReplaces;
// This profile's Friends ID: what another computer types to join it, and the ID joining here would replace.
@property(nonatomic, copy, nullable) NSString *friendsID;
// The You conversation while its row shows (two or more computers, or anything in it), and its newest item.
@property(nonatomic, strong, nullable) SZFriendsPersonFacts *you;
@property(nonatomic, strong, nullable) SZFriendsItemFacts *youPreview;
// You items every other computer holds, by item id: "On all your computers".
@property(nonatomic, copy) NSSet<NSString *> *youItemsEverywhere;
// You files being copied to another computer now, by transfer id: how much of the file that copy has.
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *youCopying;
// Files on another computer and not here, by transfer id.
@property(nonatomic, copy) NSDictionary<NSString *, SZFriendsDeviceFileFacts *> *files;
@end

@interface SZFriendsStrings (SZFriendsDevices)
// error.message for the devices intents' errors that have words of their own; nil for the rest. `reason`:
// "device" (revoke_device not_found), "empty" or "invalid" (rename_device name_invalid), "fetch" (fetch_from_device
// not_found), "again" (fetch_from_friend not_found), "device_removed" (not_allowed on a computer another one removed).
- (nullable NSString *)devicesMessageForErrorCode:(NSString *)code reason:(NSString *)reason;
// What another computer's system says to the person: a phone's ("Android", "iOS") as a phone ("Android phone"), a
// computer's as it is ("macOS 26.1").
- (NSString *)deviceSystemLabel:(NSString *)system;
- (BOOL)isPhoneSystem:(NSString *)system;
@end

@interface SZFriendsSnapshotBuilder (SZFriendsDevices)
// profile.devices.
- (NSDictionary<NSString *, id> *)devicesSectionWithFacts:(SZFriendsDevicesFacts *)facts now:(NSDate *)now;
// Settings' `join` (label, note, action), or nil when joining is not offered here (PROTOCOL.md § Joining).
- (nullable NSDictionary<NSString *, id> *)settingsJoin;
// The list with what several computers add: `state`, `removed`, the You row among the others, each row's `kind`,
// `join`; on a removed computer no join rows and no drops.
- (NSDictionary<NSString *, id> *)listWithDevices:(NSDictionary<NSString *, id> *)list
                                           people:(NSArray<SZFriendsPersonFacts *> *)people
                                            query:(NSString *)query
                                              now:(NSDate *)now;
// A conversation (You's header and composer; on a removed computer, no composer).
- (NSDictionary<NSString *, id> *)conversationWithDevices:(NSDictionary<NSString *, id> *)conversation
                                                   person:(SZFriendsPersonFacts *)person;
// An outgoing You message's status, or nil when the conversation is not You.
- (nullable NSDictionary<NSString *, id> *)youStatusForMessage:(SZFriendsItemFacts *)item
                                                        person:(SZFriendsPersonFacts *)person;
// A transfer item as several computers show it: a file on another computer, being fetched, or a You file copying.
- (NSDictionary<NSString *, id> *)transferWithDevices:(NSDictionary<NSString *, id> *)transfer
                                                 item:(SZFriendsItemFacts *)item
                                               person:(SZFriendsPersonFacts *)person;
// Whether Delete history speaks of every computer (two or more).
@property(nonatomic, readonly) BOOL deletesOnEveryComputer;
// A copying file's progress ("Copying, 25 percent").
- (NSDictionary<NSString *, id> *)progressWithFraction:(double)fraction;
@end

// A file the person moved or deleted (SZFriendsSnapshotBuilder+Again.m, PROTOCOL.md § Getting a file again).
@interface SZFriendsSnapshotBuilder (SZFriendsAgain)
// A transfer item by where its bytes are: here (as built), on another computer (+Devices), or moved or deleted, with
// Get again from the friend who sent it.
- (NSDictionary<NSString *, id> *)transferWhereItIs:(NSDictionary<NSString *, id> *)transfer
                                              item:(SZFriendsItemFacts *)item
                                            person:(SZFriendsPersonFacts *)person;
@end

NS_ASSUME_NONNULL_END
