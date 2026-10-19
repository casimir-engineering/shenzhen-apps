// Shenzhen Friends device chains in the store (schema v8; ADR 0012; friends-multi-device.md § Identity).
//
// Helper-only. What persists: this person's own chain, and for each friend the newest chain their devices sent, each
// verified before it is kept and only ever replaced by a chain that holds every link of the one kept (a merge), so a
// friend's devices can be added and revoked but a stored chain never loses a link and never changes root or genesis.
// Every device of every chain is indexed by its key, which is how a session's device key finds its person
// (-personWithIdentityKey: in SZFriendsStore.h) and how a revoked device is refused.
//
// The join and sync areas build on this: a joining device adopts the profile's chain (-adoptOwnDeviceChain:...), an
// approving device stores the chain with the new add (-mergeOwnDeviceChain:...), own devices exchange chains on every
// session (-mergeOwnDeviceChain:...), and Your devices lists -devicesOfRootKey: with each one's last connection.

#import <Foundation/Foundation.h>

#import "service/store/SZFriendsStore.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsDeviceChain, SZFriendsIdentity;

typedef NS_ENUM(NSInteger, SZFriendsChainMergeResult) {
    SZFriendsChainMergeRefused = 0,   // nothing stored; the error says why (a chain error, or SZFriendsStoreError)
    SZFriendsChainMergeUnchanged = 1, // the stored chain already held every link
    SZFriendsChainMergeChanged = 2,   // the union is stored, and the device index with it
};

// One device of a chain as the store keeps it. `state` is SZFriendsChainDeviceState (SZFriendsDeviceChain.h).
@interface SZFriendsDeviceRecord : NSObject
@property(nonatomic, copy) NSData *rootKey;
@property(nonatomic, copy) NSData *deviceKey;
@property(nonatomic, copy) NSData *staticKey;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *system;
@property(nonatomic) NSInteger state;
@property(nonatomic, copy) NSDate *addedAt;
@property(nonatomic, copy, nullable) NSDate *revokedAt;
@property(nonatomic, copy, nullable) NSDate *lastSeenAt; // the last session with it went live; nil: never seen here
@property(nonatomic) BOOL isRoot;
@end

@interface SZFriendsStore (Devices)

#pragma mark Own chain

- (nullable SZFriendsDeviceChain *)ownDeviceChain;
// The own chain, writing its genesis first when there is none: an existing single-device profile becomes a chain
// whose first device is this one, with `identity`'s keys, this Mac's name and system. Done the first time the helper
// needs the chain (a session going live, Your devices), never at launch.
- (nullable SZFriendsDeviceChain *)ownDeviceChainCreatingGenesisWithIdentity:(SZFriendsIdentity *)identity
                                                                       error:(NSError **)error;
// Joining: replaces the own chain with the profile's (another root), which must authorize `localDeviceKey`. Only the
// join area calls it, once the approving device's chain arrived after the code was confirmed.
- (BOOL)adoptOwnDeviceChain:(SZFriendsDeviceChain *)chain
             localDeviceKey:(NSData *)localDeviceKey
                      error:(NSError **)error;
// A chain of the same root and genesis from one of our devices, or one this device built (an add, a revoke, a
// rename): stored as the union with the own chain.
- (SZFriendsChainMergeResult)mergeOwnDeviceChain:(SZFriendsDeviceChain *)chain error:(NSError **)error;

#pragma mark Friends' chains

// A CHAIN frame's bytes from a session with a friend whose pinned root is `rootKey`. Refused unless a person in the
// list has that identity key, the chain verifies from that root, and its genesis is the one already kept (a second
// genesis for the same root is a fork and is never believed).
- (SZFriendsChainMergeResult)mergeDeviceChainData:(NSData *)data
                                       forRootKey:(NSData *)rootKey
                                            error:(NSError **)error;
- (nullable SZFriendsDeviceChain *)deviceChainForRootKey:(NSData *)rootKey;
// First contact from a device other than a person's first (a request, or an answer to our Add by ID): the session's
// device key named the person until their chain arrived. With `chain` verified from its own genesis and authorizing
// `deviceKey`, the row of `conversationID` that holds `deviceKey` becomes the person's: its identity key the root,
// its static key the first device's, and the chain kept as theirs. Refused (nothing changed) when the row holds
// another key, the chain does not authorize the device, or someone else in the list already has that root.
- (BOOL)rekeyConversation:(NSString *)conversationID
            fromDeviceKey:(NSData *)deviceKey
                  toChain:(SZFriendsDeviceChain *)chain
                    error:(NSError **)error;

#pragma mark Devices

// The root an authorized device speaks for, in any kept chain (ours included); nil for an unknown, revoked or void key.
- (nullable NSData *)rootKeyForDeviceKey:(NSData *)deviceKey;
// YES when a kept chain revoked `deviceKey`: sessions from it are refused, whatever else knows the key.
- (BOOL)isRevokedDeviceKey:(NSData *)deviceKey;
// The X25519 static key an authorized device of `rootKey` uses, for IK to that device and for checking its sessions.
- (nullable NSData *)staticKeyForDeviceKey:(NSData *)deviceKey ofRootKey:(NSData *)rootKey;
// Every device of a kept chain: authorized ones first, the first device before the others, then by when added.
- (NSArray<SZFriendsDeviceRecord *> *)devicesOfRootKey:(NSData *)rootKey;
// A session with `deviceKey` went live: "last connection" in Your devices. Unknown keys change nothing.
- (BOOL)noteDeviceKey:(NSData *)deviceKey seenAtDate:(NSDate *)date error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
