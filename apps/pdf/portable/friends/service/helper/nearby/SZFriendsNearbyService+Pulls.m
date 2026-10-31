// One file pulled from every device that holds it at once (ADR 0018 § 9.6), as the Rust helper's service/pulls.rs:
// Get again from a friend's devices (AGAIN 4 and 5), and a copy from the person's own devices (SYNC 7 and 8) together
// with the friend who sent the file. WP6's planner (SZFriendsPull) gives each holder blocks by its measured speed; this
// file asks for them, takes what arrives into one copy by blocks (SZFriendsBlockCopy, which resumes from its map after
// a cut or a restart), and drops a holder that leaves, whose blocks the others then serve.
//
// Holders must hold the same file: each serves only after checking its bytes against the file's digest (a stale
// version is answered NONE), and one whose tree differs from the copy's is not asked again. Only on sessions that
// negotiated fast transfers; on others the per-session requesters copy as before, from one holder, by offset.

#import <time.h>

#import "service/helper/nearby/SZFriendsNearbyDevices.h"
#import "service/helper/nearby/SZFriendsNearbyInternal.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/sync/SZFriendsSync.h"
#import "service/transfer/SZFriendsBlockCopy.h"
#import "service/transfer/SZFriendsPull.h"

// A file no holder could give is tried again after this long.
static const NSTimeInterval SZFriendsPullNotNow = 5;
// The pull's timers (silent holders, the endgame), and how often a copy running by itself looks for a Get again.
static const NSTimeInterval SZFriendsPullTick = 0.25;

static double SZFriendsPullNow(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

// One device a pull asks: by AGAIN (the friend who sent the file) or by SYNC (another of the person's devices).
@interface SZFriendsPullHolder : NSObject
@property(nonatomic, weak) SZFriendsPeerLink *link;
@property(nonatomic) SZFriendsSourceID source;
@property(nonatomic) BOOL sync;
@property(nonatomic) SZFriendsRouteMethod route;
@property(nonatomic) BOOL up;  // its BLOCKS FOLLOW named the copy's tree: it serves
@property(nonatomic) BOOL out; // it answered NONE, or its tree is not the copy's: not asked again in this pull
@property(nonatomic) uint32_t delivered;
@end
@implementation SZFriendsPullHolder
@end

@interface SZFriendsPullCopy : NSObject
@property(nonatomic, copy) NSString *transferID;
@property(nonatomic, strong, nullable) SZFriendsAgainFile *again;   // Get again
@property(nonatomic, strong, nullable) SZFriendsSyncFileRecord *own; // a copy from the person's own devices
@property(nonatomic, copy, nullable) NSString *friendConversation;   // the friend who sent it, who may give it too
@property(nonatomic) uint64_t size;
@property(nonatomic, strong) SZFriendsBlockCopy *blockCopy;
@property(nonatomic, strong, nullable) SZFriendsPull *pull;
@property(nonatomic, copy, nullable) NSData *root;
@property(nonatomic) uint8_t shift;
@property(nonatomic, strong) NSMutableArray<SZFriendsPullHolder *> *holders;
@property(nonatomic) uint32_t probes; // blocks asked before the tree was known, one per holder
@end
@implementation SZFriendsPullCopy
@end

static uint64_t SZFriendsNextPullSource = 0;

// The `n`th block of `ranges` (wrapping), so each holder's first ask is a different block.
static uint32_t SZFriendsNthBlock(NSData *ranges, uint32_t n) {
    const uint32_t *pairs = ranges.bytes;
    uint64_t total = 0;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) total += pairs[2 * i + 1];
    if (total == 0) return 0;
    uint64_t left = n % total;
    for (NSUInteger i = 0; i < ranges.length / 8; i++) {
        if (left < pairs[2 * i + 1]) return pairs[2 * i] + (uint32_t)left;
        left -= pairs[2 * i + 1];
    }
    return 0;
}

@implementation SZFriendsNearbyService (Pulls)

- (BOOL)pullsOnLink:(SZFriendsPeerLink *)link {
    return link.live && !link.closed && !link.superseded && !link.lane && link.channel.fastTransfers;
}

- (nullable SZFriendsPullCopy *)currentPull {
    return self.pullCurrent;
}

- (NSUInteger)holdersServingTransfer:(NSString *)transferID own:(NSUInteger *)own {
    SZFriendsPullCopy *current = self.currentPull;
    NSUInteger serving = 0, ours = 0;
    if ([current.transferID isEqualToString:transferID]) {
        for (SZFriendsPullHolder *holder in current.holders) {
            if (!holder.up || holder.out) continue;
            serving++;
            if (holder.sync) ours++;
        }
    }
    if (own) *own = ours;
    return serving;
}

- (void)schedulePullReconsider {
    if (self.pullReconsiderScheduled || self.shutDown) return;
    self.pullReconsiderScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsPullTick * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        strongSelf.pullReconsiderScheduled = NO;
        [strongSelf reconsiderPulls];
    });
}

- (void)reconsiderPulls {
    if (self.shutDown) return;
    [self dropUnwantedPull];
    [self preemptForAsked];
    if (self.currentPull == nil) [self startPull];
    [self attachHolders];
    [self drivePull];
    [self schedulePullTick];
}

// The pull's timers while it runs, and files waiting to be tried again.
- (void)schedulePullTick {
    if (self.pullTickScheduled || (self.currentPull == nil && self.pullNotBefore.count == 0)) return;
    self.pullTickScheduled = YES;
    __weak SZFriendsNearbyService *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SZFriendsPullTick * NSEC_PER_SEC)), self.queue, ^{
        SZFriendsNearbyService *strongSelf = weakSelf;
        strongSelf.pullTickScheduled = NO;
        [strongSelf reconsiderPulls];
    });
}

#pragma mark - What to pull

- (BOOL)pullWaiting:(NSString *)transferID {
    NSDate *until = self.pullNotBefore[transferID];
    if (until != nil && until.timeIntervalSinceNow <= 0) {
        [self.pullNotBefore removeObjectForKey:transferID];
        return NO;
    }
    return until != nil;
}

// A Get again the person asked a friend for, with the friend's conversation.
- (nullable SZFriendsAgainFile *)againCandidate:(NSString *_Nullable *_Nullable)conversation {
    for (SZFriendsPeerLink *link in self.links) {
        if (![self pullsOnLink:link] || link.ownDevice || link.conversationID == nil || !link.adopted) continue;
        for (SZFriendsAgainFile *file in [self againFilesWantedInConversation:link.conversationID]) {
            if ([self pullWaiting:file.transferID]) continue;
            if (conversation) *conversation = link.conversationID;
            return file;
        }
    }
    return nil;
}

// The first copy from the person's own devices that a live fast session with a holder can give.
- (nullable SZFriendsSyncFileRecord *)ownCandidate {
    SZFriendsSyncEngine *engine = self.syncEngine;
    if (engine == nil || !engine.active) return nil;
    for (SZFriendsSyncFileRecord *file in [engine filesWanted]) {
        if ([self pullWaiting:file.transferID]) continue;
        for (SZFriendsPeerLink *link in self.syncLinkTable.allValues) {
            if ([self pullsOnLink:link] && link.syncExchange != nil &&
                [file.holders containsObject:link.syncExchange.peerKey]) {
                return file;
            }
        }
    }
    return nil;
}

// Cancel (Get again, or Get) stopped the file being pulled, and nobody waits on it any more: the pull stops, what
// arrived stays in its map, and its holders hear a HAVE of every block, so they stop and their rows clear at once.
- (void)dropUnwantedPull {
    SZFriendsPullCopy *current = self.currentPull;
    if (current == nil) return;
    BOOL wanted = current.again != nil ? [self againStateOfTransfer:current.transferID] == SZFriendsAgainAsked
                                       : [[self.syncEngine.filesWanted valueForKey:@"transferID"]
                                             containsObject:current.transferID];
    if (wanted) return;
    [self stopHoldersOf:current];
    [current.blockCopy pause];
    self.pullCurrent = nil;
    [self changed];
}

// A Get again the person asked for, waiting behind a copy that runs by itself: the copy steps aside (what arrived
// stays in its map, its holders stop) and is pulled again afterwards. Looked at four times a second.
- (void)preemptForAsked {
    SZFriendsPullCopy *current = self.currentPull;
    if (current.own == nil || [self.syncEngine isFileRequested:current.transferID]) return;
    if (self.pullCheckedAt != nil && -self.pullCheckedAt.timeIntervalSinceNow < SZFriendsPullTick) return;
    self.pullCheckedAt = [NSDate date];
    if ([self againCandidate:NULL] == nil) return;
    [self stopHoldersOf:current];
    [current.blockCopy pause];
    self.pullCurrent = nil;
    [self changed];
}

- (void)startPull {
    NSString *conversation = nil;
    SZFriendsAgainFile *again = [self againCandidate:&conversation];
    SZFriendsSyncFileRecord *own = again == nil ? [self ownCandidate] : nil;
    if (again == nil && own == nil) return;
    SZFriendsPullCopy *current = [[SZFriendsPullCopy alloc] init];
    current.transferID = again ? again.transferID : own.transferID;
    current.again = again;
    current.own = own;
    current.friendConversation = again ? conversation : (own.outgoing ? nil : own.conversationID);
    current.size = again ? again.size : own.size;
    NSString *partial = [self.services.transfers.receivedDirectory stringByAppendingPathComponent:@".partial"];
    [NSFileManager.defaultManager createDirectoryAtPath:partial withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSString *path = [partial stringByAppendingPathComponent:[@"pull-" stringByAppendingString:current.transferID]];
    current.blockCopy = [SZFriendsBlockCopy openWithSize:current.size digest:again ? again.digest : own.contentDigest
                                            partial:path];
    if (current.blockCopy == nil) return;
    current.holders = [NSMutableArray array];
    self.pullCurrent = current;
}

#pragma mark - Holders

- (nullable SZFriendsPullHolder *)holderOfLink:(SZFriendsPeerLink *)link {
    for (SZFriendsPullHolder *holder in self.currentPull.holders) {
        if (holder.link == link) return holder;
    }
    return nil;
}

// Every live session that can serve the file and is not asked yet gets its first WANT BLOCKS: one block, so it answers
// with its tree.
- (void)attachHolders {
    SZFriendsPullCopy *current = self.currentPull;
    if (current == nil) return;
    NSMutableArray<NSArray *> *found = [NSMutableArray array]; // (link, sync)
    if (current.own != nil) {
        for (SZFriendsPeerLink *link in self.syncLinkTable.allValues) {
            if ([self pullsOnLink:link] && link.syncExchange != nil &&
                [current.own.holders containsObject:link.syncExchange.peerKey]) {
                [found addObject:@[ link, @YES ]];
            }
        }
    }
    if (current.friendConversation != nil) {
        for (SZFriendsPeerLink *link in self.links) {
            if (![self pullsOnLink:link] || link.ownDevice || !link.adopted ||
                ![link.conversationID isEqualToString:current.friendConversation]) {
                continue;
            }
            if ([self againExchangeForLink:link] != nil) [found addObject:@[ link, @NO ]];
        }
    }
    for (NSArray *entry in found) {
        SZFriendsPeerLink *link = entry[0];
        if ([self holderOfLink:link] != nil) continue;
        SZFriendsPullHolder *holder = [[SZFriendsPullHolder alloc] init];
        holder.link = link;
        holder.source = ++SZFriendsNextPullSource;
        holder.sync = [entry[1] boolValue];
        holder.route = link.raceRoute;
        [current.holders addObject:holder];
        uint32_t probe = SZFriendsNthBlock(current.blockCopy.missing, current.probes++);
        [self askHolder:holder ranges:SZFriendsRange(probe, 1)];
    }
}

- (void)askHolder:(SZFriendsPullHolder *)holder ranges:(NSData *)ranges {
    SZFriendsPullCopy *current = self.currentPull;
    SZFriendsPeerLink *link = holder.link;
    if (link == nil || link.closed) return;
    uint8_t shift = current.blockCopy.shift;
    if (holder.sync) {
        NSData *message = SZFriendsSyncWantBlocks(current.transferID, shift, ranges);
        if (message) {
            [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeSync
                                                          fields:@{@(SZFriendsFieldSync) : message}]];
        }
    } else {
        NSData *message = SZFriendsAgainWantBlocks(current.transferID, shift, ranges);
        if (message) {
            [link.channel sendFrame:[SZFriendsFrame frameWithType:SZFriendsFrameTypeAgain
                                                          fields:@{@(SZFriendsFieldAgain) : message}]];
        }
    }
}

- (void)sendHave:(NSData *)ranges toHolder:(SZFriendsPullHolder *)holder {
    NSData *wire = SZFriendsLinkBytesFromHex(self.currentPull.transferID);
    if (wire == nil || holder.link == nil || holder.link.closed) return;
    for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, ranges, [NSData data])) [holder.link.channel sendFrame:frame];
}

// Every holder still serving hears that every block is here: it stops.
- (void)stopHoldersOf:(SZFriendsPullCopy *)current {
    SZFriendsBlockGeometry geometry;
    uint32_t blocks = SZFriendsGeometryMake(current.size, current.blockCopy.shift, &geometry) ? geometry.blocks : 1;
    NSData *wire = SZFriendsLinkBytesFromHex(current.transferID);
    for (SZFriendsPullHolder *holder in current.holders) {
        if (holder.out || holder.link == nil || holder.link.closed || wire == nil) continue;
        for (SZFriendsFrame *frame in SZFriendsHaveFrames(wire, SZFriendsRange(0, blocks), [NSData data])) {
            [holder.link.channel sendFrame:frame];
        }
    }
}

// The planner's decisions, sent: WANT BLOCKS to the holders it gave blocks, HAVE to those it took them from.
- (void)drivePull {
    SZFriendsPullCopy *current = self.currentPull;
    if (current.pull == nil) return;
    [current.pull tick:SZFriendsPullNow()];
    for (SZFriendsPullAction *action in [current.pull takeActions]) {
        for (SZFriendsPullHolder *holder in current.holders) {
            if (holder.source != action.source) continue;
            if (action.want) [self askHolder:holder ranges:action.ranges];
            else [self sendHave:action.ranges toHolder:holder];
        }
    }
}

#pragma mark - Answers and frames

- (BOOL)link:(SZFriendsPeerLink *)link pullAnswer:(NSString *)transferID root:(NSData *)root
       shift:(uint8_t)shift gone:(BOOL)gone {
    SZFriendsPullCopy *current = self.currentPull;
    SZFriendsPullHolder *holder = [current.transferID isEqualToString:transferID] ? [self holderOfLink:link] : nil;
    if (holder == nil) return NO;
    double now = SZFriendsPullNow();
    if (root == nil) {
        holder.out = YES;
        if (!holder.sync && gone && current.again != nil) {
            // The friend who sent it no longer has it: Get again ends, as from one holder.
            self.pullCurrent = nil;
            [self stopHoldersOf:current];
            SZFriendsRemoveCopy(current.blockCopy.partial);
            [self againFileNotThere:transferID];
            [self changed];
            [self schedulePullReconsider];
            return YES;
        }
        [current.pull sourceDown:holder.source now:now];
        BOOL anyLeft = NO;
        for (SZFriendsPullHolder *other in current.holders) anyLeft |= !other.out;
        if (!anyLeft) [self pullGivesUp];
    } else {
        if (current.root == nil && [current.blockCopy followRoot:root shift:shift]) {
            current.root = root;
            current.shift = shift;
        }
        if ([current.root isEqualToData:root] && current.shift == shift) {
            holder.up = YES;
            [current.pull sourceUp:holder.source route:holder.route now:now];
        } else {
            holder.out = YES; // another tree: not this file
        }
    }
    [self drivePull];
    [self progressChanged];
    return YES;
}

- (BOOL)link:(SZFriendsPeerLink *)link receivedPullFrame:(SZFriendsFrame *)frame {
    SZFriendsPullCopy *current = self.currentPull;
    if (current == nil) return NO;
    NSString *transferID = SZFriendsLinkHex([frame dataForTag:SZFriendsFieldID] ?: [NSData data]);
    if (![current.transferID isEqualToString:transferID]) return NO;
    SZFriendsPullHolder *holder = [self holderOfLink:link];
    if (holder == nil || !holder.up || holder.out) return NO;
    double now = SZFriendsPullNow();
    [current.pull heard:holder.source now:now];
    if (frame.type == SZFriendsFrameTypeHashes) {
        NSData *index = [frame dataForTag:SZFriendsFieldIndex], *hashes = [frame dataForTag:SZFriendsFieldHashes];
        const uint8_t *b = index.bytes;
        uint32_t first = index.length == 4
                             ? ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3]
                             : 0;
        BOOL done = NO;
        if (hashes == nil || ![current.blockCopy acceptHashes:hashes index:first done:&done]) {
            holder.out = YES;
            [current.pull sourceDown:holder.source now:now];
        } else if (current.blockCopy.leavesKnown && current.pull == nil) {
            // The tree is known: the planner starts with what is missing and every holder that serves it.
            SZFriendsBlockGeometry geometry;
            if (!SZFriendsGeometryMake(current.size, current.shift, &geometry)) return YES;
            current.pull = [[SZFriendsPull alloc] initWithGeometry:geometry missing:current.blockCopy.missing now:now];
            for (SZFriendsPullHolder *up in current.holders) {
                if (up.up && !up.out) [current.pull sourceUp:up.source route:up.route now:now];
            }
            if (current.blockCopy.complete) return [self pullComplete]; // every block was here already
        }
    } else if (frame.type == SZFriendsFrameTypePart) {
        uint64_t offset = 0;
        NSData *data = [frame dataForTag:SZFriendsFieldData];
        if (![frame getUInt64:&offset forTag:SZFriendsFieldOffset] || data == nil) return YES;
        uint32_t block = 0;
        switch ([current.blockCopy acceptPart:data offset:offset block:&block]) {
        case SZFriendsCopyPartWritten:
            holder.delivered++;
            [current.pull arrived:holder.source block:block now:now];
            [self sendHave:SZFriendsRange(block, 1) toHolder:holder]; // the holder's own window moves on its HAVE
            break;
        case SZFriendsCopyPartCorrupt: [current.pull failed:block now:now]; break;
        case SZFriendsCopyPartComplete: holder.delivered++; return [self pullComplete];
        case SZFriendsCopyPartPending:
        case SZFriendsCopyPartLate:
        case SZFriendsCopyPartRefused: break;
        }
    } else {
        return NO;
    }
    [self drivePull];
    [self progressChanged];
    return YES;
}

// Every block is here: the whole file checked against its digest, then kept; every holder hears to stop.
- (BOOL)pullComplete {
    SZFriendsPullCopy *current = self.currentPull;
    self.pullCurrent = nil;
    [self stopHoldersOf:current];
    NSMutableArray<NSString *> *shares = [NSMutableArray array];
    for (SZFriendsPullHolder *holder in current.holders) {
        [shares addObject:[NSString stringWithFormat:@"%@ %u%@", holder.sync ? @"own device" : @"friend",
                                                     holder.delivered, holder.out ? @" (out)" : @""]];
    }
    SZFriendsHelperLog(@"pulled a file from %lu holders, blocks each: %@", (unsigned long)current.holders.count,
                       [shares componentsJoinedByString:@", "]);
    NSString *path = [current.blockCopy finish];
    if (path == nil) {
        SZFriendsHelperLog(@"a file pulled from its holders did not check");
    } else if (current.again != nil) {
        [self adoptAgainCopy:current.again path:path];
    } else if (![self.syncEngine adoptCopiedFile:current.transferID atPath:path error:NULL]) {
        SZFriendsHelperLog(@"a file pulled from its holders could not be kept");
    }
    [self changed];
    [self schedulePullReconsider];
    return YES;
}

- (void)pullLinkClosed:(SZFriendsPeerLink *)link {
    SZFriendsPullCopy *current = self.currentPull;
    SZFriendsPullHolder *holder = [self holderOfLink:link];
    if (holder == nil) return;
    [current.holders removeObject:holder];
    [current.pull sourceDown:holder.source now:SZFriendsPullNow()];
    BOOL anyLeft = NO;
    for (SZFriendsPullHolder *other in current.holders) anyLeft |= !other.out;
    if (!anyLeft) [self pullGivesUp];
    [self drivePull];
}

// Nobody left to ask: what arrived waits in its map, and the file is tried again later.
- (void)pullGivesUp {
    SZFriendsPullCopy *current = self.currentPull;
    if (current == nil) return;
    if (self.pullNotBefore == nil) self.pullNotBefore = [NSMutableDictionary dictionary];
    self.pullNotBefore[current.transferID] = [NSDate dateWithTimeIntervalSinceNow:SZFriendsPullNotNow];
    [current.blockCopy pause];
    self.pullCurrent = nil;
    [self changed];
    [self schedulePullTick];
}

- (BOOL)pullFractionOfTransfer:(NSString *)transferID fraction:(double *)fraction {
    SZFriendsPullCopy *current = self.currentPull;
    if (![current.transferID isEqualToString:transferID]) return NO;
    if (fraction) *fraction = current.size > 0 ? (double)current.blockCopy.receivedBytes / (double)current.size : 0;
    return YES;
}

@end
