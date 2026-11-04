// Small shared pieces of the helper: its log line, its build identity, whether its executable is still the one it
// started from, test time scaling and JSON type checks.

#import "service/helper/SZFriendsHelperInternal.h"

#import <errno.h>
#import <libproc.h>
#import <sys/stat.h>
#import <unistd.h>

#import "client/szfriends_client.h"

void SZFriendsHelperLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    NSString *line = [NSString stringWithFormat:@"%@ shenzhen-friends[%d] %@\n",
                                                [formatter stringFromDate:[NSDate date]], getpid(), message];
    NSData *bytes = [line dataUsingEncoding:NSUTF8StringEncoding];
    // write(2) rather than stdio: one atomic append per line even when several helpers share the log.
    if (bytes.length > 0) (void)write(STDERR_FILENO, bytes.bytes, bytes.length);
}

SZFriendsExecutableIdentity SZFriendsOwnExecutableIdentity(void) {
    SZFriendsExecutableIdentity identity;
    memset(&identity, 0, sizeof identity);
    struct stat info;
    if (proc_pidpath(getpid(), identity.path, sizeof identity.path) > 0 && stat(identity.path, &info) == 0) {
        identity.known = YES;
        identity.device = info.st_dev;
        identity.inode = info.st_ino;
    }
    return identity;
}

NSString *_Nullable SZFriendsOwnExecutableChange(const SZFriendsExecutableIdentity *identity) {
    if (identity == NULL || !identity->known) return nil;
    char now[sizeof identity->path];
    errno = 0;
    // The kernel follows the file through renames and fails with ENOENT once no name is left: deleted.
    if (proc_pidpath(getpid(), now, sizeof now) <= 0) return errno == ENOENT ? @"its executable was deleted" : nil;
    struct stat info;
    if (stat(identity->path, &info) == 0 && (info.st_dev != identity->device || info.st_ino != identity->inode)) {
        return @"another app was put where it started from";
    }
    return nil;
}

NSString *SZFriendsHelperVersionString(void) {
    NSDictionary *info = [NSBundle mainBundle].infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"];
    if (![version isKindOfClass:[NSString class]] || version.length == 0) return @"0";
    // CFBundleVersion is the YYMMDDBB build number (helper.mk); its last two digits are the app's build.
    uint64_t build = SZFriendsHelperBuildNumber();
    if (build == 0) return version;
    return [NSString stringWithFormat:@"%@-%llu", version, build % 100];
}

uint64_t SZFriendsHelperBuildNumber(void) {
    id value = [NSBundle mainBundle].infoDictionary[@"SZFriendsBuildNumber"];
    if ([value isKindOfClass:[NSNumber class]]) return [value unsignedLongLongValue];
    if ([value isKindOfClass:[NSString class]]) return strtoull([value UTF8String], NULL, 10);
    return 0;
}

SZFriendsProtocolVersion SZFriendsHelperProtocolVersion(void) {
    return (SZFriendsProtocolVersion){.major = SZFRIENDS_PROTOCOL_MAJOR, .minor = SZFRIENDS_PROTOCOL_MINOR};
}

double SZFriendsHelperTimeScale(NSDictionary<NSString *, NSString *> *env) {
    if (env[@SZFRIENDS_ENV_STATE_DIR].length == 0) return 1.0;
    NSString *text = env[@"SZFRIENDS_HELPER_TIME_SCALE"];
    if (text.length == 0) return 1.0;
    double scale = text.doubleValue;
    if (!(scale > 0)) return 1.0;
    return MAX(0.01, MIN(1.0, scale));
}

NSDictionary<NSString *, NSString *> *SZFriendsHelperTrustedEnvironment(NSDictionary<NSString *, NSString *> *env,
                                                                        BOOL overridesAllowed,
                                                                        NSArray<NSString *> **ignored) {
    NSMutableArray<NSString *> *dropped = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *kept = [env mutableCopy];
    if (!overridesAllowed) {
        for (NSString *name in env) {
            if ([name hasPrefix:@"SZFRIENDS_"]) [dropped addObject:name];
        }
        [kept removeObjectsForKeys:dropped];
    }
    if (ignored) *ignored = [dropped sortedArrayUsingSelector:@selector(compare:)];
    return kept;
}

BOOL SZFriendsJSONIsBool(id _Nullable value) {
    return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

BOOL SZFriendsJSONIsInteger(id _Nullable value) {
    if (![value isKindOfClass:[NSNumber class]] || SZFriendsJSONIsBool(value)) return NO;
    double d = [value doubleValue];
    // Integers below 2^53, as PROTOCOL.md requires of sizes; 1.5 or 1e300 are not integers here.
    return d == floor(d) && fabs(d) < 9007199254740992.0;
}

BOOL SZFriendsJSONIsString(id _Nullable value) {
    return [value isKindOfClass:[NSString class]];
}

BOOL SZFriendsFrameIDIsValid(id _Nullable value) {
    if (!SZFriendsJSONIsString(value)) return NO;
    NSString *text = value;
    if (text.length < 1 || text.length > 32) return NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < 0x20 || c > 0x7e) return NO;
    }
    return YES;
}

NSString *SZFriendsRFC3339(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSISO8601DateFormatter alloc] init];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    return [formatter stringFromDate:date];
}
