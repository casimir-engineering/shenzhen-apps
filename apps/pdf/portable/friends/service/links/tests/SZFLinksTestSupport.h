// Shared by the links suite: checks, bounded waits on the main queue (where every link object of the suite runs),
// temporary directories, an in-memory sid pair standing in for the host, a transport that counts the connections it
// is asked for, and a sink that keeps what arrives. Every wait is bounded (at most 10 s).

#import <Foundation/Foundation.h>

#import "service/links/SZFriendsLinkOpening.h"
#import "service/online/transport/SZFriendsOnlineTransportInternal.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFLFailures;
void SZFLFail(const char *file, int line, const char *expression, NSString *detail);
#define SZFL_CHECK(condition, ...)                                                                                  \
    do {                                                                                                            \
        if (!(condition)) SZFLFail(__FILE__, __LINE__, #condition, [NSString stringWithFormat:@"" __VA_ARGS__]);    \
    } while (0)

// Runs the main run loop until `condition` holds or `timeout` (at most 10 s) passes.
BOOL SZFLWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void));
void SZFLSpin(NSTimeInterval seconds);
NSString *SZFLTemporaryDirectory(NSString *label);
void SZFLRemoveTemporaryRoot(void);
NSData *SZFLRandom(NSUInteger length);

// One end of a sid: what one side sends arrives at the other's onPayload on the main queue, in order. A sender's
// relay credentials are never given (no host here).
@interface SZFLChannel : NSObject <SZFriendsOnlineSignalChannel>
+ (NSArray<SZFLChannel *> *)pair;
@property(nonatomic, weak, nullable) SZFLChannel *peer;
@property(nonatomic) NSUInteger sent;
@end

// Counts -openConnection: calls and the purposes and roles asked for, forwarding to the loopback transport, and keeps
// the connections it made (a test closes them to drop a download mid-file).
@interface SZFLCountingTransport : NSObject <SZFriendsOnlineTransport>
- (instancetype)initWithTransport:(id<SZFriendsOnlineTransport>)transport;
@property(nonatomic, readonly) NSUInteger opened;
@property(nonatomic, readonly) NSUInteger openedBySender; // answerers
@property(nonatomic, readonly) NSMutableArray<id<SZFriendsOnlineConnection>> *connections;
@end

@class SZFriendsIdentity;

// A sender: the helper's link service on a store of its own, on the loopback transport (SZFLinksExchangeTests.m).
@interface SZFLSenderWorld : NSObject
@property(nonatomic) NSString *directory;
@property(nonatomic) SZFriendsStore *store;
@property(nonatomic) SZFriendsTransfers *transfers;
@property(nonatomic) SZFriendsIdentity *identity;
@property(nonatomic) SZFriendsLinkService *service;
@property(nonatomic) SZFLCountingTransport *transport;
@end

SZFLSenderWorld *SZFLSender(NSString *label);
SZFriendsIdentity *SZFLNewIdentity(void);
// make_download_link's work: the payload of a new link to `bytes` (written to "Site photos.pdf"; its path in *path).
SZFriendsDownloadLinkPayload *SZFLMakeLink(SZFLSenderWorld *world, NSData *bytes, NSString *_Nullable *_Nullable path);

// Keeps the metadata, the bytes at their offsets, and how it ended.
@interface SZFLSink : NSObject <SZFriendsLinkSink>
@property(nonatomic, strong, nullable) SZFriendsLinkMetadata *metadata;
@property(nonatomic, readonly) NSMutableData *bytes;
@property(nonatomic) BOOL finished;
@property(nonatomic) NSInteger stopped; // -1 until it stopped
@end

// An environment on the loopback transport (127.0.0.1), the main queue and short timeouts.
SZFriendsLinkEnvironment *SZFLEnvironment(id<SZFriendsOnlineTransport> transport);
id<SZFriendsOnlineTransport> SZFLLoopbackTransport(void);

void SZFLRunWireTests(void);
void SZFLRunPageVectorTests(void);
void SZFLRunSourceTests(void);
void SZFLRunStoreTests(void);
void SZFLRunExchangeTests(void);
void SZFLRunReceiveTests(void);
void SZFLRunServingTests(void);
void SZFLRunResumeTests(void);
void SZFLRunTombstoneTests(void);

NS_ASSUME_NONNULL_END
