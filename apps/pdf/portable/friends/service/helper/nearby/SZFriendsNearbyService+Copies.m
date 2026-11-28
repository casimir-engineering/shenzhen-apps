// Get again and own-device copies served by blocks (ADR 0018 § 4, as the Rust helper's service/again.rs): on a session
// with fast transfers, the other side asks for a file by blocks (AGAIN 4 from a friend, SYNC 7 from another of our
// devices). This side answers with the file's tree at the asked shift (AGAIN 5 or SYNC 8), sends the leaves (HASHES),
// then the blocks asked for as PARTs, each read from the file and checked against its leaf, while the channel has room
// and within a window of unacknowledged blocks that the other side's HAVEs move on. The requester checks each block
// and, before the file counts, its whole digest. Trees are kept per file while it is unchanged.

#import <fcntl.h>
#import <time.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/sync/SZFriendsSync.h"
#import "service/transfer/SZFriendsBlockFlow.h"

// 48 KiB parts, as the copies by offset; 8 MiB sent and not yet in a HAVE.
static const NSUInteger SZFriendsCopyPartBytes = 48 * 1024;
static const uint64_t SZFriendsCopyWindowBytes = 8ull << 20;
// The channel's bulk queue is kept this shallow, as the block exchange keeps it.
static const NSUInteger SZFriendsCopyBulkDepth = 4;
// A serve with nothing asked left ends after this long (a computer resuming asks only for the blocks it misses, so
// its last HAVE need not cover the file); one waiting this long on a HAVE ends too (the other computer stopped, or
// took the rest from another holder). As the Rust helper's serving.rs.
static const double SZFriendsCopyIdleEnd = 2, SZFriendsCopyHaveWait = 30;
// While serving, the copies are pumped at least this often (writes completing pump them sooner).
static const NSTimeInterval SZFriendsCopyTick = 0.25;
static const NSUInteger SZFriendsCopyTreesKept = 16;

// One file served by blocks on one session.
@interface SZFriendsCopyServe : NSObject {
  @public
    int fd;
}
@property(nonatomic, strong) SZFriendsBlockServe *serve;
@property(nonatomic) BOOL sync;
@property(nonatomic, copy) NSData *root;
@property(nonatomic) uint64_t size;
@property(nonatomic) double lastActivity; // monotonic seconds: last ask or HAVE
// For helper.log: when the serve began, what it sent, how often it was asked, the last progress line.
@property(nonatomic) double startedAt, loggedAt;
@property(nonatomic) uint64_t bytesSent, loggedBytes;
@property(nonatomic) NSUInteger asks;
@end

@implementation SZFriendsCopyServe
- (instancetype)init {
    if ((self = [super init])) fd = -1;
    return self;
}
- (void)dealloc {
    if (fd >= 0) close(fd);
}
@end

// Trees served, by transfer, path, size, modification time and shift: leaves, then the root.
static NSMutableDictionary<NSString *, NSArray<NSData *> *> *SZFriendsCopyTrees(void) {
    static NSMutableDictionary *trees;
    if (trees == nil) trees = [NSMutableDictionary dictionary];
    return trees;
}

static double SZFriendsCopyNow(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

@implementation SZFriendsNearbyService (Copies)

// One line for helper.log about a copy served by blocks: who, how long, what went and what came back.
- (void)logServe:(SZFriendsCopyServe *)served transfer:(NSString *)transferID link:(SZFriendsPeerLink *)link
            what:(NSString *)what {
    double now = SZFriendsCopyNow(), seconds = MAX(now - served.startedAt, 0.001);
    double since = MAX(now - served.loggedAt, 0.001);
    SZFriendsHelperLog(@"copy %@ to %@ (%@) %@ after %.1f s: %.1f MB sent (%.2f MB/s, %.2f MB/s lately), %.1f MB "
                       @"acknowledged of %.1f MB, %lu asks, %lu frames queued",
                       [transferID substringToIndex:MIN((NSUInteger)8, transferID.length)],
                       served.sync ? @"own device" : @"friend", SZFriendsTraceRouteName(link.raceRoute), what,
                       seconds, served.bytesSent / 1e6, served.bytesSent / 1e6 / seconds,
                       (served.bytesSent - served.loggedBytes) / 1e6 / since, served.serve.acknowledgedBytes / 1e6,
                       served.size / 1e6, (unsigned long)served.asks, (unsigned long)link.channel.queuedBulkFrames);
    served.loggedAt = now;
    served.loggedBytes = served.bytesSent;
}

- (BOOL)serveCopyOnLink:(SZFriendsPeerLink *)link
               transfer:(NSString *)transferID
                   path:(NSString *)path
                   size:(uint64_t)size
                  shift:(uint8_t)shift
                 ranges:(NSData *)ranges
                   sync:(BOOL)sync {
    NSData *wire = SZFriendsLinkBytesFromHex(transferID);
    SZFriendsBlockGeometry geometry;
    if (link.closed || !link.channel.fastTransfers || wire == nil || !SZFriendsGeometryMake(size, shift, &geometry)) {
        return NO;
    }
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || (uint64_t)info.st_size != size) {
        if (fd >= 0) close(fd);
        return NO;
    }
    // A WANT BLOCKS for a file already served on this session adds to that serve, and its tree goes again (a pull
    // asks bit by bit: what it asked before stays asked).
    SZFriendsCopyServe *existing = link.servedCopies[transferID];
    if (existing != nil && existing.serve.geometry.shift == shift && existing.serve.geometry.size == size) {
        close(fd);
        if (![existing.serve want:ranges]) return NO;
        existing.lastActivity = SZFriendsCopyNow();
        existing.asks++;
        [self sendFollowOf:existing transfer:transferID onLink:link];
        [self pumpCopiesOnLink:link];
        return YES;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%llu|%ld.%09ld|%u", transferID, path, size,
                                               (long)info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, shift];
    NSArray<NSData *> *tree = SZFriendsCopyTrees()[key];
    if (tree == nil) {
        NSData *leaves = nil, *digest = nil;
        if (!SZFriendsHashFileTree(fd, geometry, &leaves, &digest) || leaves == nil) {
            close(fd);
            return NO;
        }
        NSData *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
        if (root == nil) {
            close(fd);
            return NO;
        }
        if (SZFriendsCopyTrees().count >= SZFriendsCopyTreesKept) [SZFriendsCopyTrees() removeAllObjects];
        tree = @[ leaves, root ];
        SZFriendsCopyTrees()[key] = tree;
    }
    SZFriendsBlockServe *serve = [[SZFriendsBlockServe alloc] initWithTransferID:wire geometry:geometry
                                                                          leaves:tree[0]
                                                                       partBytes:SZFriendsCopyPartBytes
                                                                     windowBytes:SZFriendsCopyWindowBytes];
    if (![serve want:ranges]) {
        close(fd);
        return NO;
    }
    SZFriendsCopyServe *served = [[SZFriendsCopyServe alloc] init];
    served->fd = fd;
    served.serve = serve;
    served.sync = sync;
    served.root = tree[1];
    served.size = size;
    served.lastActivity = SZFriendsCopyNow();
    served.startedAt = served.loggedAt = served.lastActivity;
    served.asks = 1;
    [self logServe:served transfer:transferID link:link what:@"starts"];
    if (link.servedCopies == nil) link.servedCopies = [NSMutableDictionary dictionary];
    link.servedCopies[transferID] = served;
    [self sendFollowOf:served transfer:transferID onLink:link];
    [self watchWritesOfLink:link];
    [self pumpCopiesOnLink:link];
    return YES;
}

// BLOCKS FOLLOW (AGAIN 5 or SYNC 8) with the file's tree, then its leaves.
- (void)sendFollowOf:(SZFriendsCopyServe *)served transfer:(NSString *)transferID onLink:(SZFriendsPeerLink *)link {
    uint8_t shift = served.serve.geometry.shift;
    if (served.sync) {
        NSData *follow = SZFriendsSyncBlocksFollow(transferID, served.root, shift);
        if (follow) [link.syncExchange sendServing:transferID message:follow];
    } else {
        NSData *follow = SZFriendsAgainBlocksFollow(transferID, served.root, shift);
        if (follow) {
            [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAgain
                                                          fields:@{@(SZFriendsFieldAgain) : follow}]];
        }
    }
    for (SZFriendsFrame *frame in served.serve.hashesFrames) [link.channel sendFrame:frame];
}

// A file served by blocks on this link is done or given up: a friend's Get again slot is free again at once, and a
// copy to another of our computers is no longer shown as being copied.
- (void)endServe:(NSString *)transferID onLink:(SZFriendsPeerLink *)link {
    SZFriendsCopyServe *served = link.servedCopies[transferID];
    [link.servedCopies removeObjectForKey:transferID];
    if (served == nil) return;
    // A copy to another of our computers: the You row stops saying it is being copied from here.
    if (served.sync) [link.syncExchange finishedServing:transferID];
    else [link.againExchange finishedServing:transferID];
}

// Writes completing on the link pump the copies (after whatever else listens), and a tick does while any is served.
- (void)watchWritesOfLink:(SZFriendsPeerLink *)link {
    void (^before)(void) = link.channel.onWritten;
    __weak SZFriendsNearbyService *weakSelf = self;
    __weak SZFriendsPeerLink *weakLink = link;
    link.channel.onWritten = ^{
        if (before) before();
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink.servedCopies.count > 0) [weakSelf pumpCopiesOnLink:strongLink];
    };
    [self scheduleCopyTickOnLink:link];
}

- (void)scheduleCopyTickOnLink:(SZFriendsPeerLink *)link {
    if (link.servedCopiesTickScheduled || link.closed || link.servedCopies.count == 0) return;
    link.servedCopiesTickScheduled = YES;
    __weak SZFriendsPeerLink *weakLink = link;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsCopyTick * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsPeerLink *strongLink = weakLink;
        if (strongLink == nil) return;
        strongLink.servedCopiesTickScheduled = NO;
        [self pumpCopiesOnLink:strongLink];
        [self scheduleCopyTickOnLink:strongLink];
    });
}

// The next parts of what this link serves by blocks, while its bulk queue is shallow.
- (void)pumpCopiesOnLink:(SZFriendsPeerLink *)link {
    if (link.closed) {
        link.servedCopies = nil;
        return;
    }
    double now = SZFriendsCopyNow();
    for (NSString *transferID in link.servedCopies.allKeys) {
        SZFriendsCopyServe *served = link.servedCopies[transferID];
        SZFriendsBlockServe *serve = served.serve;
        // Quiet: every block asked for was acknowledged and nothing more came for a while, or a HAVE never came.
        BOOL done = serve.idle && !serve.awaitingHave && now - served.lastActivity >= SZFriendsCopyIdleEnd;
        BOOL stuck = serve.awaitingHave && now - served.lastActivity >= SZFriendsCopyHaveWait;
        if (done || stuck) {
            [self logServe:served transfer:transferID link:link
                      what:done ? @"ends, nothing more asked" : @"ends, no HAVE came"];
            [self endServe:transferID onLink:link];
            [self changed];
            continue;
        }
        if (now - served.loggedAt >= 2) [self logServe:served transfer:transferID link:link what:@"runs"];
        while (link.channel.queuedBulkFrames < SZFriendsCopyBulkDepth) {
            NSUInteger partLength = serve.nextPartLength;
            SZFriendsFrame *part = [serve nextPart];
            if (part != nil) {
                if (![link.channel sendFrame:part]) return;
                served.bytesSent += partLength;
                continue;
            }
            uint32_t block = 0;
            if (![serve nextBlock:&block]) break;
            uint64_t offset = 0;
            NSUInteger length = 0;
            SZFriendsGeometrySpan(serve.geometry, block, &offset, &length);
            NSMutableData *data = [NSMutableData dataWithLength:length];
            ssize_t got = length ? pread(served->fd, data.mutableBytes, length, (off_t)offset) : 0;
            if (got != (ssize_t)length || ![serve loadBlock:block data:data]) {
                // Changed or gone since it was checked: the other side hears it is gone.
                [self endServe:transferID onLink:link];
                if (served.sync) [link.syncExchange sendNone:transferID];
                else [link.againExchange sendNone:transferID reason:SZFriendsAgainAnswerNotHere];
                break;
            }
        }
    }
}

- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyFrame:(SZFriendsFrame *)frame {
    if ([self link:link receivedPullFrame:frame]) return YES; // a file pulled from several holders (+Pulls)
    NSString *again = link.againExchange.copyingByBlocks, *sync = link.syncExchange.copyingByBlocks;
    if (again == nil && sync == nil) return NO;
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire.length != 16) return NO;
    NSMutableString *transferID = [NSMutableString stringWithCapacity:32];
    for (NSUInteger i = 0; i < 16; i++) [transferID appendFormat:@"%02x", ((const uint8_t *)wire.bytes)[i]];
    BOOL handled = NO;
    if (frame.type == SZFriendsFrameTypeHashes) {
        NSData *index = [frame dataForTag:SZFriendsFieldIndex], *hashes = [frame dataForTag:SZFriendsFieldHashes];
        if (index.length != 4 || hashes == nil) return NO;
        const uint8_t *b = index.bytes;
        uint32_t first = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
        handled = [again isEqualToString:transferID]
                      ? [link.againExchange receiveHashes:hashes index:first forTransfer:transferID]
                      : [sync isEqualToString:transferID] &&
                            [link.syncExchange receiveHashes:hashes index:first forTransfer:transferID];
    } else {
        uint64_t offset = 0;
        NSData *data = [frame dataForTag:SZFriendsFieldData];
        if (![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || data == nil) return NO;
        handled = [again isEqualToString:transferID]
                      ? [link.againExchange receivePart:data offset:offset forTransfer:transferID]
                      : [sync isEqualToString:transferID] &&
                            [link.syncExchange receivePart:data offset:offset forTransfer:transferID];
    }
    if (handled) [self progressChanged];
    return handled;
}

- (BOOL)link:(SZFriendsPeerLink *)link receivedCopyHave:(SZFriendsFrame *)frame {
    if (link.servedCopies.count == 0) return NO;
    NSData *wire = [frame dataForTag:SZFriendsFieldID];
    if (wire.length != 16) return NO;
    NSMutableString *transferID = [NSMutableString stringWithCapacity:32];
    for (NSUInteger i = 0; i < 16; i++) [transferID appendFormat:@"%02x", ((const uint8_t *)wire.bytes)[i]];
    SZFriendsCopyServe *served = link.servedCopies[transferID];
    if (served == nil) return NO;
    NSData *ranges = SZFriendsFrameRanges(frame, SZFriendsFieldRanges);
    if (ranges != nil) [served.serve have:ranges];
    served.lastActivity = SZFriendsCopyNow();
    // The You row rises with what the other computer acknowledged.
    if (served.sync && served.size > 0) {
        [link.syncExchange servingProgress:transferID
                                  fraction:(double)served.serve.acknowledgedBytes / (double)served.size];
        [self progressChanged];
    }
    if (served.serve.allAcknowledged) {
        [self logServe:served transfer:transferID link:link what:@"ends, every block asked acknowledged"];
        [self endServe:transferID onLink:link];
    }
    [self pumpCopiesOnLink:link];
    return YES;
}

@end
