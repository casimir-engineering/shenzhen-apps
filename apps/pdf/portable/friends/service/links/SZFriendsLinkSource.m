// What a download link serves (SZFriendsLinksInternal.h): the file fixed when the link is made, at any size. An
// APFS clone of the exact bytes where the volume makes one (no extra space; later edits never reach it), otherwise the
// original, served only while its size and dates are what they were, or its SHA-256 still matches
// (friends-links.md § Rules).

#import "service/links/SZFriendsLinksInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

#import <sodium.h>

#import "service/store/SZFriendsStore.h"

BOOL SZFriendsLinkClonesRefused = NO;

static const size_t SZFriendsLinkHashBlock = 1 << 20;

static int64_t SZFriendsLinkNanoseconds(struct timespec time) {
    return (int64_t)time.tv_sec * 1000000000 + time.tv_nsec;
}

static NSError *SZFriendsLinkSourceError(SZFriendsStoreError code, NSString *why) {
    return [NSError errorWithDomain:SZFriendsStoreErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : why}];
}

// SHA-256 and BLAKE2b-256 of the whole file at `fd`, and its length as read.
static BOOL SZFriendsLinkHash(int fd, uint64_t *length, NSData **sha256, NSData **blake2b) {
    crypto_hash_sha256_state sha;
    crypto_generichash_state blake;
    crypto_hash_sha256_init(&sha);
    crypto_generichash_init(&blake, NULL, 0, 32);
    uint8_t *buffer = malloc(SZFriendsLinkHashBlock);
    uint64_t total = 0;
    ssize_t got = 0;
    while (buffer && (got = read(fd, buffer, SZFriendsLinkHashBlock)) > 0) {
        crypto_hash_sha256_update(&sha, buffer, (unsigned long long)got);
        crypto_generichash_update(&blake, buffer, (unsigned long long)got);
        total += (uint64_t)got;
    }
    free(buffer);
    if (buffer == NULL || got < 0) return NO;
    NSMutableData *first = [NSMutableData dataWithLength:32], *second = [NSMutableData dataWithLength:32];
    crypto_hash_sha256_final(&sha, first.mutableBytes);
    crypto_generichash_final(&blake, second.mutableBytes, 32);
    *length = total;
    *sha256 = first;
    *blake2b = second;
    return YES;
}

SZFriendsDownloadLinkRecord *SZFriendsLinkHoldFile(NSString *path, NSString *clonePath, NSError **error) {
    struct stat info;
    // A symbolic link is followed, to what it names now, like any file the person picks.
    if (stat(path.fileSystemRepresentation, &info) != 0) {
        if (error) *error = SZFriendsLinkSourceError(SZFriendsStoreErrorFileMissing, @"no such file");
        return nil;
    }
    if (S_ISDIR(info.st_mode)) {
        if (error) *error = SZFriendsLinkSourceError(SZFriendsStoreErrorFolderNotSupported, @"a folder");
        return nil;
    }
    SZFriendsDownloadLinkRecord *link = [[SZFriendsDownloadLinkRecord alloc] init];
    BOOL cloned = !SZFriendsLinkClonesRefused &&
                  clonefile(path.fileSystemRepresentation, clonePath.fileSystemRepresentation, 0) == 0;
    NSString *served = cloned ? clonePath : path;
    int fd = open(served.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    struct stat held;
    if (fd < 0 || fstat(fd, &held) != 0 || !S_ISREG(held.st_mode)) {
        if (fd >= 0) close(fd);
        if (cloned) unlink(clonePath.fileSystemRepresentation);
        if (error) *error = SZFriendsLinkSourceError(SZFriendsStoreErrorFileMissing, @"not a readable file");
        return nil;
    }
    if (cloned) {
        fchmod(fd, 0600);
        link.snapshotPath = clonePath;
    } else {
        link.sourcePath = path;
        link.sourceModifiedNanoseconds = SZFriendsLinkNanoseconds(held.st_mtimespec);
        link.sourceChangedNanoseconds = SZFriendsLinkNanoseconds(held.st_ctimespec);
        link.sourceInode = held.st_ino;
        link.sourceDevice = held.st_dev;
    }
    uint64_t length = 0;
    NSData *sha256 = nil, *blake2b = nil;
    BOOL hashed = SZFriendsLinkHash(fd, &length, &sha256, &blake2b);
    close(fd);
    // An original that changed while it was read is not what anyone can promise to serve.
    if (!hashed || (!cloned && length != (uint64_t)held.st_size)) {
        if (cloned) unlink(clonePath.fileSystemRepresentation);
        if (error) *error = SZFriendsLinkSourceError(SZFriendsStoreErrorSourceChanged, @"changed while read");
        return nil;
    }
    link.size = length;
    link.sha256 = sha256;
    link.blake2b = blake2b;
    return link;
}

NSString *SZFriendsLinkServedPath(SZFriendsDownloadLinkRecord *link) {
    return link.snapshotPath ?: link.sourcePath;
}

BOOL SZFriendsLinkSourceUnchanged(SZFriendsDownloadLinkRecord *link) {
    NSString *path = SZFriendsLinkServedPath(link);
    struct stat info;
    if (path == nil || stat(path.fileSystemRepresentation, &info) != 0 || !S_ISREG(info.st_mode) ||
        (uint64_t)info.st_size != link.size) {
        return NO;
    }
    if (link.snapshotPath != nil) return YES; // a clone nobody else can reach: its bytes are the link's
    if (SZFriendsLinkNanoseconds(info.st_mtimespec) != link.sourceModifiedNanoseconds) return NO;
    // Same size and modification date. Writing a file always moves its change time, so with the same inode and
    // change time the bytes are the ones hashed; otherwise (a copy put back, a changed attribute) the hash decides.
    if (info.st_ino == link.sourceInode && info.st_dev == link.sourceDevice &&
        SZFriendsLinkNanoseconds(info.st_ctimespec) == link.sourceChangedNanoseconds) {
        return YES;
    }
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return NO;
    uint64_t length = 0;
    NSData *sha256 = nil, *blake2b = nil;
    BOOL same = SZFriendsLinkHash(fd, &length, &sha256, &blake2b) && length == link.size &&
                [sha256 isEqualToData:link.sha256];
    close(fd);
    return same;
}

void SZFriendsLinkReleaseFile(SZFriendsDownloadLinkRecord *link, NSString *linksDirectory) {
    NSString *clone = link.snapshotPath;
    // Only a clone this helper made, in its own directory: a path from a row is never trusted to point elsewhere.
    if (clone == nil || ![clone.stringByDeletingLastPathComponent isEqualToString:linksDirectory]) return;
    unlink(clone.fileSystemRepresentation);
}
