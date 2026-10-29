// File-level helpers for transfers: snapshots, digests, the quarantine attribute, private directories, free space.

#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <copyfile.h>
#import <fcntl.h>
#import <sodium.h>
#import <sys/attr.h>
#import <sys/clonefile.h>
#import <sys/mount.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"
#import "service/transfer/SZFriendsTransferBlocks.h"

NS_ASSUME_NONNULL_BEGIN

BOOL SZFriendsSnapshotDisableClone = NO;

// A copied snapshot must leave this much on the volume, so sending a file never fills the disk to the last byte.
static const uint64_t SZFriendsSnapshotMargin = 16ULL << 20;
static const size_t SZFriendsReadBuffer = 1 << 20;

static NSError *SZFriendsPOSIXError(SZFriendsStoreError code, NSString *what, int number) {
    return SZFriendsStoreMakeError(code, [NSString stringWithFormat:@"%@: %s", what, strerror(number)]);
}

BOOL SZFriendsSetQuarantine(NSString *path, NSError **error) {
    // Written directly rather than through NSURLQuarantinePropertiesKey, which also records an event in the user's
    // LaunchServices quarantine database; the attribute alone is what Gatekeeper checks when the file is opened.
    // Flags 0x0081 are a non-sandboxed downloader's (download, not yet approved), as browsers write them.
    NSString *value = [NSString stringWithFormat:@"0081;%08lx;Shenzhen Friends;%@",
                                                 (unsigned long)time(NULL), NSUUID.UUID.UUIDString];
    const char *bytes = value.UTF8String;
    if (setxattr(path.fileSystemRepresentation, "com.apple.quarantine", bytes, strlen(bytes), 0, XATTR_NOFOLLOW) != 0) {
        return SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorDatabase, @"quarantine", errno));
    }
    return YES;
}

NSData *_Nullable SZFriendsFileDigest(NSString *path, uint64_t length, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorFileMissing, path, errno));
        return nil;
    }
    crypto_generichash_state state;
    crypto_generichash_init(&state, NULL, 0, 32);
    uint8_t *buffer = malloc(SZFriendsReadBuffer);
    uint64_t remaining = length;
    BOOL ok = buffer != NULL;
    while (ok && remaining > 0) {
        size_t want = (size_t)MIN((uint64_t)SZFriendsReadBuffer, remaining);
        ssize_t got = read(fd, buffer, want);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) {
            ok = got == 0 && length == UINT64_MAX; // a short file cannot vouch for bytes it does not hold
            break;
        }
        crypto_generichash_update(&state, buffer, (unsigned long long)got);
        if (remaining != UINT64_MAX) remaining -= (uint64_t)got;
    }
    free(buffer);
    close(fd);
    if (!ok) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid, @"file shorter than expected"));
        return nil;
    }
    uint8_t digest[32];
    crypto_generichash_final(&state, digest, sizeof digest);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

uint64_t SZFriendsVolumeFreeBytes(NSString *path) {
    NSNumber *important = nil;
    NSURL *url = [NSURL fileURLWithPath:path];
    if ([url getResourceValue:&important forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:NULL] &&
        important.longLongValue > 0) {
        return important.unsignedLongLongValue;
    }
    struct statfs info;
    if (statfs(path.fileSystemRepresentation, &info) != 0) return 0;
    return (uint64_t)info.f_bavail * (uint64_t)info.f_bsize;
}

BOOL SZFriendsEnsurePrivateDirectory(NSString *path, NSError **error) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) {
        if (errno != ENOENT) return SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorDatabase, path, errno));
        if (![NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES
                                                      attributes:@{NSFilePosixPermissions : @0700} error:error]) {
            return NO;
        }
        if (lstat(path.fileSystemRepresentation, &info) != 0) {
            return SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorDatabase, path, errno));
        }
    }
    // A symlink here would let received or staged files land outside the state directory.
    if (S_ISLNK(info.st_mode) || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorInvalid,
                                                            [path stringByAppendingString:@" is not our directory"]));
    }
    return YES;
}

NSString *_Nullable SZFriendsCreateStagingFile(NSString *partialDirectory, NSError **error) {
    // 128 random bits make a clash practically impossible; EEXIST is retried rather than ever opening a file that
    // something else created, whatever it is.
    for (int attempt = 0; attempt < 4; attempt++) {
        NSString *name = [SZFriendsNewIdentifier() stringByAppendingString:@".part"];
        NSString *path = [partialDirectory stringByAppendingPathComponent:name];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0 && errno == EEXIST) continue;
        if (fd < 0) {
            int number = errno;
            SZFriendsStoreError code = number == ENOSPC ? SZFriendsStoreErrorDiskFull : SZFriendsStoreErrorDatabase;
            SZFriendsFail(error, SZFriendsPOSIXError(code, path, number));
            return nil;
        }
        close(fd);
        // Quarantined from the first byte, so the published file can never exist without the attribute.
        if (!SZFriendsSetQuarantine(path, error)) {
            unlink(path.fileSystemRepresentation);
            return nil;
        }
        return path;
    }
    SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"no free staging name"));
    return nil;
}

// One pass over the snapshot for every digest it needs, so a large file is read once.
static BOOL SZFriendsHashSnapshot(NSString *path, uint64_t *size, NSData *_Nullable *_Nonnull digest,
                                  NSData *_Nullable *_Nullable sha256, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorFileMissing, path, errno));
    crypto_generichash_state blake;
    crypto_generichash_init(&blake, NULL, 0, 32);
    CC_SHA256_CTX sha;
    CC_SHA256_Init(&sha);
    uint8_t *buffer = malloc(SZFriendsReadBuffer);
    uint64_t total = 0;
    BOOL ok = buffer != NULL;
    while (ok) {
        ssize_t got = read(fd, buffer, SZFriendsReadBuffer);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) ok = NO;
        if (got <= 0) break;
        crypto_generichash_update(&blake, buffer, (unsigned long long)got);
        if (sha256) CC_SHA256_Update(&sha, buffer, (CC_LONG)got);
        total += (uint64_t)got;
    }
    free(buffer);
    close(fd);
    if (!ok) return SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorFileMissing, @"snapshot read"));
    uint8_t blakeBytes[32], shaBytes[CC_SHA256_DIGEST_LENGTH];
    crypto_generichash_final(&blake, blakeBytes, sizeof blakeBytes);
    *digest = [NSData dataWithBytes:blakeBytes length:sizeof blakeBytes];
    if (sha256) {
        CC_SHA256_Final(shaBytes, &sha);
        *sha256 = [NSData dataWithBytes:shaBytes length:sizeof shaBytes];
    }
    *size = total;
    return YES;
}

// The source as one open descriptor on a regular file that is not a symlink. A drag or a file promise can leave
// the path pointing anywhere by the time the helper snapshots it (a sandboxed promise source may swap the file it
// wrote for a symlink to ~/Documents/tax.pdf after the drop was checked), so the path is resolved exactly once,
// without following a symlink, and everything after works on what that one resolution found (security review, file
// promises). The read check is open() itself rather than access(), which would resolve the path a second time.
static int SZFriendsOpenSnapshotSource(NSString *source, struct stat *info, NSError **error) {
    struct stat link;
    if (lstat(source.fileSystemRepresentation, &link) != 0) {
        SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorFileMissing, source, errno));
        return -1;
    }
    if (S_ISDIR(link.st_mode)) {
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorFolderNotSupported, source));
        return -1;
    }
    // A symlink is refused rather than followed: what it names is not the file that was dropped and checked.
    if (!S_ISREG(link.st_mode)) {
        NSString *why = [source stringByAppendingString:S_ISLNK(link.st_mode) ? @" is a symlink" : @" is not a file"];
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorFileMissing, why));
        return -1;
    }
    SZFriendsStoreTestPoint("snapshot.after_lstat");
    int fd = open(source.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        SZFriendsFail(error, SZFriendsPOSIXError(SZFriendsStoreErrorFileMissing, source, errno));
        return -1;
    }
    // The same file lstat saw: a swap in between, even for another regular file, is refused rather than raced.
    if (fstat(fd, info) != 0 || !S_ISREG(info->st_mode) || info->st_dev != link.st_dev ||
        info->st_ino != link.st_ino) {
        close(fd);
        SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorFileMissing,
                                                     [source stringByAppendingString:@" changed while opening"]));
        return -1;
    }
    SZFriendsStoreTestPoint("snapshot.after_open");
    return fd;
}

// The digest and the tree in one pass; NO (nothing written) when the file has no block geometry or cannot be read,
// and the plain digest pass runs instead.
static BOOL SZFriendsHashSnapshotWithTree(NSString *path, uint64_t *size, NSData *_Nullable *_Nonnull digest) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return NO;
    struct stat info;
    SZFriendsBlockGeometry geometry;
    NSData *leaves = nil, *hashed = nil;
    BOOL ok = fstat(fd, &info) == 0 && SZFriendsGeometryForSize((uint64_t)info.st_size, &geometry) &&
              SZFriendsHashFileTree(fd, geometry, &leaves, &hashed);
    close(fd);
    if (!ok) return NO;
    NSData *root = SZFriendsTreeRootOfLeaves(geometry, leaves);
    NSData *tree = SZFriendsSenderTreeEncode(geometry, root, hashed, leaves);
    NSString *treePath = [path stringByAppendingString:@".tree"];
    int out = open(treePath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (out >= 0) {
        // A cache: a short write leaves a sidecar that does not decode, and the tree is computed again when needed.
        if (write(out, tree.bytes, tree.length) != (ssize_t)tree.length) ftruncate(out, 0);
        close(out);
    }
    *size = geometry.size;
    *digest = hashed;
    return YES;
}

BOOL SZFriendsSnapshotFile(NSString *source, NSString *destination, uint64_t freeBytes, uint64_t *size,
                           NSData *_Nullable *_Nonnull digest, NSData *_Nullable *_Nullable sha256,
                           NSError **error) {
    struct stat info;
    int sourceFD = SZFriendsOpenSnapshotSource(source, &info, error);
    if (sourceFD < 0) return NO;
    unlink(destination.fileSystemRepresentation);
    // A clone costs no space and is immune to later edits of the source (copy-on-write); a copy is the fallback
    // across volumes. Both read from the descriptor, never the path again, so the bytes sent are the file checked
    // above; with no path left to follow, CLONE_NOFOLLOW and COPYFILE_NOFOLLOW_SRC are moot (the flag is passed so a
    // later switch back to clonefile() keeps it). The destination is created exclusively and never followed.
    BOOL cloned = !SZFriendsSnapshotDisableClone &&
                  fclonefileat(sourceFD, AT_FDCWD, destination.fileSystemRepresentation, CLONE_NOFOLLOW) == 0;
    if (!cloned) {
        if (freeBytes < (uint64_t)info.st_size || freeBytes - (uint64_t)info.st_size < SZFriendsSnapshotMargin) {
            close(sourceFD);
            NSError *full = SZFriendsStoreMakeError(SZFriendsStoreErrorDiskFull, @"no room for a snapshot");
            return SZFriendsFail(error, full);
        }
        int destinationFD = open(destination.fileSystemRepresentation,
                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        int number = destinationFD < 0 ? errno : 0;
        if (destinationFD >= 0 && fcopyfile(sourceFD, destinationFD, NULL, COPYFILE_DATA) != 0) number = errno;
        if (destinationFD >= 0) close(destinationFD);
        if (number != 0) {
            close(sourceFD);
            unlink(destination.fileSystemRepresentation);
            SZFriendsStoreError code = number == ENOSPC ? SZFriendsStoreErrorDiskFull : SZFriendsStoreErrorFileMissing;
            return SZFriendsFail(error, SZFriendsPOSIXError(code, source, number));
        }
    }
    close(sourceFD);
    chmod(destination.fileSystemRepresentation, 0600);
    // Without a revision to check, one pass gives the digest and the transfer tree's leaves on every core (ADR 0018
    // § 2): the tree is kept beside the snapshot (<snapshot>.tree), so an OFFER can announce it at once.
    if (sha256 == NULL && SZFriendsHashSnapshotWithTree(destination, size, digest)) return YES;
    if (!SZFriendsHashSnapshot(destination, size, digest, sha256, error)) {
        unlink(destination.fileSystemRepresentation);
        return NO;
    }
    return YES;
}

NSFileHandle *_Nullable SZFriendsOpenSnapshotForSending(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    fcntl(fd, F_RDAHEAD, 1);
    return [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES];
}

NSData *_Nullable SZFriendsReadSnapshotAt(NSFileHandle *snapshot, uint64_t offset, NSUInteger length) {
    uint8_t *bytes = malloc(MAX(length, (NSUInteger)1));
    if (bytes == NULL) return nil;
    NSUInteger done = 0;
    while (done < length) {
        ssize_t got = pread(snapshot.fileDescriptor, bytes + done, length - done, (off_t)(offset + done));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) {
            free(bytes);
            return nil;
        }
        done += (NSUInteger)got;
    }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

BOOL SZFriendsOrderWrites(int fd) {
    return fcntl(fd, F_BARRIERFSYNC) == 0 || fsync(fd) == 0;
}

BOOL SZFriendsMakeDurable(int fd) {
    return fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0;
}

void SZFriendsRemovePrivateFiles(NSString *stateDirectory, NSArray<NSString *> *paths) {
    // Both sides standardized the same way: stringByStandardizingPath also drops a leading /private, so comparing a
    // standardized path with a raw prefix would refuse every file under /private/var.
    NSString *outgoing = [[stateDirectory stringByAppendingPathComponent:@"outgoing"].stringByStandardizingPath
        stringByAppendingString:@"/"];
    NSString *partial = [[stateDirectory stringByAppendingPathComponent:@"received/.partial"].stringByStandardizingPath
        stringByAppendingString:@"/"];
    NSString *thumbnails = [[stateDirectory stringByAppendingPathComponent:@"thumbnails"].stringByStandardizingPath
        stringByAppendingString:@"/"];
    for (NSString *path in paths) {
        NSString *standard = path.stringByStandardizingPath;
        BOOL owned = [standard hasPrefix:outgoing] || [standard hasPrefix:partial] || [standard hasPrefix:thumbnails];
        if (owned && ![standard.lastPathComponent hasPrefix:@"."]) unlink(standard.fileSystemRepresentation);
    }
}

NSString *_Nullable SZFriendsUniformTypeForName(NSString *name) {
    NSString *extension = name.pathExtension;
    if (extension.length == 0) return nil;
    UTType *type = [UTType typeWithFilenameExtension:extension];
    // Dynamic identifiers ("dyn.ah62...") name nothing a receiving app recognises.
    return type.isDynamic ? nil : type.identifier;
}

NS_ASSUME_NONNULL_END
