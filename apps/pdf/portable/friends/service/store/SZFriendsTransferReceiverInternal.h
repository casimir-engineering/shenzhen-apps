// Shared by SZFriendsTransferReceiver.m (chunks written and published) and SZFriendsTransferReceiver+Recovery.m (what a
// restart finds): the receiver's state and the staged-file checks both use.

#import <fcntl.h>
#import <sodium.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

static const uint64_t SZFriendsDurableBatchBytes = 4ULL << 20;
static const NSTimeInterval SZFriendsDurableBatchInterval = 1.0;

// One download in progress: its open staging file, running digest and how much of it is written versus durable.
@interface SZFriendsReceiving : NSObject {
@public
    crypto_generichash_state hash;
    int fd;
    uint64_t written;
    uint64_t durable;
}
@property(nonatomic, copy) NSString *partialPath;
@property(nonatomic, copy) NSDate *lastCommit;
@end

static inline NSError *SZFriendsReceiveError(SZFriendsStoreError code, NSString *why) {
    return SZFriendsStoreMakeError(code, why);
}

static inline BOOL SZFriendsHashPrefix(int fd, uint64_t length, crypto_generichash_state *state);

// The file about to be published, read back through the descriptor that wrote it: still the file the staging path
// names, a regular file of the offered size, hashing to the offered digest. The streamed digest only covers bytes as
// they arrived; this is what makes a published file always match its verified digest, even if something else wrote
// to the staging file meanwhile (security review: two transfers once shared one file and published a corrupted copy
// as verified). It costs one read of the file on the store queue, once per received file.
static inline BOOL SZFriendsStagedFileMatches(int fd, NSString *path, SZFriendsTransferRecord *record) {
    struct stat opened, named;
    if (record.contentDigest.length != 32 || fstat(fd, &opened) != 0 ||
        lstat(path.fileSystemRepresentation, &named) != 0) {
        return NO;
    }
    if (!S_ISREG(named.st_mode) || opened.st_dev != named.st_dev || opened.st_ino != named.st_ino ||
        (uint64_t)opened.st_size != record.size) {
        return NO;
    }
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, 32);
    if (!SZFriendsHashPrefix(fd, record.size, &state)) return NO;
    uint8_t disk[32];
    crypto_generichash_final(&state, disk, sizeof disk);
    return sodium_memcmp(disk, record.contentDigest.bytes, 32) == 0;
}

static inline BOOL SZFriendsStagedFileMatchesAtPath(NSString *path, SZFriendsTransferRecord *record) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    BOOL matches = SZFriendsStagedFileMatches(fd, path, record);
    close(fd);
    return matches;
}

static inline BOOL SZFriendsHashPrefix(int fd, uint64_t length, crypto_generichash_state *state) {
    uint8_t buffer[64 * 1024];
    uint64_t offset = 0;
    while (offset < length) {
        size_t want = (size_t)MIN((uint64_t)sizeof buffer, length - offset);
        ssize_t got = pread(fd, buffer, want, (off_t)offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return NO;
        crypto_generichash_update(state, buffer, (unsigned long long)got);
        offset += (uint64_t)got;
    }
    return YES;
}

@interface SZFriendsTransferReceiver () {
    SZFriendsStore *_store;
    NSString *_stateDirectory;
    NSString *_receivedDirectory;
    NSString *_partialDirectory;
    NSMutableDictionary<NSString *, SZFriendsReceiving *> *_open; // touched only on the store queue
    NSMutableDictionary<NSString *, id> *_blockDownloads;          // the same (SZFriendsBlockDownloads.m)
}
- (nullable SZFriendsReceiving *)openIn:(SZFriendsStoreDB *)db
                                 record:(SZFriendsTransferRecord *)record
                                  error:(NSError **)error;
- (BOOL)commit:(SZFriendsReceiving *)receiving transfer:(NSString *)transferID db:(SZFriendsStoreDB *)db
         error:(NSError **)error;
- (nullable SZFriendsTransferRecord *)receivingRecord:(SZFriendsStoreDB *)db
                                           transferID:(NSString *)transferID
                                         conversation:(NSString *)conversationID
                                                error:(NSError **)error;
- (BOOL)markReceived:(NSString *)transferID at:(NSString *)finalPath size:(uint64_t)size db:(SZFriendsStoreDB *)db
               error:(NSError **)error;
@end

@interface SZFriendsTransferReceiver (Recovery)
- (BOOL)recoverPublishingIn:(SZFriendsStoreDB *)db error:(NSError **)error;
- (BOOL)recoverReceivingIn:(SZFriendsStoreDB *)db error:(NSError **)error;
- (BOOL)removeOrphansIn:(SZFriendsStoreDB *)db error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
