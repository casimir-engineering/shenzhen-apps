// Fakes and helpers for the host area's tests (see the header for why the identity header is faked here).

#import "SZFriendsHostTestSupport.h"

#import <sodium.h>
#import <sys/socket.h>
#import <sys/un.h>

int SZFHFailures = 0;

void SZFHFail(const char *file, int line, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(stderr, "%s:%d: %s\n", file, line, message.UTF8String);
    SZFHFailures += 1;
}

BOOL SZFHWaitUntil(NSTimeInterval timeout, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(timeout, 10.0)];
    while ([deadline timeIntervalSinceNow] > 0) {
        if (condition()) return YES;
        usleep(10000);
    }
    return condition();
}

void SZFHDrain(dispatch_queue_t queue) {
    for (int i = 0; i < 3; i++) dispatch_sync(queue, ^{
                                });
}

NSData *SZFHHex(NSString *hex) {
    NSMutableData *data = [NSMutableData dataWithLength:hex.length / 2];
    sodium_hex2bin(data.mutableBytes, data.length, hex.UTF8String, hex.length, NULL, NULL, NULL);
    return data;
}

NSString *SZFHHexString(NSData *data) {
    NSMutableData *hex = [NSMutableData dataWithLength:data.length * 2 + 1];
    sodium_bin2hex(hex.mutableBytes, hex.length, data.bytes, data.length);
    return [NSString stringWithUTF8String:hex.bytes];
}

// Every directory SZFHTempDir made in this run. Harnesses and live clients outlive the function that made their
// directories, so the suite removes them all at the end (SZFHRemoveTempDirs) instead of each test doing it.
static NSMutableArray<NSString *> *SZFHTempDirs(void) {
    static NSMutableArray<NSString *> *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dirs = [NSMutableArray array];
    });
    return dirs;
}

NSString *SZFHTempDirPrefix(void) {
    return [NSString stringWithFormat:@"szfh-%d-", getpid()];
}

NSString *SZFHTempDir(void) {
    NSString *name = [SZFHTempDirPrefix() stringByAppendingString:@"XXXXXX"];
    char *path = strdup([NSTemporaryDirectory() stringByAppendingPathComponent:name].fileSystemRepresentation);
    NSString *made = mkdtemp(path) ? [NSString stringWithUTF8String:path] : nil;
    free(path);
    if (made) {
        @synchronized(SZFHTempDirs()) {
            [SZFHTempDirs() addObject:made];
        }
    }
    return made;
}

void SZFHRemoveTempDirs(void) {
    @synchronized(SZFHTempDirs()) {
        for (NSString *dir in SZFHTempDirs()) [[NSFileManager defaultManager] removeItemAtPath:dir error:NULL];
        [SZFHTempDirs() removeAllObjects];
    }
}

NSString *SZFHEnv(NSString *name) {
    const char *value = getenv(name.UTF8String);
    return value ? [NSString stringWithUTF8String:value] : nil;
}

NSDictionary *SZFHVectors(void) {
    static NSDictionary *vectors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:SZFHEnv(@"SZFRIENDS_HOST_VECTORS") ?: @""];
        vectors = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    });
    return vectors;
}

#pragma mark - Identity stand-ins

@implementation SZFHTestIdentity {
    NSData *_secretKey;
    BOOL _broken;
}

+ (instancetype)identityWithSeed:(NSData *)seed {
    SZFHTestIdentity *identity = [[SZFHTestIdentity alloc] init];
    NSMutableData *pk = [NSMutableData dataWithLength:crypto_sign_PUBLICKEYBYTES];
    NSMutableData *sk = [NSMutableData dataWithLength:crypto_sign_SECRETKEYBYTES];
    crypto_sign_seed_keypair(pk.mutableBytes, sk.mutableBytes, seed.bytes);
    identity->_publicKey = pk;
    identity->_secretKey = sk;
    return identity;
}

+ (instancetype)randomIdentity {
    NSMutableData *seed = [NSMutableData dataWithLength:crypto_sign_SEEDBYTES];
    randombytes_buf(seed.mutableBytes, seed.length);
    return [self identityWithSeed:seed];
}

+ (instancetype)brokenIdentity {
    SZFHTestIdentity *identity = [self randomIdentity];
    identity->_broken = YES;
    return identity;
}

// The identity area's contract: Ed25519 over UTF-8(domain) || message.
- (NSData *)signatureForMessage:(NSData *)message domain:(NSString *)domain {
    NSMutableData *bytes = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [bytes appendData:message];
    NSMutableData *signature = [NSMutableData dataWithLength:crypto_sign_BYTES];
    crypto_sign_detached(signature.mutableBytes, NULL, bytes.bytes, bytes.length, _secretKey.bytes);
    if (_broken) ((unsigned char *)signature.mutableBytes)[0] ^= 0x01;
    return signature;
}

- (SZFriendsIdentity *)asIdentity {
    return (SZFriendsIdentity *)(id)self;
}

@end

BOOL SZFHVerify(NSData *signature, NSData *message, NSString *domain, NSData *publicKey) {
    NSMutableData *bytes = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [bytes appendData:message];
    return signature.length == crypto_sign_BYTES && publicKey.length == crypto_sign_PUBLICKEYBYTES &&
           crypto_sign_verify_detached(signature.bytes, bytes.bytes, bytes.length, publicKey.bytes) == 0;
}

// The identity area's word-count rule, faked so the provider test can see what it was asked. The signature comes
// from the identity header, so a change there fails this build, which is the point.
NSInteger SZFHLastListWords = -1;
NSUInteger SZFHLastCollisions = 0;
NSUInteger SZFriendsWordCountForNewID(NSInteger listNewIDWords, NSUInteger collisionsInARow) {
    SZFHLastListWords = listNewIDWords;
    SZFHLastCollisions = collisionsInARow;
    return collisionsInARow >= 3 ? 3 : (NSUInteger)listNewIDWords;
}

@implementation SZFHTestCodec

- (NSString *)randomIDWithWordCount:(NSUInteger)wordCount generator:(uint32_t (^)(uint32_t bound))randomUniform {
    NSArray<NSString *> *words = @[ @"maple", @"river", @"harbor", @"cedar", @"pebble", @"otter", @"tulip", @"lark" ];
    NSMutableArray<NSString *> *picked = [NSMutableArray array];
    for (NSUInteger i = 0; i < wordCount; i++) [picked addObject:words[randomUniform((uint32_t)words.count)]];
    return [picked componentsJoinedByString:@"-"];
}

- (SZFriendsIDCodec *)asCodec {
    return (SZFriendsIDCodec *)(id)self;
}

@end

#pragma mark - Signing

@implementation SZFHSigner {
    NSData *_secretKey;
}

+ (instancetype)signerWithSeed:(NSData *)seed {
    SZFHSigner *signer = [[SZFHSigner alloc] init];
    signer->_seed = [seed copy];
    NSMutableData *pk = [NSMutableData dataWithLength:crypto_sign_PUBLICKEYBYTES];
    NSMutableData *sk = [NSMutableData dataWithLength:crypto_sign_SECRETKEYBYTES];
    crypto_sign_seed_keypair(pk.mutableBytes, sk.mutableBytes, seed.bytes);
    signer->_publicKey = pk;
    signer->_secretKey = sk;
    return signer;
}

+ (instancetype)randomSigner {
    NSMutableData *seed = [NSMutableData dataWithLength:crypto_sign_SEEDBYTES];
    randombytes_buf(seed.mutableBytes, seed.length);
    return [self signerWithSeed:seed];
}

- (NSData *)signatureOver:(NSData *)bytes {
    NSMutableData *signature = [NSMutableData dataWithLength:crypto_sign_BYTES];
    crypto_sign_detached(signature.mutableBytes, NULL, bytes.bytes, bytes.length, _secretKey.bytes);
    return signature;
}

- (NSData *)envelopeForPayload:(NSDictionary *)payload {
    NSData *payloadBytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL];
    NSMutableData *signed_ = [[SZFriendsHostListDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signed_ appendData:payloadBytes];
    NSDictionary *envelope = @{
        @"payload" : SZFriendsHostBase64URLEncode(payloadBytes),
        @"sigs" : @[ @{@"key" : @"primary", @"sig" : SZFriendsHostBase64URLEncode([self signatureOver:signed_])} ]
    };
    return [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
}

@end

NSDictionary *SZFHPayload(NSInteger version, NSArray<NSDictionary *> *hosts) {
    NSMutableArray *entries = [NSMutableArray array];
    for (NSDictionary *host in hosts) {
        NSMutableData *key = [host[@"key"] mutableCopy] ?: [NSMutableData dataWithLength:32];
        if (host[@"key"] == nil) randombytes_buf(key.mutableBytes, key.length);
        [entries addObject:@{
            @"id" : host[@"id"],
            @"role" : host[@"role"] ?: @"rendezvous",
            @"urls" : host[@"urls"] ?: @[ host[@"url"] ],
            @"region" : @"Test",
            @"priority" : host[@"priority"],
            @"public_key" : SZFriendsHostBase64URLEncode(key),
        }];
    }
    return @{@"version" : @(version), @"issued_at" : @"2026-10-12T06:00:00Z", @"new_id_words" : @2, @"hosts" : entries};
}

NSDictionary *SZFHSigned(NSDictionary *reply, SZFHSigner *host, NSString *nonce, NSString *requested) {
    NSString *type = reply[@"type"];
    NSArray *body = [type isEqual:@"welcome"]          ? SZFriendsHostWelcomeBody(requested, reply)
                    : [type isEqual:@"reserve_result"] ? SZFriendsHostReserveResultBody(requested, reply)
                                                       : SZFriendsHostReleasedBody(reply);
    NSMutableData *bytes = [[SZFriendsHostReplyDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [bytes appendData:SZFriendsHostReplyMessage(SZFriendsHostBase64URLDecode(nonce, 32), body)];
    NSMutableDictionary *signedReply = [reply mutableCopy];
    signedReply[@"host_sig"] = SZFriendsHostBase64URLEncode([host signatureOver:bytes]);
    return signedReply;
}

// PKCS#8 for Ed25519 is a fixed 16-byte prefix and the 32-byte seed (portable/server/friends/src/keys.js).
NSString *SZFHPrivateKeyPEM(SZFHSigner *signer) {
    NSMutableData *der = [SZFHHex(@"302e020100300506032b657004220420") mutableCopy];
    [der appendData:signer.seed];
    return [NSString stringWithFormat:@"-----BEGIN PRIVATE KEY-----\n%@\n-----END PRIVATE KEY-----\n",
                                      [der base64EncodedStringWithOptions:0]];
}

#pragma mark - Scripted socket and recorder

@implementation SZFHFakeSocket {
    NSMutableArray<NSDictionary *> *_sent;
}

@synthesize onOpen = _onOpen;
@synthesize onMessage = _onMessage;
@synthesize onClose = _onClose;

- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = url;
        _sent = [NSMutableArray array];
    }
    return self;
}

- (void)open {
    _opened = YES;
    if (_onOpen) _onOpen();
}

- (void)sendMessage:(NSData *)message {
    id object = [NSJSONSerialization JSONObjectWithData:message options:0 error:NULL];
    @synchronized(self) {
        if (object) [_sent addObject:object];
    }
}

- (NSArray<NSDictionary *> *)sent {
    @synchronized(self) {
        return [_sent copy];
    }
}

- (void)close {
    _closed = YES;
}

- (void)deliver:(NSDictionary *)message {
    NSMutableDictionary *full = [message mutableCopy];
    full[@"v"] = @1;
    if (_onMessage) _onMessage([NSJSONSerialization dataWithJSONObject:full options:0 error:NULL]);
}

- (void)closeWithCode:(NSInteger)code {
    NSError *closed = [NSError errorWithDomain:SZFriendsHostErrorDomain code:code userInfo:nil];
    if (_onClose) _onClose(closed);
}

- (void)hangUp {
    NSError *lost = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNetworkConnectionLost userInfo:nil];
    if (_onClose) _onClose(lost);
}

@end

@implementation SZFHRecorder {
    NSMutableArray<NSString *> *_events;
}

- (instancetype)init {
    if ((self = [super init])) _events = [NSMutableArray array];
    return self;
}

- (void)record:(NSString *)event {
    @synchronized(self) {
        [_events addObject:event];
    }
}

- (NSArray<NSString *> *)events {
    @synchronized(self) {
        return [_events copy];
    }
}

- (BOOL)saw:(NSString *)event {
    return [[self events] containsObject:event];
}

- (void)checkInStateDidChange:(SZFriendsHostState)state {
    [self record:[NSString stringWithFormat:@"state %ld", (long)state]];
}

- (void)checkInDidReserveID:(NSString *)friendsID {
    [self record:[NSString stringWithFormat:@"reserved %@", friendsID]];
    if (self.reserveDelay > 0) [NSThread sleepForTimeInterval:self.reserveDelay];
}

- (void)checkInDidRenameIDFrom:(NSString *)friendsID to:(NSString *)newID {
    [self record:[NSString stringWithFormat:@"renamed %@ %@", friendsID, newID]];
    if (self.reserveDelay > 0) [NSThread sleepForTimeInterval:self.reserveDelay];
}

- (void)checkInDeviceWasRevoked {
    [self record:@"revoked"];
}

- (void)checkInRequiresUpdate {
    [self record:@"update"];
}

- (void)checkInDidReceiveAttestation:(SZFriendsHostAttestation *)attestation {
    [self record:[NSString stringWithFormat:@"attestation %@ %@", attestation.friendsID, attestation.hostID]];
}

@end

#pragma mark - Dashboard requests

NSInteger SZFHDashboardRequest(NSString *socketPath, NSString *method, NSString *path, NSString *user,
                               NSString *password, NSData *body) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strlcpy(address.sun_path, socketPath.fileSystemRepresentation, sizeof address.sun_path);
    struct timeval timeout = {.tv_sec = 5};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    if (connect(fd, (struct sockaddr *)&address, sizeof address) != 0) {
        close(fd);
        return 0;
    }
    NSString *auth = [[[NSString stringWithFormat:@"%@:%@", user, password] dataUsingEncoding:NSUTF8StringEncoding]
        base64EncodedStringWithOptions:0];
    NSMutableData *request = [[[NSString
        stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: dashboard\r\nAuthorization: Basic %@\r\nContent-Length: %lu\r\n"
                         @"Connection: close\r\n\r\n",
                         method, path, auth, (unsigned long)body.length] dataUsingEncoding:NSUTF8StringEncoding]
        mutableCopy];
    if (body) [request appendData:body];
    write(fd, request.bytes, request.length);
    char buffer[64] = {0};
    ssize_t got = read(fd, buffer, sizeof buffer - 1);
    close(fd);
    int status = 0;
    return got > 12 && sscanf(buffer, "HTTP/1.1 %d", &status) == 1 ? status : 0;
}
