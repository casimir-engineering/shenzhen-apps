// friends-nat-emulator-check, second half: the real online driver, two hosts at a time, through every pair of
// emulated NAT types (szfnat.h). SZFNATMatrix.m holds the NAT types, what each pair must show and the matrix it
// writes; SZFNATWorld.m starts the public side (the host's STUN, coturn when FRIENDS_TEST_COTURN names one) and runs
// one pair of SZFNATPeer processes.

#import <Foundation/Foundation.h>

#include "szfnat.h"

NS_ASSUME_NONNULL_BEGIN

// One NAT type of the matrix.
typedef struct {
    const char *name;        // as the matrix shows it
    const char *description; // RFC 4787 terms
    szfnat_config config;
} SZFNATType;

// The public side: STUN on two ports (3478 and 3479 in production), and the relay when coturn runs.
@interface SZFNATServers : NSObject
// Nil, with `problem` set, when Node.js or the host service is missing (the suite then fails: it needs both).
// `script` is stun-host.mjs.
+ (nullable instancetype)startWithServerDirectory:(NSString *)serverDirectory
                                           script:(NSString *)script
                                          scratch:(NSString *)scratch
                                          problem:(NSString *_Nullable *_Nonnull)problem;
@property(nonatomic, readonly) uint16_t stunPrimary, stunSecondary;
@property(nonatomic, readonly) uint16_t turnPort; // 0 without coturn
@property(nonatomic, readonly, copy, nullable) NSString *turnSecret;
- (void)stop;
@end

// What one pair did, from the offerer's reports (SZFNATPeer.m) and the two NATs' counters.
@interface SZFNATOutcome : NSObject
@property(nonatomic) NSInteger offererClass, answererClass; // SZFriendsNATClass as each measured it
@property(nonatomic) BOOL direct;                           // a direct stream carried the 16-byte echo
@property(nonatomic) BOOL relayed;                          // the relay carried it
@property(nonatomic) BOOL relayRequested;
@property(nonatomic) NSInteger technique;                   // SZFriendsOnlineTechnique of the first stream
@property(nonatomic) NSUInteger tried;                      // bit per technique tried
@property(nonatomic) double seconds;                        // descriptions to first stream (technique log)
@property(nonatomic) double elapsed;                        // the offerer's reach to its first stream
@property(nonatomic) double relayAskedAt;                   // the offerer's reach to its order asking for the relay
@property(nonatomic) szfnat_stats offererNAT, answererNAT;
@property(nonatomic, copy, nullable) NSString *problem;     // why the pair could not run at all
@property(nonatomic) NSUInteger runs;
@end

// Runs the offerer behind `offerer` and the answerer behind `answerer` until the offerer's first stream carried the
// echo, its attempt ended, or (with no coturn to carry it) 2 s after its order asked for the relay; at most 45 s.
SZFNATOutcome *SZFNATRunPair(szfnat_world *world, SZFNATServers *servers, NSString *peer, NSString *scratch,
                             const SZFNATType *offerer, const SZFNATType *answerer);

NS_ASSUME_NONNULL_END
