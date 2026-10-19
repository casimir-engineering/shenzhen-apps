// REQUEST_BY_ID signing and verification (SZFriendsSession.h § Add by ID requests; ADR 0004 step 1).
//
// NN authenticates nobody, so the request carries its own proof: the requester's certificate (binding its static
// key to its identity key) and a signature over this session's handshake hash. A device in the middle running one
// NN session with each side holds two different hashes and cannot turn a signature over one into the other.

#import "service/session/SZFriendsSession.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"

static NSString *const kRequestDomain = @"SZFriends request v1";

static NSData *SZFriendsRequestSignedBytes(NSData *handshakeHash, NSData *token, NSData *callbackSecret,
                                           NSData *staticKey, NSData *friendsID) {
    NSMutableData *bytes = [NSMutableData dataWithCapacity:64 + 16 + 32 + 32 + friendsID.length];
    [bytes appendData:handshakeHash];
    [bytes appendData:token];
    [bytes appendData:callbackSecret];
    [bytes appendData:staticKey];
    // Variable length last, after fixed-size fields, so the concatenation has one reading.
    [bytes appendData:friendsID];
    return bytes;
}

SZFriendsFrame *SZFriendsMakeRequestByIDFrame(SZFriendsIdentity *identity, NSString *friendsID, NSData *requestToken,
                                              NSData *callbackSecret, NSData *handshakeHash) {
    NSData *idBytes = [friendsID dataUsingEncoding:NSUTF8StringEncoding];
    if (requestToken.length != 16 || callbackSecret.length != 32 || handshakeHash.length != 64 ||
        idBytes.length == 0 || idBytes.length > 64) {
        return nil;
    }
    NSData *staticKey = identity.staticPublicKey;
    NSData *signature = [identity signatureForMessage:SZFriendsRequestSignedBytes(handshakeHash, requestToken,
                                                                                  callbackSecret, staticKey, idBytes)
                                               domain:kRequestDomain];
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeRequestByID
                                  fields:@{
                                      @(SZFriendsFieldFriendsID) : idBytes,
                                      @(SZFriendsFieldToken) : requestToken,
                                      @(SZFriendsFieldCallbackSecret) : callbackSecret,
                                      @(SZFriendsFieldCertificate) : identity.staticCertificate,
                                      @(SZFriendsFieldStaticKey) : staticKey,
                                      @(SZFriendsFieldSignature) : signature,
                                  }];
}

NSData *SZFriendsVerifyRequestByIDFrame(SZFriendsFrame *frame, NSData *handshakeHash) {
    NSData *idBytes = [frame dataForTag:SZFriendsFieldFriendsID];
    NSData *token = [frame dataForTag:SZFriendsFieldToken];
    NSData *callbackSecret = [frame dataForTag:SZFriendsFieldCallbackSecret];
    NSData *certificate = [frame dataForTag:SZFriendsFieldCertificate];
    NSData *staticKey = [frame dataForTag:SZFriendsFieldStaticKey];
    NSData *signature = [frame dataForTag:SZFriendsFieldSignature];
    if (frame.type != SZFriendsFrameTypeRequestByID || handshakeHash.length != 64 || !idBytes || !token ||
        !callbackSecret || !certificate || !staticKey || !signature) {
        return nil;
    }
    NSData *identityKey = SZFriendsIdentityKeyFromCertificate(certificate, staticKey);
    if (identityKey.length != 32) {
        return nil;
    }
    NSData *signedBytes = SZFriendsRequestSignedBytes(handshakeHash, token, callbackSecret, staticKey, idBytes);
    BOOL valid = [SZFriendsIdentity verifySignature:signature
                                         forMessage:signedBytes
                                             domain:kRequestDomain
                                          publicKey:identityKey];
    return valid ? identityKey : nil;
}

NSData *SZFriendsInviteProof(NSData *inviteToken, NSData *handshakeHash) {
    if (inviteToken.length != 16 || handshakeHash.length != 64) return nil;
    static const char label[] = "SZFriends invite v1";
    crypto_auth_hmacsha256_state state;
    crypto_auth_hmacsha256_init(&state, inviteToken.bytes, inviteToken.length);
    crypto_auth_hmacsha256_update(&state, (const unsigned char *)label, sizeof label - 1);
    crypto_auth_hmacsha256_update(&state, handshakeHash.bytes, handshakeHash.length);
    NSMutableData *proof = [NSMutableData dataWithLength:crypto_auth_hmacsha256_BYTES];
    crypto_auth_hmacsha256_final(&state, proof.mutableBytes);
    return proof;
}
