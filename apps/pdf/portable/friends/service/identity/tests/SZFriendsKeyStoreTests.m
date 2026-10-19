// Key stores: the file store on disk, the store the helper picks, and the Keychain store through a fake of its
// Security calls. Nothing here touches the real Keychain.

#import "service/identity/SZFriendsIdentityInternal.h"
#import "service/identity/SZFriendsKeychainCalls.h"
#import "SZFriendsIdentityTestSupport.h"

#import <LocalAuthentication/LocalAuthentication.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations" // kSecUseAuthenticationUI, as the store uses it

// Records every call, keeps items in memory, and checks the interaction switch is off during each item call.
@interface SZFFakeKeychain : NSObject <SZFriendsKeychainCalls>
@property(nonatomic) NSMutableDictionary<NSString *, NSData *> *items; // by account
@property(nonatomic) NSMutableArray<NSString *> *calls;
@property(nonatomic) NSMutableArray<NSDictionary *> *queries;
@property(nonatomic) Boolean interactionAllowed;
@property(nonatomic) BOOL itemCallWhileInteractive;
@property(nonatomic) OSStatus copyStatus;      // forced result of copyMatching when not errSecSuccess
@property(nonatomic) OSStatus getSwitchStatus; // forced result of getUserInteractionAllowed
@end

@implementation SZFFakeKeychain
- (instancetype)init {
    if ((self = [super init])) {
        _items = [NSMutableDictionary dictionary];
        _calls = [NSMutableArray array];
        _queries = [NSMutableArray array];
        _interactionAllowed = true;
        _copyStatus = errSecSuccess;
        _getSwitchStatus = errSecSuccess;
    }
    return self;
}
- (void)noteItemCall:(NSString *)name query:(NSDictionary *)query {
    [_calls addObject:name];
    [_queries addObject:query];
    if (_interactionAllowed) _itemCallWhileInteractive = YES;
}
- (OSStatus)copyMatching:(NSDictionary *)query result:(id _Nullable __autoreleasing *)result {
    [self noteItemCall:@"copy" query:query];
    if (_copyStatus != errSecSuccess) return _copyStatus;
    NSData *data = _items[query[(__bridge id)kSecAttrAccount]];
    if (data == nil) return errSecItemNotFound;
    *result = [data copy];
    return errSecSuccess;
}
- (OSStatus)add:(NSDictionary *)attributes {
    [self noteItemCall:@"add" query:attributes];
    NSString *account = attributes[(__bridge id)kSecAttrAccount];
    if (_items[account] != nil) return errSecDuplicateItem;
    _items[account] = [attributes[(__bridge id)kSecValueData] copy]; // SecItemAdd copies; callers zero theirs
    return errSecSuccess;
}
- (OSStatus)deleteMatching:(NSDictionary *)query {
    [self noteItemCall:@"delete" query:query];
    NSString *account = query[(__bridge id)kSecAttrAccount];
    if (_items[account] == nil) return errSecItemNotFound;
    [_items removeObjectForKey:account];
    return errSecSuccess;
}
- (OSStatus)getUserInteractionAllowed:(Boolean *)allowed {
    [_calls addObject:@"get-switch"];
    if (_getSwitchStatus != errSecSuccess) return _getSwitchStatus;
    *allowed = _interactionAllowed;
    return errSecSuccess;
}
- (OSStatus)setUserInteractionAllowed:(Boolean)allowed {
    [_calls addObject:allowed ? @"allow" : @"disallow"];
    _interactionAllowed = allowed;
    return errSecSuccess;
}
@end

static void TestFileStore(void) {
    NSString *root = SZFMakeTemporaryDirectory(@"filestore");
    NSString *keys = [root stringByAppendingPathComponent:@"state/keys"];
    SZFriendsFileKeyStore *store = [[SZFriendsFileKeyStore alloc] initWithDirectory:keys];
    NSError *error = [NSError errorWithDomain:@"sentinel" code:1 userInfo:nil];

    SZFExpect([store secretNamed:@"identity" error:&error] == nil && error == nil, @"absent reads as nil, no error");
    NSData *secret = [@"first secret" dataUsingEncoding:NSUTF8StringEncoding];
    SZFExpect([store storeSecret:secret named:@"identity" error:&error], @"store: %@", error);
    SZFExpect([[store secretNamed:@"identity" error:&error] isEqualToData:secret], @"round trip");

    struct stat info;
    SZFExpect(stat([keys stringByAppendingPathComponent:@"identity"].fileSystemRepresentation, &info) == 0 &&
                  (info.st_mode & 0777) == 0600, @"key file is 0600");
    SZFExpect(stat(keys.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0700, @"directory 0700");
    NSArray *leftovers = [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:keys error:NULL]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.partial'"]];
    SZFExpect(leftovers.count == 0, @"no temporary files left: %@", leftovers);

    // Never replaces: the existing secret survives a second store.
    NSData *other = [@"second secret" dataUsingEncoding:NSUTF8StringEncoding];
    error = nil;
    SZFExpect(![store storeSecret:other named:@"identity" error:&error], @"second store refused");
    SZFExpect(error.code == SZFriendsIdentityErrorStoreFailed, @"StoreFailed, got %@", error);
    SZFExpect([[store secretNamed:@"identity" error:NULL] isEqualToData:secret], @"original kept");

    // Unreadable, group-readable, foreign or linked files are unavailable: they exist, so nobody may replace them.
    NSString *path = [keys stringByAppendingPathComponent:@"identity"];
    chmod(path.fileSystemRepresentation, 0644);
    error = nil;
    SZFExpect([store secretNamed:@"identity" error:&error] == nil && error.code == SZFriendsIdentityErrorUnavailable,
              @"group-readable file is unavailable: %@", error);
    chmod(path.fileSystemRepresentation, 0000);
    error = nil;
    if (geteuid() != 0) {
        SZFExpect([store secretNamed:@"identity" error:&error] == nil &&
                      error.code == SZFriendsIdentityErrorUnavailable, @"unreadable file is unavailable: %@", error);
    }
    chmod(path.fileSystemRepresentation, 0600);
    NSString *target = [root stringByAppendingPathComponent:@"elsewhere"];
    [secret writeToFile:target atomically:NO];
    chmod(target.fileSystemRepresentation, 0600);
    symlink(target.fileSystemRepresentation, [keys stringByAppendingPathComponent:@"linked"].fileSystemRepresentation);
    error = nil;
    SZFExpect([store secretNamed:@"linked" error:&error] == nil && error.code == SZFriendsIdentityErrorUnavailable,
              @"symbolic link is unavailable, not followed: %@", error);
    mkdir([keys stringByAppendingPathComponent:@"folder"].fileSystemRepresentation, 0700);
    error = nil;
    SZFExpect([store secretNamed:@"folder" error:&error] == nil && error != nil, @"a directory is unavailable");

    // Names can never become paths.
    for (NSString *bad in @[ @"", @"../escape", @"a/b", @".hidden", @"white space", [@"" stringByPaddingToLength:65
        withString:@"x" startingAtIndex:0] ]) {
        error = nil;
        SZFExpect(![store storeSecret:secret named:bad error:&error] && error != nil, @"name '%@' refused", bad);
        error = nil;
        SZFExpect([store secretNamed:bad error:&error] == nil && error != nil, @"read of '%@' refused", bad);
    }
    SZFExpect(![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"state/escape"]],
              @"nothing written outside the key directory");

    SZFExpect([store deleteSecretNamed:@"identity" error:&error], @"delete: %@", error);
    SZFExpect([store secretNamed:@"identity" error:&error] == nil && error == nil, @"gone after delete");
    SZFExpect([store deleteSecretNamed:@"identity" error:&error], @"deleting nothing succeeds");
    SZFExpect([store storeSecret:other named:@"identity" error:&error], @"store again after delete");
    SZFRemoveTemporaryDirectory(root);
}

static void TestDefaultStore(void) {
    NSString *state = @"/tmp/szfriends-state";
    NSString *keys = @"/tmp/szfriends-state/keys";
    struct { NSDictionary *env; BOOL file; } cases[] = {
        {@{}, NO},
        {@{@"SZFRIENDS_STATE_DIR" : state}, YES},
        {@{@"SZFRIENDS_STATE_DIR" : @""}, YES},
        {@{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"keychain"}, NO},
        {@{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"Keychain"}, NO},
        {@{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"other"}, YES},
        {@{@"SZFRIENDS_KEY_STORE" : @"file"}, YES},
        {@{@"SZFRIENDS_KEY_STORE" : @"FILE"}, YES},
        {@{@"SZFRIENDS_KEY_STORE" : @"keychain"}, NO},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        // Creating a Keychain store does no Keychain work, so this never reaches the real Keychain.
        id<SZFriendsKeyStore> store = SZFriendsDefaultKeyStore(state, cases[i].env);
        BOOL isFile = [store isKindOfClass:[SZFriendsFileKeyStore class]];
        SZFExpect(isFile == cases[i].file, @"case %zu %@: file store %d", i, cases[i].env, isFile);
        SZFExpect(cases[i].file || [store isKindOfClass:[SZFriendsKeychainKeyStore class]], @"case %zu keychain", i);
        if (isFile) SZFExpect([((SZFriendsFileKeyStore *)store).directory isEqualToString:keys], @"keys directory");
    }
}

// A team-signed release ignores every override (security review: launchctl setenv must not move the identity into a
// plaintext file). The signing check is injected: these test binaries are linker-signed, without a team.
static void TestTeamSignedBuildIgnoresOverrides(void) {
    SZFExpect(SZFriendsSigningTeamIdentifier() == nil && SZFriendsEnvironmentOverridesAllowed(),
              @"a test build has no team, so its suites may use temporary state: %@", SZFriendsSigningTeamIdentifier());
    SZFExpect(SZFriendsEnvironmentOverridesAllowedForTeam(nil) && SZFriendsEnvironmentOverridesAllowedForTeam(@""),
              @"no team: overrides allowed");
    SZFExpect(!SZFriendsEnvironmentOverridesAllowedForTeam(@"ABCDE12345"), @"a team: overrides refused");
    SZFExpect(!SZFriendsEnvironmentOverridesAllowedForTeam(@"not a team"), @"any team string counts as signed");
    NSString *state = @"/tmp/szfriends-state";
    NSArray<NSDictionary *> *environments = @[
        @{@"SZFRIENDS_STATE_DIR" : state}, @{@"SZFRIENDS_KEY_STORE" : @"file"},
        @{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"FILE"}, @{@"SZFRIENDS_STATE_DIR" : @""}
    ];
    for (NSDictionary *env in environments) {
        // Creating a Keychain store does no Keychain work, so this never reaches the real Keychain.
        id<SZFriendsKeyStore> signed_ = SZFriendsKeyStoreForTeam(state, env, @"ABCDE12345");
        SZFExpect([signed_ isKindOfClass:[SZFriendsKeychainKeyStore class]], @"team-signed with %@ keeps the Keychain",
                  env);
        id<SZFriendsKeyStore> unsigned_ = SZFriendsKeyStoreForTeam(state, env, nil);
        SZFExpect([unsigned_ isKindOfClass:[SZFriendsFileKeyStore class]], @"a build without a team obeys %@", env);
    }
}

static void ExpectNoninteractiveQuery(NSDictionary *query, NSString *label) {
    SZFExpect([query[(__bridge id)kSecClass] isEqual:(__bridge id)kSecClassGenericPassword], @"%@ class", label);
    SZFExpect([query[(__bridge id)kSecAttrService] isEqual:@"Shenzhen Friends"], @"%@ service", label);
    SZFExpect([query[(__bridge id)kSecAttrSynchronizable] isEqual:@NO], @"%@ never synced", label);
    SZFExpect([query[(__bridge id)kSecUseAuthenticationUI] isEqual:(__bridge id)kSecUseAuthenticationUIFail],
              @"%@ fails instead of showing authentication UI", label);
    LAContext *context = query[(__bridge id)kSecUseAuthenticationContext];
    SZFExpect([context isKindOfClass:[LAContext class]] && context.interactionNotAllowed, @"%@ LAContext", label);
}

static void TestKeychainStore(void) {
    SZFFakeKeychain *fake = [[SZFFakeKeychain alloc] init];
    SZFriendsKeychainKeyStore *store = [[SZFriendsKeychainKeyStore alloc] initWithCalls:fake];
    NSError *error = nil;
    SZFExpect([store secretNamed:@"identity" error:&error] == nil && error == nil, @"absent: nil, no error");

    NSData *secret = [@"keychain secret" dataUsingEncoding:NSUTF8StringEncoding];
    SZFExpect([store storeSecret:secret named:@"identity" error:&error], @"store: %@", error);
    NSDictionary *added = fake.queries.lastObject;
    ExpectNoninteractiveQuery(added, @"add");
    SZFExpect([added[(__bridge id)kSecAttrAccount] isEqual:@"identity"], @"account is the name");
    SZFExpect([added[(__bridge id)kSecAttrAccessible] isEqual:
                   (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly], @"this device only");
    SZFExpect([[store secretNamed:@"identity" error:&error] isEqualToData:secret], @"round trip: %@", error);
    NSDictionary *read = fake.queries.lastObject;
    ExpectNoninteractiveQuery(read, @"copy");
    SZFExpect([read[(__bridge id)kSecReturnData] isEqual:@YES], @"copy returns data");

    // Never replaces, and never updates in place.
    error = nil;
    SZFExpect(![store storeSecret:[NSData dataWithBytes:"x" length:1] named:@"identity" error:&error] &&
                  error.code == SZFriendsIdentityErrorStoreFailed, @"duplicate refused: %@", error);
    SZFExpect([fake.items[@"identity"] isEqualToData:secret], @"original kept");
    SZFExpect(![fake.calls containsObject:@"update"], @"no SecItemUpdate");

    // A refused ACL (an ad-hoc rebuild) or a locked keychain is unavailable, never "absent".
    for (NSNumber *status in @[ @(errSecInteractionNotAllowed), @(errSecAuthFailed), @(errSecUserCanceled),
                                @(errSecNotAvailable) ]) {
        fake.copyStatus = (OSStatus)status.intValue;
        error = nil;
        SZFExpect([store secretNamed:@"identity" error:&error] == nil &&
                      error.code == SZFriendsIdentityErrorUnavailable, @"status %@ is unavailable", status);
        NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
        SZFExpect(underlying.code == status.integerValue, @"underlying status kept: %@", underlying);
    }
    fake.copyStatus = errSecSuccess;

    // Interaction is off during every item call, and the previous setting comes back afterwards.
    SZFExpect(!fake.itemCallWhileInteractive, @"no item call while interaction was allowed");
    SZFExpect(fake.interactionAllowed, @"previous setting restored");
    fake.interactionAllowed = false;
    [store secretNamed:@"identity" error:NULL];
    SZFExpect(!fake.interactionAllowed, @"restores the previous value, not a fixed one");
    fake.interactionAllowed = true;

    // Fails closed: when the switch cannot be read, nothing touches the item.
    fake.getSwitchStatus = errSecInternalComponent;
    NSUInteger before = [fake.calls filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF == 'copy'"]].count;
    error = nil;
    SZFExpect([store secretNamed:@"identity" error:&error] == nil && error.code == SZFriendsIdentityErrorUnavailable,
              @"switch failure is unavailable");
    NSUInteger after = [fake.calls filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"SELF == 'copy'"]].count;
    SZFExpect(before == after, @"no copy without the switch");
    fake.getSwitchStatus = errSecSuccess;

    SZFExpect([store deleteSecretNamed:@"identity" error:&error], @"delete: %@", error);
    ExpectNoninteractiveQuery(fake.queries.lastObject, @"delete");
    SZFExpect(fake.items[@"identity"] == nil, @"deleted");
    SZFExpect([store deleteSecretNamed:@"identity" error:&error], @"deleting nothing succeeds");
    error = nil;
    SZFExpect(![store storeSecret:secret named:@"../x" error:&error] && error != nil, @"bad name refused");
}

int main(void) {
    @autoreleasepool {
        TestFileStore();
        TestDefaultStore();
        TestTeamSignedBuildIgnoresOverrides();
        TestKeychainStore();
        return SZFFinish("SZFriendsKeyStoreTests");
    }
}

#pragma clang diagnostic pop
