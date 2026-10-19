// Shared pieces of the NAT techniques' suite: the CHECK macro, bounded waits, and scripted servers on loopback.
// Nothing here listens or sends anywhere but 127.0.0.1 and ::1.

#import <Foundation/Foundation.h>

#import "service/online/nat/SZFriendsNAT.h"

NS_ASSUME_NONNULL_BEGIN

extern int SZFTestFailures;

#define CHECK(condition, ...)                                                                                        \
    do {                                                                                                             \
        if (!(condition)) {                                                                                          \
            SZFTestFailures++;                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s %s\n", __FILE__, __LINE__, #condition,                          \
                    [[NSString stringWithFormat:@"" __VA_ARGS__] UTF8String]);                                       \
        }                                                                                                            \
    } while (0)

// Waits for `semaphore` at most `seconds` (never more than 10); NO on timeout.
BOOL SZFTestWait(dispatch_semaphore_t semaphore, NSTimeInterval seconds);
// Runs `block` on `queue` and waits for it.
void SZFTestSync(dispatch_queue_t queue, dispatch_block_t block);
dispatch_queue_t SZFTestQueue(const char *name);

// A UDP server on a loopback address. `handler` runs on the server's own queue for each datagram and returns the
// datagrams to send back to the sender (empty for none).
typedef NSArray<NSData *> *_Nonnull (^SZFTestUDPHandler)(NSData *packet, SZFriendsNATEndpoint *from);

@interface SZFTestUDPServer : NSObject
- (nullable instancetype)initWithHost:(NSString *)host port:(uint16_t)port handler:(SZFTestUDPHandler)handler;
@property(nonatomic, readonly) SZFriendsNATEndpoint *endpoint;
@property(nonatomic, readonly) NSUInteger received;
- (void)sendData:(NSData *)data to:(SZFriendsNATEndpoint *)destination;
- (void)close;
@end

// A STUN Binding responder (UDP) that answers with XOR-MAPPED-ADDRESS: the sender's address, or the sender's address
// with its port moved by `portShift` (a NAT that maps this destination anew), and FINGERPRINT.
SZFTestUDPServer *_Nullable SZFTestStunServer(NSString *host, int32_t portShift);

// A loopback TCP listener; `handler` gets each accepted connection's descriptor on a background thread and owns it.
@interface SZFTestTCPServer : NSObject
- (nullable instancetype)initWithHost:(NSString *)host handler:(void (^)(int descriptor))handler;
@property(nonatomic, readonly) SZFriendsNATEndpoint *endpoint;
@property(nonatomic, readonly) NSUInteger accepted;
- (void)close;
@end

// Reads until `length` bytes or EOF or `seconds`; returns what arrived.
NSData *SZFTestReadSocket(int descriptor, NSUInteger length, NSTimeInterval seconds);

// A small free loopback port window: `count` consecutive UDP ports all bindable on 127.0.0.1, held by the returned
// sockets (descriptors) until the caller closes them. Empty when none was found.
NSArray<NSNumber *> *SZFTestHoldUDPPortWindow(NSUInteger count, uint16_t *firstPort);

// The suites, each in its own file.
void SZFTestCodecs(void);
void SZFTestClassifier(NSString *_Nullable serverDirectory);
void SZFTestPortMapping(void);
void SZFTestUPnP(void);
void SZFTestProber(void);
void SZFTestTCPPath(void);

NS_ASSUME_NONNULL_END
