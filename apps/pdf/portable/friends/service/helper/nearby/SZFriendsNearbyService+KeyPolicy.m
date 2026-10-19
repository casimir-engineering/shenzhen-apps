// Who may open a session to us (ADR 0004 § Hidden listeners, § Public visibility, as the wave-3 and wave-4 security
// re-checks narrowed it). Split from +Sessions so each file stays under the size cap.
//
// Everyone admitted by IK can find our device in every presence window by probing, since only our listener answers IK
// sealed to our static key, so every case below that is not a friend is bounded in time.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"

#import "service/helper/nearby/SZFriendsNearbyDevices.h"

#import "service/store/SZFriendsStoreDevices.h"

@implementation SZFriendsNearbyService (KeyPolicy)

// Whether a known person who is not a friend may open IK to our hidden listener:
//   - an outgoing request of ours, only while an answer can still come: one to someone found nearby for
//     SZFriendsOutgoingRequestLifetime after it began, an Add by ID answer's key while the request that admitted it
//     lasts (7 days from our asking), or a token of an unexpired Add by ID of ours that admits the key. Without the
//     bound, anyone who once answered an Add by ID of ours, a bystander who heard the broadcast included, could follow
//     us for good; the store lapses such rows too (-expireOutgoingRequestsAtDate:);
//   - an incoming request that found us nearby, only within SZFriendsIncomingRequestIKWindow of their asking, which is
//     when a requester withdraws by CANCEL; our own answer travels over the IK we dial, so nothing later needs theirs.
//     One that came by Friends ID never: such a requester never learned our static key from us, so the window would
//     serve only someone who had it already, renewed by every fresh key they asked from (wave-4 re-check, P4);
//   - a removed person: only presenting the token of an unexpired Add by ID of ours that admits their key, for an ID
//     the host attests is theirs (`attested`) or they last told us, which is how they answer when we ask for it again.
// Blocked people never.
- (BOOL)person:(SZFriendsPersonRecord *)person
    mayOpenIKWithToken:(nullable NSData *)token
              attested:(BOOL)attested
                   now:(NSDate *)now {
    SZFriendsStore *store = self.services.store;
    switch (person.relation) {
    case SZFriendsRelationFriend:
        return YES;
    case SZFriendsRelationOutgoingRequest: {
        if (token.length == 16 && [store idRequestWithToken:token admitsIdentityKey:person.identityKey
                                                    attested:attested atDate:now]) {
            return YES;
        }
        if (!person.requestFoundNearby) return [store identityKeyAnswersUnexpiredIDRequest:person.identityKey
                                                                                    atDate:now];
        NSDate *since = person.pendingRequestSince ?: person.requestAt;
        return since != nil && [now timeIntervalSinceDate:since] < SZFriendsOutgoingRequestLifetime;
    }
    case SZFriendsRelationIncomingRequest: {
        if (!person.requestFoundNearby) return NO;
        // From when the request began; the store keeps that moment while the request waits, so asking again does
        // not reopen the window.
        NSDate *since = person.pendingRequestSince ?: person.requestAt;
        return since != nil && [now timeIntervalSinceDate:since] < SZFriendsIncomingRequestIKWindow;
    }
    case SZFriendsRelationRemoved: {
        if (token.length != 16) return NO;
        // Only when we have reason to think they hold the ID asked for: the host says so, or it is the ID they last
        // told us themselves. That is exactly when the store takes their row back as our request (SZFriendsStore.h);
        // anyone else's answer would land on a removed row that takes no answer, leaving them sure we are friends
        // and us not, and a removed person answering a request for someone else stays removed.
        NSString *asked = [store idRequestWithToken:token atDate:now].targetFriendsID;
        if (!attested && (asked == nil || ![person.friendsID isEqualToString:asked])) return NO;
        return [store idRequestWithToken:token admitsIdentityKey:person.identityKey attested:attested atDate:now];
    }
    case SZFriendsRelationBlocked:
        return NO;
    }
    return NO;
}

// Asked on IK and NN message 1 and XX message 3, before any reply or application frame (SZFriendsSession.h). Reads
// only: IK message 1 can be replayed, so nothing here writes the store, records a sighting or spends a token; the
// session acts once the initiator's HELLO arrives (-linkWentLive:). Its one action is making room among strangers'
// sessions when their cap is full (+Limits); a replayed message 1 never gets this far (the channel's replay cache).
- (BOOL)allowRemoteKey:(nullable NSData *)key
               pattern:(SZFriendsHandshakePattern)pattern
                 token:(nullable NSData *)token
                  link:(nullable SZFriendsPeerLink *)link
           publicEntry:(BOOL)publicEntry {
    SZFriendsStore *store = self.services.store;
    if (self.shutDown || self.resetting || store == nil || [key isEqualToData:[self localIdentityKey]]) return NO;
    // A device its owner removed, a first device included, whatever relation its person has (ADR 0012). One of our
    // own computers removed while away finishes IK only to be told so (+Removed), then the session closes. A friend's
    // other authorized devices need nothing here: the store finds the friend from any of them.
    if (key != nil && [store isRevokedDeviceKey:key]) {
        return pattern == SZFriendsHandshakeIK && [self isOwnRemovedDeviceKey:key];
    }
    // Another device of this person's, which our chain authorizes: IK only, to sync (+Sync).
    if (key != nil && [self isOwnDeviceKey:key]) return pattern == SZFriendsHandshakeIK;
    // (The admission rates were applied by the adapter when the preamble named the pattern.)
    SZFriendsPersonRecord *person = key ? [store personWithIdentityKey:key] : nil;
    switch (pattern) {
    case SZFriendsHandshakeNN:
        break; // Add by ID: anyone may ask (ADR 0004 step 2), within the rate above
    case SZFriendsHandshakeXX:
        // Only a public entry reaches this (the channel refuses XX on a listener without a profile); completing XX
        // there is a friend request, which blocked people may never make.
        if (!publicEntry || person.relation == SZFriendsRelationBlocked) return NO;
        break;
    case SZFriendsHandshakeIK: {
        NSDate *now = [NSDate date];
        // A token means an answer to our Add by ID: its attestation decides which slot it may take, or refuses it
        // when it is another key's (+Attestation). Judged on the unverified field the channel holds for this ask.
        SZFriendsAnswerAttestation said = SZFriendsAnswerUnattested;
        if (token.length == 16 && key.length == 32) {
            said = [self judgeAnswerWithToken:token identityKey:key presented:link.channel.remoteAttestation now:now
                                  attestation:NULL];
        }
        if (said == SZFriendsAnswerRefused) return NO;
        // An Add from a mention admits only the key the mention carried, whoever else holds the ID (ADR 0007).
        if ([self requestToken:token refusesIdentityKey:key atDate:now]) return NO;
        BOOL attested = said == SZFriendsAnswerAttested;
        if (person != nil) {
            if (![self person:person mayOpenIKWithToken:token attested:attested now:now]) return NO;
            break;
        }
        // An unknown key only with a token we issued for an unexpired Add by ID (ADR 0004 step 4), and only while
        // its slots last: anyone who heard the broadcast can answer, so each answer is its own unverified person and
        // their number is bounded (SZFriendsIDRequestMaxAnswers), with the last slot kept for the attested holder.
        if (token.length != 16 || key.length != 32 ||
            ![store idRequestWithToken:token admitsIdentityKey:key attested:attested atDate:now]) {
            return NO;
        }
        break;
    }
    }
    if (person != nil && person.relation == SZFriendsRelationFriend && pattern != SZFriendsHandshakeNN) return YES;
    // Everyone else counts against the sessions strangers may hold at once; friends never wait for that. A full cap
    // gives the newcomer the place of the stranger session idle longest.
    if ([self strangerLinkCount] >= SZFriendsStrangerSessionsMax && ![self makeRoomForStranger]) return NO;
    link.stranger = YES;
    return YES;
}

@end
