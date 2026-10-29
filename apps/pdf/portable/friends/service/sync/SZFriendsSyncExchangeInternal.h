// Shared by SZFriendsSyncExchange.m (events) and SZFriendsSyncExchange+Files.m (files copied between the person's own
// computers): the exchange's state, its message kinds, and the helpers both use.

#import <sodium.h>

#import "service/sync/SZFriendsSyncInternal.h"
#import "service/sync/SZFriendsAgain.h"
#import "service/transfer/SZFriendsBlockCopy.h"

NS_ASSUME_NONNULL_BEGIN

static const uint16_t SZFriendsSyncCopyParts = 8;  // parts per WANT
static const uint16_t SZFriendsSyncCopyAhead = 16; // parts requested and not yet arrived, at most
static const NSUInteger SZFriendsSyncEventsPerMessage = 200;

typedef NS_ENUM(uint8_t, SZFriendsSyncMessage) {
    SZFriendsSyncMessageHello = 1,
    SZFriendsSyncMessageEvents = 2,
    SZFriendsSyncMessageAck = 3,
    SZFriendsSyncMessageWant = 4,
    SZFriendsSyncMessagePart = 5,
    SZFriendsSyncMessageNone = 6,
    SZFriendsSyncMessageWantBlocks = 7,
    SZFriendsSyncMessageBlocksFollow = 8,
};

// One file being copied from the peer.
@interface SZFriendsSyncCopy : NSObject
@property(nonatomic, copy) SZFriendsSyncFileRecord *file;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic) uint64_t received;
@property(nonatomic) uint64_t requested;
@property(nonatomic, strong, nullable) SZFriendsBlockCopy *blocks; // by blocks: `handle` is then unused
@end


static inline void SZFriendsSyncPutID(NSMutableData *data, NSString *transferID) {
    NSData *bytes = [transferID dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t length = (uint8_t)bytes.length;
    [data appendBytes:&length length:1];
    [data appendData:bytes];
}

// The transfer id at `*offset`, advancing it; nil when malformed.
static inline NSString *_Nullable SZFriendsSyncGetID(NSData *data, NSUInteger *offset) {
    const uint8_t *p = data.bytes;
    if (*offset >= data.length) return nil;
    NSUInteger length = p[*offset];
    if (length == 0 || length > 64 || *offset + 1 + length > data.length) return nil;
    NSString *transferID = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(*offset + 1, length)]
                                                 encoding:NSUTF8StringEncoding];
    *offset += 1 + length;
    return SZFriendsSyncLabelIsValid(transferID) && ![transferID containsString:@":"] &&
                   ![transferID containsString:@"/"]
               ? transferID
               : nil;
}

// A transfer id's 16 bytes, as session frames name it; nil unless 32 hex digits.
static inline NSData *_Nullable SZFriendsSyncHexBytes(NSString *transferID) {
    if (transferID.length != 32) return nil;
    NSMutableData *bytes = [NSMutableData dataWithLength:16];
    for (NSUInteger i = 0; i < 16; i++) {
        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[transferID substringWithRange:NSMakeRange(2 * i, 2)]];
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd) return nil;
        ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)value;
    }
    return bytes;
}

static inline BOOL SZFriendsSyncFileMatchesDigest(NSString *path, uint64_t size, NSData *digest) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) return NO;
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, 32);
    uint64_t total = 0;
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1024 * 1024];
            if (chunk.length == 0) break;
            total += chunk.length;
            crypto_generichash_update(&state, chunk.bytes, chunk.length);
        }
    }
    [handle closeFile];
    uint8_t computed[32];
    crypto_generichash_final(&state, computed, sizeof computed);
    return total == size && digest.length == 32 && sodium_memcmp(computed, digest.bytes, 32) == 0;
}

@interface SZFriendsSyncExchange () {
    SZFriendsSyncEngine *_engine;
    void (^_send)(NSData *message);
    NSMutableDictionary<NSData *, NSNumber *> *_sent; // what the peer has, or will once our EVENTS arrive
    SZFriendsSyncVector *_peerVector;                 // what the peer said it holds
    NSUInteger _outstanding;
    BOOL _stopped;
    SZFriendsSyncCopy *_copy;
    NSMutableSet<NSString *> *_unavailable;
    // The properties' own (SZFriendsSync.h), declared here so the files' category reaches them too.
    NSData *_peerKey;
    NSString *_Nullable _servingTransferID;
    double _servingFraction;
}
- (void)endCopy;
- (nullable SZFriendsSyncVector *)vectorIn:(NSData *)message from:(NSUInteger)offset;
- (void)learnPeerHolds:(SZFriendsSyncVector *)vector;
- (BOOL)receiveHello:(NSData *)message error:(NSError **)error;
- (BOOL)receiveAck:(NSData *)message error:(NSError **)error;
@end

@interface SZFriendsSyncExchange (Files)
- (void)startNextCopy;
- (void)requestMore;
- (BOOL)receiveWant:(NSData *)message error:(NSError **)error;
- (BOOL)receiveWantBlocks:(NSData *)message error:(NSError **)error;
- (BOOL)receiveBlocksFollow:(NSData *)message error:(NSError **)error;
- (void)sendHave;
- (void)stopBlocksCopy;
- (void)finishBlocksCopy;
- (BOOL)receivePart:(NSData *)message error:(NSError **)error;
- (BOOL)receiveNone:(NSData *)message error:(NSError **)error;
- (void)abandonCopy:(BOOL)discard;
@end

NS_ASSUME_NONNULL_END
