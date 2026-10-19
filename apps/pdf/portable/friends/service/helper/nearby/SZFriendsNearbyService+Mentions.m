// Mentions on the nearby side (PROTOCOL.md § Mentions, ADR 0007): what an arriving message may keep as a mention, and
// the Add from a mention that only the mentioned identity key may answer.
//
// The binding needs no store change: the request's token is a keyed hash of the mentioned key under the request's own
// callback secret (which never leaves this Mac), and the request's row holds that key from the start. A token that
// hashes the row's key is bound to it; a random token, as add_by_id draws, matches with negligible probability.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import <sodium.h>

#import "service/presentation/SZFriendsMentions.h"

NSData *SZFriendsMentionRequestToken(NSData *callbackSecret, NSData *identityKey) {
    static const char domain[] = "SZFriends mention request v1";
    if (callbackSecret.length < crypto_generichash_KEYBYTES_MIN ||
        callbackSecret.length > crypto_generichash_KEYBYTES_MAX || identityKey.length != 32) {
        return [NSData data];
    }
    uint8_t message[sizeof(domain) - 1 + 32];
    memcpy(message, domain, sizeof(domain) - 1);
    memcpy(message + sizeof(domain) - 1, identityKey.bytes, 32);
    uint8_t token[16]; // crypto_generichash_BYTES_MIN, the size of every request token (ADR 0004)
    crypto_generichash(token, sizeof token, message, sizeof message, callbackSecret.bytes, callbackSecret.length);
    return [NSData dataWithBytes:token length:sizeof token];
}

@implementation SZFriendsNearbyService (Mentions)

- (NSString *)textWithCheckedMentions:(NSString *)text {
    SZFriendsIDCodec *codec = self.services.codec;
    return SZFriendsMentionsChecked(text, ^BOOL(NSString *friendsID) {
      // Exactly an ID the list can issue, in its canonical spelling: the mention form allows no other.
      return codec != nil && [[codec normalizedID:friendsID] isEqualToString:friendsID];
    });
}

- (BOOL)requestToken:(NSData *)token isBoundToIdentityKey:(NSData *)identityKey atDate:(NSDate *)now {
    SZFriendsStore *store = self.services.store;
    SZFriendsIDRequestRecord *request = token.length == 16 ? [store idRequestWithToken:token atDate:now] : nil;
    return request != nil && identityKey.length == 32 &&
           [SZFriendsMentionRequestToken(request.callbackSecret, identityKey) isEqualToData:token];
}

- (BOOL)requestToken:(NSData *)token refusesIdentityKey:(NSData *)identityKey atDate:(NSDate *)now {
    SZFriendsStore *store = self.services.store;
    SZFriendsIDRequestRecord *request = token.length == 16 ? [store idRequestWithToken:token atDate:now] : nil;
    if (request == nil) return NO; // no request of ours: the other rules refuse it
    NSData *bound = [store personWithConversationID:request.conversationID].identityKey;
    if (bound.length != 32 || ![SZFriendsMentionRequestToken(request.callbackSecret, bound) isEqualToData:token]) {
        return NO; // an ordinary Add by ID, which any holder may answer
    }
    return ![bound isEqualToData:identityKey];
}

@end
