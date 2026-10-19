// Shared pieces of the nearby test binary (SZFriendsHelperNearbyTests.h).

#import "SZFriendsHelperNearbyTests.h"

#import <sodium.h>

SZFriendsHelperServices *SZFNOpenServices(NSString *scratch, NSString *name) {
    NSString *state = [scratch stringByAppendingPathComponent:name];
    [[NSFileManager defaultManager] createDirectoryAtPath:state withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700} error:NULL];
    NSDictionary *env = @{@"SZFRIENDS_STATE_DIR" : state, @"SZFRIENDS_KEY_STORE" : @"file"};
    SZFriendsStatePaths *paths = [[SZFriendsStatePaths alloc] initWithStateDirectory:state];
    SZFriendsHelperServices *services =
        [[SZFriendsHelperServices alloc] initWithPaths:paths environment:env
                                             resources:[SZFriendsHelperResources loadFromBundle:[NSBundle mainBundle]]];
    [services open];
    EXPECT(services.store != nil && services.identity != nil, "services open in %@", state);
    return services.store != nil && services.identity != nil ? services : nil;
}

void SZFNSpin(NSTimeInterval seconds) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static NSData *SZFNRandom(NSUInteger count) {
    NSMutableData *data = [NSMutableData dataWithLength:count];
    randombytes_buf(data.mutableBytes, count);
    return data;
}

SZFriendsPersonRecord *SZFNSavePerson(SZFriendsStore *store, SZFriendsRelation relation) {
    SZFriendsPersonRecord *person = [[SZFriendsPersonRecord alloc] init];
    person.conversationID = SZFriendsNewIdentifier();
    person.identityKey = SZFNRandom(32);
    person.staticKey = SZFNRandom(32);
    person.picture = [SZFriendsPicture placeholder];
    person.relation = relation;
    person.lastInteractionAt = [NSDate date];
    NSError *error = nil;
    EXPECT([store savePerson:person error:&error], "a person is saved: %@", error);
    return person;
}

@implementation SZFNFakeChannel

- (void)closeWithReason:(SZFriendsCloseReason)reason {
    (void)reason;
    _closed = YES;
}

- (void)close {
    _closed = YES;
}

- (SZFriendsSecureChannel *)asChannel {
    return (SZFriendsSecureChannel *)(id)self;
}

@end

@implementation SZFNRecordingAdapter

@synthesize delegate = _delegate;

- (instancetype)init {
    if ((self = [super init])) _lastCallbackTags = @[];
    return self;
}

- (SZFriendsDiscoveryMethod)method {
    return SZFriendsDiscoveryMethodNetwork;
}

- (SZFriendsAdapterState)state {
    return SZFriendsAdapterStateNotAsked;
}

- (SZFriendsPermission)permissionWithoutPrompting {
    return SZFriendsPermissionUnknown;
}

- (void)start {
}

- (void)stop {
}

- (void)advertisePresenceTag:(nullable NSData *)tag
                callbackTags:(NSArray<NSData *> *)callbackTags
                 publicEntry:(BOOL)publicEntry {
    _advertisements++;
    _lastTag = [tag copy];
    _lastCallbackTags = [callbackTags copy];
    _lastPublicEntry = publicEntry;
}

- (void)openStreamToEndpoint:(NSString *)endpointID
                  completion:(void (^)(id<SZFriendsByteStream> _Nullable, NSError *_Nullable))completion {
    (void)endpointID;
    completion(nil, [NSError errorWithDomain:@"SZFNRecordingAdapter" code:1 userInfo:nil]);
}

- (void)setAdmissionLimits:(SZFriendsAdmissionLimits *)limits {
    _admissionLimits = [limits copy];
}

@end
