// The Objective-C peer of the Rust interop suites (crates/szfriends-interop): the helper's own secure channel, chunk
// flow, identity, store and transfers, and its Network.framework stream, on loopback TCP only, driven over standard
// input and output one JSON object per line exactly like the Rust peer (crates/szfriends-interop/src/peer.rs). Not
// part of the helper: `make friends-core-rs-interop-check` links it against the helper's objects in the build tree.
//
// Usage: SZFSessionPeer <state directory> <identity name>
// The identity is made in memory from the name (as the vector exporter derives it); the store and received files go
// to the state directory, a temporary home the caller removes. No keychain, no Bonjour, no other interface.

#import <Foundation/Foundation.h>
#import <Network/Network.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsSession.h"
#import "service/store/SZFriendsStore.h"
#import "service/store/SZFriendsTransfers.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFPeerSession : NSObject
@property(nonatomic) uint64_t sessionID;
@property(nonatomic, nullable) SZFriendsSecureChannel *channel;
@property(nonatomic, nullable) id<SZFriendsByteStream> stream;
@property(nonatomic, copy, nullable) NSString *conversationID;
@property(nonatomic) NSMutableDictionary<NSString *, SZFriendsChunkSender *> *senders;
@property(nonatomic) NSMutableDictionary<NSString *, NSFileHandle *> *sources;
@property(nonatomic) NSMutableSet<NSString *> *doneSent;
@property(nonatomic) NSMutableDictionary<NSString *, SZFriendsChunkReceiver *> *receivers;
@property(nonatomic) BOOL flushArmed;
@end

@interface SZFPeer : NSObject
// Everything runs on this queue: channels, store calls, commands. Network objects run on their own queue.
@property(nonatomic, readonly) dispatch_queue_t queue;
@property(nonatomic, readonly) dispatch_queue_t networkQueue;
@property(nonatomic, readonly) SZFriendsIdentity *identity;
@property(nonatomic, readonly) SZFriendsStore *store;
@property(nonatomic, readonly) SZFriendsTransfers *transfers;
@property(nonatomic, readonly) NSMutableDictionary<NSNumber *, SZFPeerSession *> *sessions;
@property(nonatomic, readonly) NSMutableSet<NSData *> *friendKeys;
@property(nonatomic, readonly) NSMutableSet<NSData *> *tokens;
@property(nonatomic, copy, nullable) NSDictionary<NSNumber *, NSData *> *publicProfile;
@property(nonatomic) uint64_t rekeyAfterBytes; // 0: the helper's own
@property(nonatomic, readonly) NSString *home;
// One person's devices: joining and sync (SZFSessionPeerDevices.m), made on first use.
@property(nonatomic, strong, nullable) id devices;
- (instancetype)initWithHome:(NSString *)home name:(NSString *)name;
- (uint64_t)nextSessionID;
// One JSON line on standard output.
- (void)emit:(NSDictionary *)event;
- (NSDictionary *)handleCommand:(NSDictionary *)command;
@end

@interface SZFPeer (Network)
- (NSDictionary *)listenOnAnyInterface:(BOOL)any;
- (NSDictionary *)dialWithCommand:(NSDictionary *)command;
@end

@interface SZFPeer (Flows)
- (void)attachChannel:(SZFriendsSecureChannel *)channel toSession:(SZFPeerSession *)session;
- (NSDictionary *)sendFileWithCommand:(NSDictionary *)command;
- (NSDictionary *)requestByIDWithCommand:(NSDictionary *)command;
@end

// Online Friends through the local Node host (SZFSessionPeerOnline.m).
@interface SZFPeer (Online)
- (NSDictionary *)onlineWithCommand:(NSDictionary *)command;
- (NSDictionary *)reachWithCommand:(NSDictionary *)command;
- (NSDictionary *)blockDirectWithCommand:(NSDictionary *)command;
- (NSDictionary *)openLinkWithCommand:(NSDictionary *)command;
- (void)stopOnline;
@end

// One person's devices: joining, the chain and sync (SZFSessionPeerDevices.m).
@interface SZFPeer (Devices)
// A device command (set_profile, device_genesis, join_*, sync_dial, add_message, erase_history, revoke_device,
// capture, device_state), or nil for one that is not.
- (nullable NSDictionary *)deviceCommand:(NSDictionary *)command;
- (BOOL)isOwnDeviceKey:(nullable NSData *)key;
- (void)devicesEstablished:(SZFPeerSession *)session;
- (void)devicesClosed:(SZFPeerSession *)session;
// JOIN, CHAIN and SYNC frames; NO for anything else.
- (BOOL)devicesSession:(SZFPeerSession *)session frame:(SZFriendsFrame *)frame;
@end

NSString *SZFHex(NSData *data);
NSData *_Nullable SZFBytes(id _Nullable hex);

NS_ASSUME_NONNULL_END
