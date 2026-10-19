// Shared helpers for the store suite.

#import <fcntl.h>
#import <poll.h>
#import <signal.h>
#import <sodium.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

NS_ASSUME_NONNULL_BEGIN

int SZFTFailures = 0;
NSString *SZFTFixturesDirectory = @"";
static NSString *SZFTRoot;

NSString *SZFTTemporaryDirectory(NSString *label) {
    if (!SZFTRoot) {
        NSString *template = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szf-store.XXXXXX"];
        char *path = strdup(template.fileSystemRepresentation);
        SZFTRoot = mkdtemp(path) ? @(path) : template;
        free(path);
    }
    NSString *directory = [SZFTRoot stringByAppendingPathComponent:
                                        [NSString stringWithFormat:@"%@-%@", label, SZFriendsNewIdentifier()]];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    return directory;
}

void SZFTRemoveTemporaryRoot(void) {
    if (SZFTRoot) [NSFileManager.defaultManager removeItemAtPath:SZFTRoot error:NULL];
    SZFTRoot = nil;
}

SZFriendsStore *_Nullable SZFTOpenStoreWithOptions(NSString *directory, SZFriendsStoreOptions *_Nullable options,
                                                  NSError *_Nullable *_Nullable error) {
    return [SZFriendsStore storeInDirectory:directory options:options error:error];
}

SZFriendsStore *SZFTOpenStore(NSString *directory) {
    NSError *error = nil;
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:directory error:&error];
    if (!store) {
        fprintf(stderr, "cannot open store in %s: %s\n", directory.UTF8String, error.localizedDescription.UTF8String);
        exit(1);
    }
    return store;
}

NSData *SZFTBytes(uint8_t value, NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    memset(data.mutableBytes, value, length);
    return data;
}

SZFriendsPersonRecord *SZFTAddPerson(SZFriendsStore *store, NSString *conversationID, uint8_t keyByte,
                                     SZFriendsRelation relation, NSTimeInterval interaction) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = conversationID;
    person.identityKey = SZFTBytes(keyByte, 32);
    person.staticKey = SZFTBytes((uint8_t)(keyByte + 1), 32);
    person.name = [@"Person " stringByAppendingString:conversationID];
    person.relation = relation;
    person.lastInteractionAt = [NSDate dateWithTimeIntervalSince1970:interaction];
    NSError *error = nil;
    if (![store savePerson:person error:&error]) {
        fprintf(stderr, "cannot save person: %s\n", error.localizedDescription.UTF8String);
        exit(1);
    }
    return person;
}

SZFriendsItemRecord *SZFTMessage(NSString *conversationID, NSString *itemID, NSString *_Nullable text,
                                 NSTimeInterval sentAt,
                                 SZFriendsDirection direction) {
    SZFriendsItemRecord *item = [[SZFriendsItemRecord alloc] init];
    item.conversationID = conversationID;
    item.itemID = itemID;
    item.kind = SZFriendsItemKindMessage;
    item.direction = direction;
    item.text = text;
    item.sentAt = [NSDate dateWithTimeIntervalSince1970:sentAt];
    item.receivedAt = item.sentAt;
    return item;
}

id _Nullable SZFTScalar(SZFriendsStore *store, NSString *sql, NSArray *binds) {
    __block id value = nil;
    [store performOnWriter:^(SZFriendsStoreDB *_Nullable db) { value = [db scalar:sql binds:binds error:NULL]; }];
    return value;
}

NSData *SZFTBlake2b(NSData *data) {
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, data.bytes, data.length, NULL, 0);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

NSData *SZFTRandomData(NSUInteger length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    arc4random_buf(data.mutableBytes, length);
    return data;
}

BOOL SZFTFileContains(NSString *path, NSData *needle) {
    NSData *contents = [NSData dataWithContentsOfFile:path];
    if (!contents.length || !needle.length) return NO;
    return [contents rangeOfData:needle options:0 range:NSMakeRange(0, contents.length)].location != NSNotFound;
}

NSUInteger SZFTFileMode(NSString *path) {
    struct stat info;
    if (lstat(path.fileSystemRepresentation, &info) != 0) return 0;
    return info.st_mode & 0777;
}

pid_t SZFTSpawnChild(NSString *mode, NSString *directory, int *readFD) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC); // only the write end reaches the child
    NSString *executable = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments[0];
    // Everything the child needs is prepared before fork: between fork and exec only async-signal-safe calls run,
    // so the child never touches the Objective-C runtime of the parent's image.
    char *argv[] = {strdup(executable.fileSystemRepresentation), strdup("--child"), strdup(mode.UTF8String),
                    strdup(directory.fileSystemRepresentation),
                    strdup([NSString stringWithFormat:@"%d", fds[1]].UTF8String), NULL};
    pid_t pid = fork();
    if (pid == 0) {
        execv(argv[0], argv);
        _exit(127);
    }
    for (int i = 0; argv[i]; i++) free(argv[i]);
    close(fds[1]);
    *readFD = fds[0];
    return pid;
}

BOOL SZFTWaitForLine(int fd, NSString *line, NSTimeInterval timeout, NSMutableArray<NSString *> *_Nullable lines) {
    NSMutableData *pending = [NSMutableData data];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        int wait = (int)MAX(0, [deadline timeIntervalSinceNow] * 1000);
        if (wait == 0) return NO;
        struct pollfd poller = {.fd = fd, .events = POLLIN};
        if (poll(&poller, 1, wait) <= 0) continue;
        uint8_t buffer[512];
        ssize_t got = read(fd, buffer, sizeof buffer);
        if (got <= 0) return NO; // the child exited without saying it
        [pending appendBytes:buffer length:(NSUInteger)got];
        while (YES) {
            NSRange newline = [pending rangeOfData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding] options:0
                                             range:NSMakeRange(0, pending.length)];
            if (newline.location == NSNotFound) break;
            NSString *text = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, newline.location)]
                                                   encoding:NSUTF8StringEncoding] ?: @"";
            [pending replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            [lines addObject:text];
            if ([text isEqualToString:line]) return YES;
        }
    }
}

void SZFTKillChild(pid_t pid) {
    if (pid <= 0) return;
    kill(pid, SIGKILL);
    int status = 0;
    waitpid(pid, &status, 0);
}

void SZFTTell(int fd, NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    write(fd, data.bytes, data.length);
}

NS_ASSUME_NONNULL_END
