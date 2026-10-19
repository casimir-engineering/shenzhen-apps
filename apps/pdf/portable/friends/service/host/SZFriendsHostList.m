// The signed host list (ADR 0005 § Signed host list): verification against pinned keys, then parsing of exactly
// the bytes that were signed. The rules match validatePayload and verifyEnvelopeObject in
// portable/server/friends/src/hostlist.js; the shared vectors prove both accept and refuse the same lists.

#import "service/host/SZFriendsHostInternal.h"

#import <sodium.h>

static const NSUInteger SZFriendsHostMaxSignatures = 4;
static const NSUInteger SZFriendsHostMaxHosts = 32;
static const NSUInteger SZFriendsHostMaxURLs = 8;
static const NSUInteger SZFriendsHostMaxURLLength = 512;

@interface SZFriendsHostEntry ()
@property(nonatomic, readwrite) NSString *hostID;
@property(nonatomic, readwrite) SZFriendsHostRole roles;
@property(nonatomic, readwrite) NSArray<NSURL *> *urls;
@property(nonatomic, readwrite) NSArray<NSString *> *turnURIs;
@property(nonatomic, readwrite) NSString *region;
@property(nonatomic, readwrite) NSInteger priority;
@property(nonatomic, readwrite) NSData *publicKey;
@end

@implementation SZFriendsHostEntry
@end

@interface SZFriendsHostList ()
@property(nonatomic, readwrite) NSInteger version;
@property(nonatomic, readwrite) NSDate *issuedAt;
@property(nonatomic, readwrite) NSInteger newIDWords;
@property(nonatomic, readwrite) NSArray<SZFriendsHostEntry *> *entries;
@property(nonatomic, readwrite) NSData *signedData;
@property(nonatomic) NSData *payload;
@end

static BOOL SZFriendsHostFail(NSError **error, SZFriendsHostError code, NSString *description) {
    if (error) *error = SZFriendsHostMakeError(code, description);
    return NO;
}

static BOOL SZFriendsHostValidHostID(id value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *string = value;
    if (string.length < 1 || string.length > 32) return NO;
    for (NSUInteger i = 0; i < string.length; i++) {
        unichar c = [string characterAtIndex:i];
        BOOL alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
        if (!alnum && !(c == '-' && i > 0)) return NO;
    }
    return YES;
}

// RFC 3339 in UTC with an optional fraction of up to three digits, as the server's ISO_TIME accepts.
static NSDate *SZFriendsHostParseTime(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *string = value;
    NSRegularExpression *shape = [NSRegularExpression
        regularExpressionWithPattern:@"^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(\\.\\d{1,3})?Z$"
                             options:0
                               error:NULL];
    if ([shape numberOfMatchesInString:string options:0 range:NSMakeRange(0, string.length)] != 1) return nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime |
                              ([string containsString:@"."] ? NSISO8601DateFormatWithFractionalSeconds : 0);
    return [formatter dateFromString:string];
}

static SZFriendsHostEntry *SZFriendsHostParseEntry(id object, NSError **error) {
    if (![object isKindOfClass:[NSDictionary class]]) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A host entry is not an object.");
        return nil;
    }
    NSDictionary *entry = object;
    SZFriendsHostEntry *host = [[SZFriendsHostEntry alloc] init];
    NSDictionary *roles = @{
        @"rendezvous" : @(SZFriendsHostRoleRendezvous),
        @"relay" : @(SZFriendsHostRoleRelay),
        @"both" : @(SZFriendsHostRoleRendezvous | SZFriendsHostRoleRelay)
    };
    NSNumber *role = [entry[@"role"] isKindOfClass:[NSString class]] ? roles[entry[@"role"]] : nil;
    NSArray *urls = entry[@"urls"];
    id turn = entry[@"turn_uris"] ?: @[];
    long long priority = 0;
    if (!SZFriendsHostValidHostID(entry[@"id"]) || role == nil || ![urls isKindOfClass:[NSArray class]] ||
        urls.count < 1 || urls.count > SZFriendsHostMaxURLs || ![turn isKindOfClass:[NSArray class]] ||
        [turn count] > SZFriendsHostMaxURLs || ![entry[@"region"] isKindOfClass:[NSString class]] ||
        [entry[@"region"] length] < 1 || [entry[@"region"] length] > 64 ||
        !SZFriendsHostJSONInteger(entry[@"priority"], 1, 1000, &priority)) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A host entry is missing a field or has a bad one.");
        return nil;
    }
    NSMutableArray<NSURL *> *parsedURLs = [NSMutableArray array];
    for (id value in urls) {
        NSURL *url = [value isKindOfClass:[NSString class]] && [value length] <= SZFriendsHostMaxURLLength
                         ? [NSURL URLWithString:value]
                         : nil;
        if (url == nil || !SZFriendsHostURLAllowed(url)) {
            SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A host URL is not wss:// (or ws:// on loopback).");
            return nil;
        }
        [parsedURLs addObject:url];
    }
    for (id value in turn) {
        if (![value isKindOfClass:[NSString class]] || [value length] > SZFriendsHostMaxURLLength) {
            SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A TURN URI is not a short string.");
            return nil;
        }
    }
    host.publicKey = SZFriendsHostBase64URLDecode(entry[@"public_key"], 32);
    if (host.publicKey == nil) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A host key is not 32 bytes.");
        return nil;
    }
    host.hostID = entry[@"id"];
    host.roles = role.unsignedIntegerValue;
    host.urls = parsedURLs;
    host.turnURIs = [turn copy];
    host.region = entry[@"region"];
    host.priority = (NSInteger)priority;
    return host;
}

@implementation SZFriendsHostList

+ (instancetype)emptyList {
    SZFriendsHostList *list = [[SZFriendsHostList alloc] init];
    list.version = 0;
    list.issuedAt = [NSDate distantPast];
    list.newIDWords = 2;
    list.entries = @[];
    list.signedData = [NSData data];
    list.payload = [NSData data];
    return list;
}

- (NSData *)payloadData {
    return self.payload;
}

+ (BOOL)verifyEnvelope:(NSDictionary *)envelope
            pinnedKeys:(NSArray<NSData *> *)pinnedKeys
               payload:(NSData **)payloadOut
                 error:(NSError **)error {
    NSData *payload = SZFriendsHostBase64URLDecode(envelope[@"payload"], 0);
    NSArray *sigs = envelope[@"sigs"];
    if (payload.length == 0) return SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"The payload is missing.");
    if (![sigs isKindOfClass:[NSArray class]] || sigs.count < 1 || sigs.count > SZFriendsHostMaxSignatures) {
        return SZFriendsHostFail(error, SZFriendsHostErrorBadSignature, @"The list carries no usable signatures.");
    }
    NSMutableData *signedBytes = [[SZFriendsHostListDomain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [signedBytes appendData:payload];
    BOOL verified = NO;
    for (id entry in sigs) {
        NSData *signature = [entry isKindOfClass:[NSDictionary class]] ? SZFriendsHostBase64URLDecode(entry[@"sig"], 64)
                                                                        : nil;
        if (signature == nil) {
            return SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A signature is malformed.");
        }
        for (NSData *key in pinnedKeys) {
            if (key.length == crypto_sign_PUBLICKEYBYTES &&
                crypto_sign_verify_detached(signature.bytes, signedBytes.bytes, signedBytes.length, key.bytes) == 0) {
                verified = YES;
            }
        }
    }
    if (!verified) return SZFriendsHostFail(error, SZFriendsHostErrorBadSignature, @"No pinned key signed the list.");
    *payloadOut = payload;
    return YES;
}

+ (nullable instancetype)listFromSignedData:(NSData *)data
                                 pinnedKeys:(NSArray<NSData *> *)pinnedKeys
                                      error:(NSError **)error {
    if (data.length == 0 || data.length > SZFriendsHostMaxMessageBytes) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"The list is empty or too large.");
        return nil;
    }
    id envelope = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSData *payload = nil;
    if (![envelope isKindOfClass:[NSDictionary class]]) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"The list is not a JSON envelope.");
        return nil;
    }
    if (![self verifyEnvelope:envelope pinnedKeys:pinnedKeys payload:&payload error:error]) return nil;
    // NSJSONSerialization refuses invalid UTF-8, as the server's fatal TextDecoder does.
    id object = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
    SZFriendsHostList *list = [self listFromPayload:object error:error];
    list.signedData = [data copy];
    list.payload = payload;
    return list;
}

+ (nullable instancetype)listFromPayload:(id)object error:(NSError **)error {
    long long version = 0;
    long long words = 0;
    NSDate *issuedAt = nil;
    NSArray *hosts = [object isKindOfClass:[NSDictionary class]] ? object[@"hosts"] : nil;
    // 2^53 - 1: the largest integer the server's JSON numbers carry exactly (Number.isSafeInteger).
    if (![object isKindOfClass:[NSDictionary class]] ||
        !SZFriendsHostJSONInteger(object[@"version"], 1, 9007199254740991LL, &version) ||
        (issuedAt = SZFriendsHostParseTime(object[@"issued_at"])) == nil ||
        !SZFriendsHostJSONInteger(object[@"new_id_words"], 2, 3, &words) || ![hosts isKindOfClass:[NSArray class]] ||
        hosts.count < 1 || hosts.count > SZFriendsHostMaxHosts) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"The payload is missing a field or has a bad one.");
        return nil;
    }
    NSMutableArray<SZFriendsHostEntry *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *ids = [NSMutableSet set];
    for (id value in hosts) {
        SZFriendsHostEntry *entry = SZFriendsHostParseEntry(value, error);
        if (entry == nil) return nil;
        if ([ids containsObject:entry.hostID]) {
            SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"A host id appears twice.");
            return nil;
        }
        [ids addObject:entry.hostID];
        [entries addObject:entry];
    }
    [entries sortUsingComparator:^NSComparisonResult(SZFriendsHostEntry *a, SZFriendsHostEntry *b) {
        if (a.priority != b.priority) return a.priority < b.priority ? NSOrderedAscending : NSOrderedDescending;
        return [a.hostID compare:b.hostID options:NSLiteralSearch];
    }];
    // Exactly one rendezvous host holds the lowest priority: it is the only ID allocator.
    NSArray<SZFriendsHostEntry *> *rendezvous =
        [entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SZFriendsHostEntry *e, id _) {
                     (void)_;
                     return (e.roles & SZFriendsHostRoleRendezvous) != 0;
                 }]];
    if (rendezvous.count == 0 || (rendezvous.count > 1 && rendezvous[0].priority == rendezvous[1].priority)) {
        SZFriendsHostFail(error, SZFriendsHostErrorMalformed, @"The list needs exactly one main rendezvous host.");
        return nil;
    }
    SZFriendsHostList *list = [[SZFriendsHostList alloc] init];
    list.version = (NSInteger)version;
    list.issuedAt = issuedAt;
    list.newIDWords = (NSInteger)words;
    list.entries = entries;
    return list;
}

@end
