// This person's computers in the helper (SZFriendsNearbyService+Devices.m; PROTOCOL.md § Devices). Internal to the
// helper: the router's devices intents, the facts snapshots show, and what follows a change to the profile's
// computers.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/presentation/SZFriendsPresentationDevices.h"

NS_ASSUME_NONNULL_BEGIN

// device_id in snapshots and revoke_device: "d_" and the first 8 bytes of the device key in hex.
NSString *SZFriendsDeviceIDForKey(NSData *deviceKey);

@interface SZFriendsNearbyService (Devices)
// Another of the person's computers removed this one (its chain says so, or the host did): it reads, sends nothing.
- (BOOL)computeThisComputerRemoved;
// Our devices or their states changed (+Sync's -noticeOwnDevicesChange): see the file's comment.
- (void)ownDevicesChanged;
- (void)hostSaysThisComputerWasRemoved;
// After start, off its way: a turn to draw new secrets this computer was waiting for when the helper stopped resumes
// from when it was first noticed (kept in the store), not at the next change to the profile's computers.
- (void)resumeSecretRenewalAfterStart;
// Every friend is sent this profile's presence secret as it stands (new secrets drawn, or another computer's won).
- (void)tellFriendsPresenceSecret;
// Intents. Each returns nil, or the error code to reply with.
- (nullable NSString *)revokeDeviceWithID:(NSString *)deviceID;
// `reason`: "empty" or "invalid" with name_invalid.
- (nullable NSString *)renameThisComputer:(NSString *)name reason:(NSString *_Nullable *_Nullable)reason;
- (nullable NSString *)fetchFileFromDevice:(NSString *)transferID;
// Cancel after Get: YES when a copy was asked for (it stops, and the file stays on the other computer).
- (BOOL)cancelFetchOfFile:(NSString *)transferID;
// What the snapshots of this pass show of the profile's computers.
- (SZFriendsDevicesFacts *)devicesFactsAtDate:(NSDate *)now;
@end

// A computer removed from the profile while away is told so (+Removed): found by the tags it still advertises, or
// let finish its handshake when it dials us, then given our chain alone, and the session closes.
@interface SZFriendsNearbyService (Removed)
// One of the computers our own chain removed (and this computer still belongs to the profile).
- (BOOL)isOwnRemovedDeviceKey:(NSData *)key;
// Tag secrets for the computers our chain removed, under the own-devices secret and the ones it replaced, as
// "rmv-<key>" names for the tag matcher.
- (NSDictionary<NSString *, NSArray<NSData *> *> *)removedDeviceTagSecrets;
// A candidate matched by those names: dialed with IK now and then. NO for any other candidate.
- (BOOL)reachRemovedDeviceCandidate:(SZFriendsCandidate *)candidate;
// Our chain, then the session closes.
- (void)tellRemovedComputerOnLink:(SZFriendsPeerLink *)link;
@end

NS_ASSUME_NONNULL_END
