// Single instance per Mac user: an exclusive, non-blocking flock on <state dir>/helper.lock (ADR 0002).
//
// WHY flock rather than a pid file or "is the socket answering": the kernel drops the lock on any exit, SIGKILL
// included, so a stale lock cannot exist, and two helpers racing from twenty windows cannot both win.

#import "service/helper/SZFriendsHelperInternal.h"

#import <errno.h>
#import <fcntl.h>
#import <sys/file.h>
#import <unistd.h>

@implementation SZFriendsInstanceLock {
    int _fd;
}

- (instancetype)init {
    // -1, not the zero an ivar starts as: dealloc must never close descriptor 0.
    if ((self = [super init])) _fd = -1;
    return self;
}

+ (nullable instancetype)acquireAtPath:(NSString *)path error:(NSError **)error {
    // O_CLOEXEC so nothing the helper might ever start inherits the lock and outlives it holding it.
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return nil;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int saved = errno;
        close(fd);
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:saved userInfo:nil];
        return nil;
    }
    SZFriendsInstanceLock *lock = [[self alloc] init];
    lock->_fd = fd;
    return lock;
}

- (void)releaseLock {
    if (_fd >= 0) {
        flock(_fd, LOCK_UN);
        close(_fd);
        _fd = -1;
    }
}

- (void)dealloc {
    [self releaseLock];
}

@end
