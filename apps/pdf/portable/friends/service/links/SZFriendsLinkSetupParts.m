// Small pieces of a link's setup (SZFriendsLinksInternal.h): its environment's defaults, one connection attempt, and
// the readings of what the other side sent.

#import "service/links/SZFriendsLinksInternal.h"

#import <sodium.h>

static NSTimeInterval SZFriendsLinkDefaultDirectTimeout = 12;

@implementation SZFriendsLinkEnvironment
+ (NSTimeInterval)defaultDirectTimeout {
    return SZFriendsLinkDefaultDirectTimeout;
}
+ (void)setDefaultDirectTimeout:(NSTimeInterval)timeout {
    SZFriendsLinkDefaultDirectTimeout = timeout > 0 ? timeout : 12;
}
- (instancetype)init {
    if ((self = [super init])) {
        _answerTimeout = SZFriendsOnlineAnswerTimeout;
        _directTimeout = SZFriendsLinkDefaultDirectTimeout;
        _relayTimeout = 25;
        _setupTimeout = 60;
        _startTimeout = 15 * 60;
        _stallTimeout = 30;
    }
    return self;
}
@end

@implementation SZFriendsLinkAttempt
- (instancetype)init {
    if ((self = [super init])) {
        _mid = @"0";
        _outgoing = [NSMutableArray array];
        _held = [NSMutableArray array];
    }
    return self;
}
@end

NSData *SZFriendsLinkRandomNonce(void) {
    NSMutableData *nonce = [NSMutableData dataWithLength:SZFriendsLinkNonceLength];
    randombytes_buf(nonce.mutableBytes, nonce.length);
    return nonce;
}

NSInteger SZFriendsLinkAttemptNumber(id value) {
    if (![value isKindOfClass:[NSNumber class]] || CFNumberIsFloatType((__bridge CFNumberRef)value)) return 0;
    NSInteger number = [value integerValue];
    return number >= 1 && number <= 2 ? number : 0;
}

SZFriendsOnlineTechnique SZFriendsLinkRemoteTechnique(NSString *line) {
    if ([line containsString:@" typ relay"]) return SZFriendsOnlineTechniqueRelay;
    if ([line containsString:@" typ srflx"]) return SZFriendsOnlineTechniqueServerReflexive;
    if ([line containsString:@" typ prflx"]) return SZFriendsOnlineTechniquePeerReflexive;
    return [line componentsSeparatedByString:@" "].count > 4 &&
                   [[line componentsSeparatedByString:@" "][4] containsString:@":"]
               ? SZFriendsOnlineTechniqueHostIPv6
               : SZFriendsOnlineTechniqueHostPrivate;
}

SZFriendsLinkOutcome SZFriendsLinkOutcomeForReason(id reason) {
    if ([reason isEqual:SZFriendsLinkEndRevoked] || [reason isEqual:SZFriendsLinkEndExpired]) {
        return SZFriendsLinkOutcomeEnded;
    }
    return [reason isEqual:SZFriendsLinkEndChanged] ? SZFriendsLinkOutcomeChanged : SZFriendsLinkOutcomeUnavailable;
}
