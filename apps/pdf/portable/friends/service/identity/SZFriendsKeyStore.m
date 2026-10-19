// The file key store and helpers shared by the identity area. Which store the helper picks is
// SZFriendsEnvironmentPolicy.m.

#import "service/identity/SZFriendsIdentityInternal.h"

#include <errno.h>
#include <fcntl.h>
#include <sodium.h>
#include <sys/stat.h>
#include <unistd.h>

NSErrorDomain const SZFriendsIdentityErrorDomain = @"SZFriendsIdentityErrorDomain";
NSString *const SZFriendsIdentitySecretName = @"identity";

// A real item is 133 bytes; anything far larger is not ours, and reading it whole would be pointless.
static const off_t SZFriendsKeyFileMaxBytes = 4096;

NSError *SZFriendsIdentityMakeError(SZFriendsIdentityError code, NSString *description, NSError *_Nullable underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying != nil) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:SZFriendsIdentityErrorDomain code:code userInfo:info];
}

void SZFriendsIdentityRequireSodium(void) {
    static int status;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ status = sodium_init(); });
    if (status < 0) [NSException raise:NSInternalInconsistencyException format:@"libsodium could not start"];
}

BOOL SZFriendsKeyStoreNameIsValid(NSString *name) {
    if (name.length == 0 || name.length > 64 || [name hasPrefix:@"."]) return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"] invertedSet];
    });
    return [name rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

static NSError *SZFErrno(int code) {
    return [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
}

@implementation SZFriendsFileKeyStore

- (instancetype)initWithDirectory:(NSString *)directory {
    if ((self = [super init])) _directory = [directory copy];
    return self;
}

- (NSString *)pathForName:(NSString *)name {
    return [_directory stringByAppendingPathComponent:name];
}

- (nullable NSData *)secretNamed:(NSString *)name error:(NSError **)error {
    if (error) *error = nil;
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable, @"Invalid key name.", nil);
        return nil;
    }
    // O_NOFOLLOW: a symbolic link planted in place of the key is refused, not followed to someone else's file.
    int fd = open([self pathForName:name].fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        int code = errno;
        if (code == ENOENT) return nil;
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable,
                                                       @"The key file exists but cannot be opened.", SZFErrno(code));
        return nil;
    }
    NSData *data = nil;
    NSString *problem = nil;
    struct stat info;
    if (fstat(fd, &info) != 0) {
        problem = @"The key file cannot be examined.";
    } else if (!S_ISREG(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 077) != 0) {
        // WHY refuse rather than use: a key others can read is no longer secret, and one they could have written
        // is not necessarily ours. Unavailable keeps the reset explicit.
        problem = @"The key file is not a private file owned by this user.";
    } else if (info.st_size > SZFriendsKeyFileMaxBytes) {
        problem = @"The key file is too large to be a Friends key.";
    } else {
        NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
        size_t done = 0;
        while (done < buffer.length) {
            ssize_t got = read(fd, (uint8_t *)buffer.mutableBytes + done, buffer.length - done);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) break;
            done += (size_t)got;
        }
        if (done == buffer.length) {
            data = buffer;
        } else {
            sodium_memzero(buffer.mutableBytes, buffer.length);
            problem = @"The key file could not be read completely.";
        }
    }
    close(fd);
    if (problem != nil && error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorUnavailable, problem, nil);
    return data;
}

- (BOOL)storeSecret:(NSData *)secret named:(NSString *)name error:(NSError **)error {
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, @"Invalid key name.", nil);
        return NO;
    }
    NSDictionary *attributes = @{NSFilePosixPermissions : @0700};
    NSError *directoryError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES
                                                    attributes:attributes error:&directoryError]) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
                                                       @"The key directory cannot be created.", directoryError);
        return NO;
    }
    NSString *finalPath = [self pathForName:name];
    SZFriendsIdentityRequireSodium(); // randombytes_random below
    NSString *temporary = [_directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@".%@.%u.partial", name, randombytes_random()]];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
                                                       @"The key file cannot be created.", SZFErrno(errno));
        return NO;
    }
    BOOL written = YES;
    size_t done = 0;
    while (written && done < secret.length) {
        ssize_t put = write(fd, (const uint8_t *)secret.bytes + done, secret.length - done);
        if (put < 0 && errno == EINTR) continue;
        if (put <= 0) written = NO; else done += (size_t)put;
    }
    // F_FULLFSYNC: the key must reach the disk before anyone is told about it, or a power cut after first start
    // could leave friends holding a key this Mac no longer has.
    if (written && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0) written = NO;
    int writeErrno = errno;
    close(fd);
    if (!written) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
                                                       @"The key file cannot be written.", SZFErrno(writeErrno));
        return NO;
    }
    // link(2) publishes the finished file atomically and, unlike rename(2), fails when the name exists, so an
    // existing key is never replaced.
    int linked = link(temporary.fileSystemRepresentation, finalPath.fileSystemRepresentation);
    int linkErrno = errno;
    unlink(temporary.fileSystemRepresentation);
    if (linked != 0) {
        NSString *why = linkErrno == EEXIST ? @"A key with this name already exists; it was not replaced."
                                            : @"The key file cannot be published.";
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, why, SZFErrno(linkErrno));
        return NO;
    }
    int directoryFD = open(_directory.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (directoryFD >= 0) {
        fsync(directoryFD);
        close(directoryFD);
    }
    return YES;
}

- (BOOL)deleteSecretNamed:(NSString *)name error:(NSError **)error {
    if (!SZFriendsKeyStoreNameIsValid(name)) {
        if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed, @"Invalid key name.", nil);
        return NO;
    }
    if (unlink([self pathForName:name].fileSystemRepresentation) == 0 || errno == ENOENT) return YES;
    if (error) *error = SZFriendsIdentityMakeError(SZFriendsIdentityErrorStoreFailed,
                                                   @"The key file cannot be deleted.", SZFErrno(errno));
    return NO;
}

@end
