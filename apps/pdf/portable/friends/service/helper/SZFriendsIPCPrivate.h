// Between the IPC server and its connections only: the connection does socket I/O and framing, the server
// decides what each frame means. Split so each file stays small enough to read in one sitting.

#import "service/helper/SZFriendsHelperInternal.h"

NS_ASSUME_NONNULL_BEGIN

@class SZFriendsIPCServer;

// Pending output past this means a client that stopped reading: the helper closes it rather than buffer
// snapshots for it without bound.
extern const NSUInteger SZFriendsIPCMaxPendingOutput; // 64 MiB

@interface SZFriendsIPCConnection ()
@property(nonatomic, readwrite, nullable) SZFriendsClientContext *client;
// Ids of intents still waiting for their reply (PROTOCOL.md: unique while outstanding, at most 64).
@property(nonatomic, readonly) NSMutableSet<NSString *> *outstandingIDs;
@property(nonatomic, readonly) BOOL closing;

- (instancetype)initWithDescriptor:(int)fd
                      connectionID:(NSString *)connectionID
                           peerPID:(pid_t)peerPID
                            server:(SZFriendsIPCServer *)server
                             queue:(dispatch_queue_t)queue;
- (void)start;
// Stops reading while 64 intents wait for replies; lines already received stay buffered until resumed.
- (void)pauseReading;
- (void)resumeReading;
// Sends goodbye (reason, optional successor and error) and closes once it is written, or after 2 s at most.
- (void)sendGoodbyeWithReason:(NSString *)reason
                    successor:(nullable NSDictionary<NSString *, id> *)successor
                        error:(nullable NSDictionary<NSString *, id> *)error;
// Closes now, discarding unsent output.
- (void)closeImmediately;
@end

@interface SZFriendsIPCServer ()
// Called by a connection for each complete line (without its newline), on the helper queue.
- (void)connection:(SZFriendsIPCConnection *)connection didReceiveLine:(NSData *)line;
// A pending line exceeded the frame cap.
- (void)connectionReceivedOversizedFrame:(SZFriendsIPCConnection *)connection;
- (void)connectionDidClose:(SZFriendsIPCConnection *)connection;
@end

NS_ASSUME_NONNULL_END
