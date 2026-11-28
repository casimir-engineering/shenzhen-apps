// The pull's stall watchdog (SZFriendsNearbyService+Pulls.m), as pulls_answers.rs's unstick_pull: holders that went
// silent (a serve that ended there, a tree that never came) are asked again, and the copy stays as it is.

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/helper/nearby/SZFriendsNearbyPullState.h"

// Silence the watchdog waits for before it asks again, doubled for each round nobody answers: 10, 20 then 40 s.
static const double SZFriendsPullStallAfter = 10;
static const uint32_t SZFriendsPullStallRounds = 3;

@implementation SZFriendsNearbyService (PullWatch)

// Each holder still in the pull is asked again for one missing block, which brings its tree back and restarts a serve
// that ended. Reopening the copy instead re-read its blocks from disk and left the holders' serves running unannounced.
// Silent through all three rounds, the pull steps aside as Cancel stops it (its holders hear a HAVE of every block)
// and is tried again later, so a copy behind it is not held up for ever.
- (void)unstickPull {
    SZFriendsPullCopy *current = self.currentPull;
    if (current == nil) return;
    double now = SZFriendsPullNow();
    if (current.askedAgainAt > 0 && current.heardAt > current.askedAgainAt) current.stalls = 0; // heard since
    double since = MAX(MAX(current.heardAt, current.startedAt), current.askedAgainAt);
    double wait = SZFriendsPullStallAfter * (double)(1u << MIN(current.stalls, SZFriendsPullStallRounds - 1));
    if (now - since < wait) return;
    NSString *shortID = [current.transferID substringToIndex:MIN((NSUInteger)8, current.transferID.length)];
    double here = current.blockCopy.receivedBytes / 1e6;
    if (current.stalls >= SZFriendsPullStallRounds) {
        SZFriendsHelperLog(@"pull %@: nothing from its holders after %u asks, %.1f MB here; steps aside", shortID,
                           SZFriendsPullStallRounds, here);
        if (self.pullNotBefore == nil) self.pullNotBefore = [NSMutableDictionary dictionary];
        self.pullNotBefore[current.transferID] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsPullNotNow];
        [self stopHoldersOf:current];
        [current.blockCopy pause];
        self.pullCurrent = nil;
        [self changed];
        return;
    }
    current.stalls++;
    current.askedAgainAt = now;
    NSData *missing = current.blockCopy.missing;
    NSUInteger asked = 0;
    for (SZFriendsPullHolder *holder in [current.holders copy]) {
        if (holder.out) continue;
        [self askHolder:holder ranges:SZFriendsRange(SZFriendsNthBlock(missing, current.probes++), 1)];
        asked++;
    }
    SZFriendsHelperLog(@"pull %@: nothing from its holders for %.0f s, %.1f MB here; %lu asked again", shortID, wait,
                       here, (unsigned long)asked);
}

@end
