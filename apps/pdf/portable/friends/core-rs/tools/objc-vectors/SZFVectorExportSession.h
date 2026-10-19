// Session transcripts (SZFVectorExportSession.m): two real SZFriendsSecureChannel objects joined by a recording
// in-memory link on one serial queue, with an injected clock and a deterministic random source per side. Everything
// either side did is kept as one ordered list of steps, which the Rust suite replays against one of its own channels
// standing in for either side: it must write exactly the bytes the helper wrote and report the same events.

#import <Foundation/Foundation.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/session/SZFriendsSession.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZFSide) { SZFSideInitiator = 0, SZFSideResponder = 1 };

// Installs the random source the transcripts draw from. Call before sodium_init(). Outside a transcript step it is
// the system's; inside one, each side draws from a stream derived from the scenario's name and the side.
void SZFInstallTranscriptRandom(void);

@interface SZFTranscript : NSObject
- (instancetype)initWithName:(NSString *)name;
@property(nonatomic, readonly) SZFriendsSecureChannel *_Nullable initiator;
@property(nonatomic, readonly) SZFriendsSecureChannel *_Nullable responder;
// Both channels share one replay cache, one clock (starting at 1000 s) and these send-rekey limits.
@property(nonatomic) uint64_t rekeyAfterBytes;
- (void)setInitiatorIdentity:(NSString *)name options:(SZFriendsHandshakeOptions *)options;
- (void)setResponderIdentity:(NSString *)name
                     profile:(nullable NSDictionary<NSNumber *, NSData *> *)profile
                      policy:(SZFriendsRemoteKeyPolicy)policy;
// Recorded as `{"do": action, ...details}` on `side`, then run on the queue in that side's context; then everything
// it set off runs to quiescence.
- (void)side:(SZFSide)side
          do:(NSString *)action
     details:(nullable NSDictionary *)details
       block:(void (^)(SZFriendsSecureChannel *channel))block;
- (void)start;
- (void)send:(SZFriendsFrame *)frame from:(SZFSide)side;
- (void)runCodeOn:(SZFSide)side;
- (void)closeSide:(SZFSide)side reason:(SZFriendsCloseReason)reason;
// Moves the shared clock and runs every scheduled refusal that came due.
- (void)advance:(NSTimeInterval)seconds;
- (NSDictionary *)export;
@end

// Each returns one scenario's transcript.
NSArray<NSDictionary *> *SZFExportSessionScenarios(void);
NSString *SZFSideName(SZFSide side);

NS_ASSUME_NONNULL_END
