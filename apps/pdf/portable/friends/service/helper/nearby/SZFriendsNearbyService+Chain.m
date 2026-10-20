// Device chains on sessions (ADR 0012; friends-multi-device.md § Identity). Every live session with a friend carries
// our chain (CHAIN, session minor 2), so friends always hold the newest list of devices that speak for us; a friend's
// chain is kept once it verifies from the root we pinned for them. The store then finds a friend from any of their
// authorized devices (-personWithIdentityKey:), so IK from those devices passes the key policy like the first
// device's, and a revoked device finds nobody. A revoked first device is still the person's identity key, so it is
// refused here.
//
// Only friends get our chain: it names our computers ("Mei's MacBook Air", "macOS 26.1"), which a stranger who reached
// a public entry has no reason to learn.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/identity/SZFriendsDeviceChain.h"
#import "service/store/SZFriendsStoreDevices.h"

@implementation SZFriendsNearbyService (Chain)

- (BOOL)chainRefusesLiveLink:(SZFriendsPeerLink *)link {
    NSData *key = link.channel.remoteIdentityKey;
    SZFriendsStore *store = self.services.store;
    if (key.length != 32 || store == nil) return NO;
    if ([store isRevokedDeviceKey:key]) {
        if ([self isOwnRemovedDeviceKey:key]) {
            [self tellRemovedComputerOnLink:link]; // one of ours, removed while away: it learns it here (+Removed)
            return YES;
        }
        SZFriendsHelperLog(@"closed a session with a device its owner removed");
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        return YES;
    }
    [store noteDeviceKey:key seenAtDate:[NSDate date] error:NULL];
    return NO;
}

- (void)sendChainOnLink:(SZFriendsPeerLink *)link {
    SZFriendsSecureChannel *channel = link.channel;
    if (link.closed || channel.pattern == SZFriendsHandshakeNN || channel.negotiatedMinor < 2) return;
    SZFriendsStore *store = self.services.store;
    SZFriendsPersonRecord *person = link.conversationID ? [store personWithConversationID:link.conversationID] : nil;
    if (person.relation != SZFriendsRelationFriend || self.services.identity == nil) return;
    // An existing profile gets its genesis here, the first time a friend needs it, never at launch.
    NSError *error = nil;
    SZFriendsDeviceChain *chain = [store ownDeviceChainCreatingGenesisWithIdentity:self.services.identity error:&error];
    if (chain == nil) {
        SZFriendsHelperLog(@"no device chain to send: %@", error.localizedDescription);
        return;
    }
    link.chainSent = YES;
    [channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                              fields:@{@(SZFriendsFieldChain) : chain.encodedData}]];
}

- (void)link:(SZFriendsPeerLink *)link person:(SZFriendsPersonRecord *)person receivedChain:(SZFriendsFrame *)frame {
    NSData *data = [frame dataForTag:SZFriendsFieldChain];
    NSData *root = person.identityKey, *device = link.channel.remoteIdentityKey;
    SZFriendsStore *store = self.services.store;
    if (data == nil || root.length != 32 || device.length != 32) return;
    // Our Add by ID answered by a device other than their first: the row the answer made names that device until
    // its chain says whose it is. Only a request may move, never a friend (whose key the person may have checked).
    if ([root isEqualToData:device] && person.relation != SZFriendsRelationFriend && !person.verified &&
        [store deviceChainForRootKey:root] == nil) {
        SZFriendsDeviceChain *theirs = [self verifiedFirstContactChain:data onLink:link];
        if (theirs != nil && [store rekeyConversation:person.conversationID fromDeviceKey:device toChain:theirs
                                                error:NULL]) {
            [self rebuildTagMatcher];
            [self changed];
            return;
        }
    }
    NSError *error = nil;
    SZFriendsChainMergeResult result = [store mergeDeviceChainData:data forRootKey:root error:&error];
    if (result == SZFriendsChainMergeRefused) {
        // A chain that does not verify from the root we pinned, or forks it, is never believed; the device that sent
        // it gets no more of this session.
        SZFriendsHelperLog(@"refused a friend's device chain: %@", error.localizedDescription);
        [link.channel closeWithReason:SZFriendsCloseReasonProtocolError];
        return;
    }
    // The chain the sender just gave may revoke the sender itself.
    BOOL stillSpeaks = [device isEqualToData:root] ? ![store isRevokedDeviceKey:device]
                                                   : [[store rootKeyForDeviceKey:device] isEqualToData:root];
    if (!stillSpeaks) {
        [link.channel closeWithReason:SZFriendsCloseReasonNormal];
        return;
    }
    if (result == SZFriendsChainMergeChanged) [self changed];
}

#pragma mark - First contact

- (void)sendFirstContactChainOnLink:(SZFriendsPeerLink *)link {
    SZFriendsSecureChannel *channel = link.channel;
    if (link.firstContactChainSent || link.ownDevice || link.closed || channel.pattern == SZFriendsHandshakeNN ||
        channel.negotiatedMinor < 2) {
        return;
    }
    link.firstContactChainSent = YES;
    SZFriendsStore *store = self.services.store;
    NSData *local = [self localIdentityKey];
    NSData *root = [store rootKeyForDeviceKey:local];
    // The first device is the person itself: nothing to explain until they are friends.
    if (root == nil || [root isEqualToData:local]) return;
    NSData *chain = store.ownDeviceChain.encodedData;
    if (chain != nil) {
        [channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeChain
                                                  fields:@{@(SZFriendsFieldChain) : chain}]];
    }
}

// A chain from a device we have no person for yet: from its own genesis, naming the session's device with the static
// key its handshake used, and not its root (the first device needs no chain to be itself). Nil otherwise.
- (nullable SZFriendsDeviceChain *)verifiedFirstContactChain:(NSData *)data onLink:(SZFriendsPeerLink *)link {
    NSData *device = link.channel.remoteIdentityKey;
    SZFriendsDeviceChain *chain = [SZFriendsDeviceChain chainWithData:data expectedRootKey:nil error:NULL];
    SZFriendsChainDevice *named = [chain deviceWithKey:device];
    BOOL fits = named != nil && [chain authorizesDeviceKey:device] && ![chain.rootKey isEqualToData:device] &&
                [named.staticKey isEqualToData:link.channel.remoteStaticKey];
    return fits ? chain : nil;
}

- (void)link:(SZFriendsPeerLink *)link receivedFirstContactChain:(SZFriendsFrame *)frame {
    NSData *data = [frame dataForTag:SZFriendsFieldChain];
    SZFriendsDeviceChain *chain = data ? [self verifiedFirstContactChain:data onLink:link] : nil;
    if (chain == nil) {
        SZFriendsHelperLog(@"a chain before a request did not name the device that sent it; ignored");
        return;
    }
    link.pendingChain = chain;
}

- (nullable NSData *)firstContactRootOnLink:(SZFriendsPeerLink *)link staticKey:(NSData **)staticKey {
    SZFriendsDeviceChain *chain = link.pendingChain;
    NSData *rootStatic = [chain deviceWithKey:chain.rootKey].staticKey;
    if (chain == nil || rootStatic.length != 32) return nil;
    if (staticKey) *staticKey = rootStatic;
    return chain.rootKey;
}

- (BOOL)otherDeviceOfPerson:(SZFriendsPersonRecord *)person
          matchesStaticKeyOnLink:(SZFriendsPeerLink *)link
                         handled:(BOOL *)handled {
    NSData *device = link.channel.remoteIdentityKey;
    *handled = device.length == 32 && person.identityKey != nil && ![device isEqualToData:person.identityKey];
    if (!*handled) return NO;
    NSData *expected = [self.services.store staticKeyForDeviceKey:device ofRootKey:person.identityKey];
    return expected != nil && [expected isEqualToData:link.channel.remoteStaticKey];
}

@end
