// Every path the helper owns, derived from one state directory (SZFriendsHelper.h § State paths).

#import "service/helper/SZFriendsHelperInternal.h"

#import <errno.h>
#import <sys/stat.h>

#import "client/szfriends_client.h"

static NSString *const SZFriendsStatePathsErrorDomain = @"SZFriendsStatePaths";

@implementation SZFriendsStatePaths

+ (NSString *)defaultStateDirectoryWithEnvironment:(NSDictionary<NSString *, NSString *> *)env {
    // The rule of szfriends_default_state_dir(), applied to an explicit environment so callers (and tests) can
    // pass one; SZFriendsHelperUnitTests checks the two agree for the process environment.
    NSString *override = env[@SZFRIENDS_ENV_STATE_DIR];
    if (override.length > 0 && [override hasPrefix:@"/"]) return override;
    NSString *home = env[@"HOME"];
    if (![home hasPrefix:@"/"]) home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
}

- (instancetype)initWithStateDirectory:(NSString *)stateDirectory {
    if ((self = [super init])) {
        _stateDirectory = [stateDirectory copy];
        char socketPath[SZFRIENDS_PATH_CAP];
        bool fallback = false;
        // The client library computes the socket path for both sides, so helper and apps can never disagree.
        szfriends_status status =
            szfriends_socket_path(stateDirectory.fileSystemRepresentation, socketPath, sizeof(socketPath), &fallback);
        if (status == SZFRIENDS_OK) {
            _socketPath = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:socketPath
                                                                                       length:strlen(socketPath)];
        } else {
            // Left empty: -prepareDirectoriesWithError: reports it and the helper exits before binding.
            _socketPath = @"";
        }
        _socketDirectory = [_socketPath stringByDeletingLastPathComponent];
    }
    return self;
}

- (NSString *)pathNamed:(NSString *)name {
    return [self.stateDirectory stringByAppendingPathComponent:name];
}

- (NSString *)lockPath { return [self pathNamed:@"helper.lock"]; }
- (NSString *)keysDirectory { return [self pathNamed:@"keys"]; }
- (NSString *)picturesDirectory { return [self pathNamed:@"pictures"]; }
- (NSString *)outgoingDirectory { return [self pathNamed:@"outgoing"]; }
- (NSString *)receivedDirectory { return [self pathNamed:@"received"]; }
- (NSString *)partialDirectory { return [self.receivedDirectory stringByAppendingPathComponent:@".partial"]; }
- (NSString *)hostListPath { return [self pathNamed:@"hosts.json"]; }

- (BOOL)prepareStateDirectoryWithError:(NSError **)error {
    // mkdir -p with 0700 on the last component; ancestors that already exist keep their modes (Application
    // Support is the user's). An existing state directory is tightened to 0700, never loosened.
    NSError *mkdirError = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:self.stateDirectory
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions : @0700}
                                                         error:&mkdirError]) {
        if (error) *error = mkdirError;
        return NO;
    }
    struct stat st;
    if (lstat(self.stateDirectory.fileSystemRepresentation, &st) != 0 || !S_ISDIR(st.st_mode) ||
        st.st_uid != geteuid()) {
        if (error) {
            *error = [NSError errorWithDomain:SZFriendsStatePathsErrorDomain code:EPERM
                                     userInfo:@{NSLocalizedDescriptionKey : @"state directory is not ours"}];
        }
        return NO;
    }
    if ((st.st_mode & 077) != 0) chmod(self.stateDirectory.fileSystemRepresentation, 0700);
    return YES;
}

- (BOOL)prepareDirectoriesWithError:(NSError **)error {
    if (![self prepareStateDirectoryWithError:error]) return NO;
    if (self.socketPath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:SZFriendsStatePathsErrorDomain code:ENAMETOOLONG
                                     userInfo:@{NSLocalizedDescriptionKey : @"no socket path fits sun_path"}];
        }
        return NO;
    }
    // One rule for both sides: the client library's check creates the directory 0700 and refuses a symlink,
    // another owner or any group/world permission (PROTOCOL.md § Transport, directory safety).
    szfriends_status status = szfriends_socket_directory_check(self.socketPath.fileSystemRepresentation, true);
    if (status != SZFRIENDS_OK) {
        if (error) {
            NSString *what = status == SZFRIENDS_ERR_UNSAFE_DIRECTORY ? @"socket directory is unsafe"
                                                                      : @"socket directory cannot be created";
            *error = [NSError errorWithDomain:SZFriendsStatePathsErrorDomain code:status
                                     userInfo:@{NSLocalizedDescriptionKey : what}];
        }
        return NO;
    }
    return YES;
}

@end
