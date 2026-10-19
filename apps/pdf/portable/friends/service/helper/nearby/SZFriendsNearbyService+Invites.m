// Friend links in Add by ID (SZFriendsNearbyInvites.h).

#import "service/helper/nearby/SZFriendsNearbyInvites.h"

#import <sodium.h>

#import "service/store/SZFriendsStoreLinks.h"

@implementation SZFriendsNearbyService (Invites)

- (SZFriendsFrame *)requestFrame:(SZFriendsFrame *)frame
                 presentingInvite:(SZFriendsIDRequestRecord *)request
                   handshakeHash:(NSData *)handshakeHash {
    NSData *invite = [self.services.store inviteTokenForIDRequestConversation:request.conversationID];
    NSData *proof = invite ? SZFriendsInviteProof(invite, handshakeHash) : nil;
    if (proof == nil) return frame;
    NSMutableDictionary *fields = [frame.fields mutableCopy];
    fields[@(SZFriendsFieldInviteProof)] = proof;
    return [SZFriendsFrame frameWithType:frame.type fields:fields];
}

- (BOOL)requestUsesLiveInvite:(SZFriendsFrame *)frame handshakeHash:(NSData *)handshakeHash {
    NSData *proof = [frame dataForTag:SZFriendsFieldInviteProof];
    if (proof.length != crypto_auth_hmacsha256_BYTES) return NO;
    SZFriendsStore *store = self.services.store;
    NSDate *now = [NSDate date];
    for (SZFriendsInviteRecord *invite in [store liveInvitesAtDate:now]) {
        NSData *expected = SZFriendsInviteProof(invite.token, handshakeHash);
        if (expected != nil && sodium_memcmp(expected.bytes, proof.bytes, proof.length) == 0) {
            return [store useInvite:invite.token atDate:now error:NULL];
        }
    }
    return NO;
}

- (BOOL)requestTokenCameFromLink:(NSData *)token {
    SZFriendsStore *store = self.services.store;
    SZFriendsIDRequestRecord *request = token.length == 16 ? [store idRequestWithToken:token] : nil;
    return request != nil && [store inviteTokenForIDRequestConversation:request.conversationID] != nil;
}

@end
