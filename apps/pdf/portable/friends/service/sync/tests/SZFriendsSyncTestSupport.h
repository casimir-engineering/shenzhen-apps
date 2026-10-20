// friends-sync-check: shared helpers. Three of one person's devices (A first, then B and C joined), each with its own
// identity, store in a temporary directory and engine; delivery between them without sessions; and a canonical dump
// of everything sync promises to keep the same on every device.

#import <Foundation/Foundation.h>

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFSFailures;

#define SZFSExpect(condition, ...)                                                                                   \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            SZFSFailures++;                                                                                          \
            fprintf(stderr, "%s:%d: expected %s: %s\n", __FILE__, __LINE__, #condition,                              \
                    [[NSString stringWithFormat:__VA_ARGS__] UTF8String]);                                           \
        }                                                                                                            \
    } while (0)

NSString *SZFSTemporaryDirectory(NSString *label);
void SZFSRemoveTemporaryRoot(void);
SZFriendsIdentity *SZFSIdentity(uint8_t seed);

// One device: its identity, store and engine.
@interface SZFSDevice : NSObject
@property(nonatomic, strong) SZFriendsIdentity *identity;
@property(nonatomic, strong) SZFriendsStore *store;
@property(nonatomic, strong) SZFriendsSyncEngine *engine;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *name;
@end

// `count` devices of one person (2 or 3), the first holding the root, all with the whole chain; sync active on each.
NSArray<SZFSDevice *> *SZFSDevices(NSString *label, NSUInteger count);
// A device on its own (no chain with another device yet): sync inactive.
SZFSDevice *SZFSLoneDevice(NSString *label, uint8_t seed);

// What `to` lacks of `from`'s log, all of it or the first `limit` events, delivered. YES when `to` took them all.
BOOL SZFSDeliver(SZFSDevice *from, SZFSDevice *to);
BOOL SZFSDeliverSome(SZFSDevice *from, SZFSDevice *to, NSUInteger limit);
// Everyone captures and exchanges with everyone until nothing moves.
void SZFSSyncAll(NSArray<SZFSDevice *> *devices);

// A friend with identity key bytes `keyByte` (32 times), as a device would have them.
SZFriendsPersonRecord *SZFSAddFriend(SZFSDevice *device, uint8_t keyByte, NSString *_Nullable conversationID);
SZFriendsItemRecord *SZFSInsertMessage(SZFSDevice *device, NSString *conversationID, NSString *itemID,
                                       NSString *text, SZFriendsDirection direction, NSTimeInterval at);
// The device's conversation with the friend whose key is `keyByte` (32 times), or nil.
NSString *_Nullable SZFSConversation(SZFSDevice *device, uint8_t keyByte);
// Everything sync keeps the same on every device, as one canonical string (conversation ids replaced by who they
// are with, so two devices that named a conversation differently still compare equal).
NSString *SZFSDump(SZFSDevice *device);

void SZFSRunCodecTests(void);
void SZFSRunEngineTests(void);
void SZFSRunDeletionTests(void);
void SZFSRunOutboxFileTests(void);
void SZFSRunPropertyTests(void);
void SZFSRunExchangeTests(void);
void SZFSRunRevocationTests(void);
void SZFSRunReleaseTests(void);

NS_ASSUME_NONNULL_END
