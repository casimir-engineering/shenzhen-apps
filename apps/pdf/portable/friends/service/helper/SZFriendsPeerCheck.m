// Who may drive the helper: the same user always, and in team-signed builds only code signed by the same team.
//
// ADR 0002 § Peer checks. The socket directory is already 0700, so the uid check is defence in depth against a
// misconfigured directory; the team check is what keeps other software the user runs (a script, another app)
// from reading Friends history or sending as the user. Ad-hoc and test builds have no team and check the uid.

#import "service/helper/SZFriendsHelperInternal.h"

#import <Security/Security.h>
#import <fcntl.h>
#import <libproc.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

BOOL SZFriendsReadPeerCredentials(int fd, SZFriendsPeerCredentials *credentials) {
    memset(credentials, 0, sizeof(*credentials));
    uid_t uid = 0;
    gid_t gid = 0;
    if (getpeereid(fd, &uid, &gid) == 0) {
        credentials->hasUID = YES;
        credentials->uid = uid;
    }
    pid_t pid = 0;
    socklen_t pidLength = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0) credentials->pid = pid;
    audit_token_t token;
    socklen_t tokenLength = sizeof(token);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLength) == 0 && tokenLength == sizeof(token)) {
        credentials->hasAuditToken = YES;
        credentials->auditToken = token;
    }
    return credentials->hasUID;
}

BOOL SZFriendsPeerUIDAllowed(const SZFriendsPeerCredentials *credentials, uid_t ownUID) {
    return credentials != NULL && credentials->hasUID && credentials->uid == ownUID;
}

BOOL SZFriendsTeamIdentifierIsValid(NSString *_Nullable team) {
    if (team.length != 10) return NO;
    for (NSUInteger i = 0; i < team.length; i++) {
        unichar c = [team characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return NO;
    }
    return YES;
}

NSString *SZFriendsPeerRequirementForTeam(NSString *team) {
    return [NSString stringWithFormat:@"anchor apple generic and certificate leaf[subject.OU] = \"%@\"", team];
}

NSString *_Nullable SZFriendsOwnTeamIdentifier(void) {
    SecCodeRef selfCode = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &selfCode) != errSecSuccess || selfCode == NULL) return nil;
    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecCodeCopyStaticCode(selfCode, kSecCSDefaultFlags, &staticCode);
    CFRelease(selfCode);
    if (status != errSecSuccess || staticCode == NULL) return nil;
    CFDictionaryRef info = NULL;
    status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &info);
    CFRelease(staticCode);
    if (status != errSecSuccess || info == NULL) return nil;
    NSDictionary *signing = CFBridgingRelease(info);
    NSString *team = signing[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    return SZFriendsTeamIdentifierIsValid(team) ? team : nil;
}

SZFriendsRequirementChecker SZFriendsSecurityRequirementChecker(void) {
    return ^BOOL(audit_token_t token, NSString *requirementText) {
        NSData *tokenData = [NSData dataWithBytes:&token length:sizeof(token)];
        NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributeAudit : tokenData};
        SecCodeRef code = NULL;
        if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) !=
                errSecSuccess ||
            code == NULL) {
            return NO;
        }
        SecRequirementRef requirement = NULL;
        OSStatus status =
            SecRequirementCreateWithString((__bridge CFStringRef)requirementText, kSecCSDefaultFlags, &requirement);
        BOOL valid = NO;
        if (status == errSecSuccess && requirement != NULL) {
            valid = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) == errSecSuccess;
            CFRelease(requirement);
        }
        CFRelease(code);
        return valid;
    };
}

BOOL SZFriendsPeerAllowed(const SZFriendsPeerCredentials *credentials, uid_t ownUID, NSString *_Nullable team,
                          SZFriendsRequirementChecker _Nullable checker) {
    if (!SZFriendsPeerUIDAllowed(credentials, ownUID)) return NO;
    if (team == nil) return YES;
    // A team-signed helper never downgrades to the uid check: a malformed team or a missing token is a refusal.
    if (!SZFriendsTeamIdentifierIsValid(team) || !credentials->hasAuditToken || checker == nil) return NO;
    return checker(credentials->auditToken, SZFriendsPeerRequirementForTeam(team));
}

NSString *_Nullable SZFriendsPeerExecutablePath(const SZFriendsPeerCredentials *credentials) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    int length = 0;
    if (credentials->hasAuditToken) {
        audit_token_t token = credentials->auditToken;
        length = proc_pidpath_audittoken(&token, path, sizeof path);
    } else if (credentials->pid > 0) {
        length = proc_pidpath(credentials->pid, path, sizeof path);
    }
    return length > 0 ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path
                                                                                    length:(NSUInteger)length]
                      : nil;
}

// A property list of at most 64 KiB, opened without following a final symlink and without blocking on a pipe.
static NSDictionary *_Nullable SZFriendsReadSmallPlist(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat info;
    NSData *bytes = nil;
    if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= 65536) {
        NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
        ssize_t got = read(fd, buffer.mutableBytes, buffer.length);
        if (got == (ssize_t)buffer.length) bytes = buffer;
    }
    close(fd);
    id plist = bytes ? [NSPropertyListSerialization propertyListWithData:bytes options:0 format:NULL error:NULL] : nil;
    return [plist isKindOfClass:[NSDictionary class]] ? plist : nil;
}

static void SZFriendsAddBuild(NSMutableSet<NSNumber *> *builds, id value) {
    if ([value isKindOfClass:[NSNumber class]]) [builds addObject:@([value unsignedLongLongValue])];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        [builds addObject:@(strtoull([value UTF8String], NULL, 10))];
    }
}

NSSet<NSNumber *> *SZFriendsEmbeddedHelperBuildsOfApp(NSString *_Nullable executablePath) {
    // <App>.app/Contents/MacOS/<executable>: anything else is not an app's main executable (a script, a tool).
    NSArray<NSString *> *parts = executablePath.pathComponents;
    NSUInteger count = parts.count;
    if (count < 4 || ![parts[count - 2] isEqualToString:@"MacOS"] || ![parts[count - 3] isEqualToString:@"Contents"] ||
        ![parts[count - 4].pathExtension isEqualToString:@"app"]) {
        return [NSSet set];
    }
    NSString *contents = [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0, count - 2)]];
    NSString *plist = [contents stringByAppendingPathComponent:@"Helpers/Shenzhen Friends.app/Contents/Info.plist"];
    NSDictionary *info = SZFriendsReadSmallPlist(plist);
    NSMutableSet<NSNumber *> *builds = [NSMutableSet set];
    SZFriendsAddBuild(builds, info[@"SZFriendsBuildNumber"]);
    SZFriendsAddBuild(builds, info[@"CFBundleVersion"]);
    [builds removeObject:@0];
    return builds;
}
