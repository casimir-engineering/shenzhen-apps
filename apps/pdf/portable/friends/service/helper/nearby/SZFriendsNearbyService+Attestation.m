// Host attestations on Add by ID answers (ADR 0004, Review amendments, 9; HOST-PROTOCOL.md § ID attestations).
//
// Anyone nearby who hears an Add by ID can answer it, and the request token proves only that they heard it. The host
// can say more: at check-in it signs that our Friends ID is reserved for our identity key. The holder shows that
// attestation beside its certificate in the IK callback (never in NN, which names nobody), and the requester believes
// it only for the ID it asked for, the session's identity key, and a host in its own verified list. A believed answer
// is the holder's: its ID is marked confirmed and it may take the answer slot kept for holders. Every other answer is
// a person of their own, never merged with the holder's, whose row shows no Friends ID until they name one themselves.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import "service/helper/SZFriendsHostCheckIn.h"

SZFriendsAnswerAttestation SZFriendsJudgeAnswerAttestation(NSData *presented, SZFriendsHostList *list,
                                                           NSString *requestedID, NSData *identityKey, NSDate *now,
                                                           SZFriendsHostAttestation **attestation) {
    if (attestation) *attestation = nil;
    SZFriendsHostAttestation *parsed =
        presented.length ? [SZFriendsHostAttestation attestationFromData:presented] : nil;
    // Unreadable (or a form a newer host signs) proves nothing either way: the answer is anyone's.
    if (parsed == nil) return SZFriendsAnswerUnattested;
    // Another key's attestation is never an honest mistake: a holder only ever shows its own. Refusing it whether or
    // not its signature holds means a copied attestation earns nothing, not even an unattested slot in that session.
    if (![parsed.identityKey isEqualToData:identityKey]) return SZFriendsAnswerRefused;
    // Our list may lag a host the holder met, or the holder's last check-in may be over 30 days old, or it was renamed
    // after hearing the request: honest, but no word from the host that this key holds the ID asked for.
    if (list == nil || requestedID.length == 0 ||
        SZFriendsHostAttestationCheck(parsed, list, requestedID, identityKey, now) != SZFriendsHostAttestationValid) {
        return SZFriendsAnswerUnattested;
    }
    if (attestation) *attestation = parsed;
    return SZFriendsAnswerAttested;
}

@implementation SZFriendsNearbyService (Attestation)

- (nullable NSData *)attestationForOurAnswer {
    NSString *ours = self.services.store.friendsID;
    SZFriendsHostAttestation *attestation = ours.length ? [self.services.checkIn attestationForFriendsID:ours] : nil;
    // The host attests the ID for the person's root: only the device that is the root can show it as its own key's.
    // Another device answers unattested, its chain naming the person (+Chain).
    if (![attestation.identityKey isEqualToData:[self localIdentityKey]]) return nil;
    NSData *encoded = attestation.encodedData;
    // A payload over the session's bound would fail the callback itself; without it the answer still goes, unattested.
    return encoded.length > 0 && encoded.length <= SZFriendsAttestationMax ? encoded : nil;
}

- (SZFriendsAnswerAttestation)judgeAnswerWithToken:(NSData *)token
                                       identityKey:(NSData *)identityKey
                                         presented:(nullable NSData *)presented
                                               now:(NSDate *)now
                                       attestation:(SZFriendsHostAttestation **)attestation {
    if (attestation) *attestation = nil;
    if (presented.length == 0) return SZFriendsAnswerUnattested;
    NSString *requested = [self.services.store idRequestWithToken:token atDate:now].targetFriendsID;
    // A token that names no request of ours admits nobody whatever it carries, so its attestation is not even parsed:
    // parsing cost a listener measurably more than refusing, through the queue NN replies come off (wave-4 re-check).
    if (requested == nil) return SZFriendsAnswerUnattested;
    return SZFriendsJudgeAnswerAttestation(presented, self.services.hostListCache.currentList, requested, identityKey,
                                           now, attestation);
}

- (void)recordAnswerInConversation:(NSString *)conversationID
                       attestation:(nullable SZFriendsHostAttestation *)attestation
                       requestedID:(nullable NSString *)requestedID
                          keyKnown:(BOOL)keyKnown {
    SZFriendsStore *store = self.services.store;
    NSError *error = nil;
    if (attestation != nil) {
        if (![store confirmFriendsID:attestation.friendsID attestation:attestation.encodedData day:attestation.day
                     forConversation:conversationID error:&error]) {
            SZFriendsHelperLog(@"could not record a confirmed Friends ID: %ld", (long)error.code);
        }
        return;
    }
    // A key we knew keeps the ID it last told us itself (or one the host confirmed earlier).
    if (keyKnown) return;
    // The row the store gave a new key carries the ID we typed: our guess at who would answer, not theirs. Unconfirmed,
    // it would read as this stranger's ID beside the holder's, so it goes; their own PROFILE may name one.
    // WORKAROUND: the store prefills it in -conversationForIDRequestAnswerWithToken:...attested:; clearing it in the
    // same transaction belongs to the store.
    SZFriendsPersonRecord *person = [store personWithConversationID:conversationID];
    if (person == nil || person.friendsIDConfirmed || requestedID.length == 0 ||
        ![person.friendsID isEqualToString:requestedID]) {
        return;
    }
    person.friendsID = nil;
    if (![store savePerson:person error:&error]) {
        SZFriendsHelperLog(@"could not clear an unconfirmed Friends ID: %ld", (long)error.code);
    }
}

@end
