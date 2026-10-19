// Sync events, their bodies' fields and version vectors on the wire (SZFriendsSync.h). Everything a peer sends is
// decoded here strictly: one encoding per value, every length checked before it is read.

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"
#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const SZFriendsSyncErrorDomain = @"SZFriendsSyncErrorDomain";
const NSUInteger SZFriendsSyncBodyMax = 60000;
const NSUInteger SZFriendsSyncMessageMax = 64000;
const NSUInteger SZFriendsSyncLabelMax = 80;
const uint64_t SZFriendsSyncAutoCopyMax = 25000000;
const uint64_t SZFriendsSyncLamportMargin = 1ull << 32;
const NSTimeInterval SZFriendsSyncSecretRenewalWait = 600;
const NSUInteger SZFriendsSyncFilePartMax = 48 * 1024;

static NSString *const SZFriendsSyncEventDomain = @"SZFriends sync event v1";
static const uint8_t SZFriendsSyncEventVersion = 1;
// version, kind, author, seq, lamport, ms, two label lengths, body length, digest, signature.
static const NSUInteger SZFriendsSyncHeaderFixed = 1 + 1 + 32 + 8 + 8 + 8 + 1 + 1 + 4 + 32 + 64;

NSError *SZFriendsSyncMakeError(SZFriendsSyncError code, NSString *why) {
    return [NSError errorWithDomain:SZFriendsSyncErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : why}];
}

BOOL SZFriendsSyncFail(NSError **error, SZFriendsSyncError code, NSString *why) {
    if (error) *error = SZFriendsSyncMakeError(code, why);
    return NO;
}

BOOL SZFriendsSyncCopiesAutomatically(uint64_t size, NSString *conversationID) {
    return size <= SZFriendsSyncAutoCopyMax || [conversationID isEqualToString:SZFriendsYouConversationID];
}

static NSData *_Nullable SZFriendsSyncKeyedSecret(NSData *key, NSString *domain, NSData *deviceKey) {
    if (key.length != 32 || deviceKey.length != 32) return nil;
    NSMutableData *input = [[domain dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [input appendData:deviceKey];
    uint8_t secret[32];
    crypto_generichash(secret, sizeof secret, input.bytes, input.length, key.bytes, 32);
    return [NSData dataWithBytes:secret length:sizeof secret];
}

NSData *_Nullable SZFriendsSyncDeviceTagSecret(NSData *ownDevicesSecret, NSData *deviceKey) {
    return SZFriendsSyncKeyedSecret(ownDevicesSecret, @"SZFriends own device v1", deviceKey);
}

NSData *_Nullable SZFriendsSyncFriendDeviceTagSecret(NSData *presenceSecret, NSData *deviceKey) {
    return SZFriendsSyncKeyedSecret(presenceSecret, @"SZFriends device presence v1", deviceKey);
}

void SZFriendsSyncPutU64(NSMutableData *data, uint64_t value) {
    uint8_t bytes[8];
    for (int i = 0; i < 8; i++) bytes[i] = (uint8_t)(value >> (56 - 8 * i));
    [data appendBytes:bytes length:8];
}

uint64_t SZFriendsSyncGetU64(const uint8_t *bytes) {
    uint64_t value = 0;
    for (int i = 0; i < 8; i++) value = (value << 8) | bytes[i];
    return value;
}

// Labels (scope, subject) are ids and prefixes: [A-Za-z0-9_:/-], 0 to SZFriendsSyncLabelMax bytes.
BOOL SZFriendsSyncLabelIsValid(NSString *_Nullable label) {
    NSData *bytes = [label dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes == nil || bytes.length > SZFriendsSyncLabelMax) return NO;
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
        uint8_t c = p[i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
                  c == '-' || c == ':' || c == '/';
        if (!ok) return NO;
    }
    return YES;
}

NSData *SZFriendsSyncDigest(NSData *data) {
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, data.bytes, data.length, NULL, 0);
    return [NSData dataWithBytes:digest length:sizeof digest];
}

#pragma mark - Fields

@implementation SZFriendsSyncFields {
    NSMutableDictionary<NSNumber *, NSData *> *_values;
}

- (instancetype)init {
    if ((self = [super init])) _values = [NSMutableDictionary dictionary];
    return self;
}

+ (nullable instancetype)fieldsWithData:(NSData *)data {
    if (data.length > SZFriendsSyncBodyMax) return nil;
    SZFriendsSyncFields *fields = [[self alloc] init];
    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    int previous = -1;
    while (offset < data.length) {
        if (data.length - offset < 3) return nil;
        uint8_t tag = bytes[offset];
        NSUInteger length = ((NSUInteger)bytes[offset + 1] << 8) | bytes[offset + 2];
        offset += 3;
        if ((int)tag <= previous || data.length - offset < length) return nil;
        previous = tag;
        fields->_values[@(tag)] = [data subdataWithRange:NSMakeRange(offset, length)];
        offset += length;
    }
    return fields;
}

- (NSData *)encodedData {
    NSMutableData *data = [NSMutableData data];
    for (NSNumber *tag in [_values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSData *value = _values[tag];
        uint8_t head[3] = {(uint8_t)tag.unsignedIntValue, (uint8_t)(value.length >> 8), (uint8_t)value.length};
        [data appendBytes:head length:3];
        [data appendData:value];
    }
    return data;
}

- (void)setData:(nullable NSData *)value forTag:(uint8_t)tag {
    if (value == nil || value.length > UINT16_MAX) {
        [_values removeObjectForKey:@(tag)];
        return;
    }
    _values[@(tag)] = [value copy];
}

- (void)setString:(nullable NSString *)value forTag:(uint8_t)tag {
    [self setData:[value dataUsingEncoding:NSUTF8StringEncoding] forTag:tag];
}

- (void)setUInt64:(uint64_t)value forTag:(uint8_t)tag {
    NSMutableData *data = [NSMutableData data];
    SZFriendsSyncPutU64(data, value);
    [self setData:data forTag:tag];
}

- (void)setDate:(nullable NSDate *)value forTag:(uint8_t)tag {
    if (value == nil) {
        [self setData:nil forTag:tag];
        return;
    }
    double seconds = value.timeIntervalSince1970;
    uint64_t bits = 0;
    memcpy(&bits, &seconds, sizeof bits);
    [self setUInt64:bits forTag:tag];
}

- (nullable NSData *)dataForTag:(uint8_t)tag {
    return _values[@(tag)];
}

- (nullable NSString *)stringForTag:(uint8_t)tag {
    NSData *data = _values[@(tag)];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

- (uint64_t)uint64ForTag:(uint8_t)tag {
    NSData *data = _values[@(tag)];
    return data.length == 8 ? SZFriendsSyncGetU64(data.bytes) : 0;
}

- (BOOL)hasTag:(uint8_t)tag {
    return _values[@(tag)] != nil;
}

- (nullable NSDate *)dateForTag:(uint8_t)tag {
    NSData *data = _values[@(tag)];
    if (data.length != 8) return nil;
    uint64_t bits = SZFriendsSyncGetU64(data.bytes);
    double seconds = 0;
    memcpy(&seconds, &bits, sizeof seconds);
    if (!isfinite(seconds)) return nil;
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

@end

#pragma mark - Events

@implementation SZFriendsSyncEvent

static NSMutableData *SZFriendsSyncUnsignedHeader(SZFriendsSyncKind kind, NSData *author, uint64_t seq,
                                                  uint64_t lamport, NSDate *date, NSString *scope,
                                                  NSString *subject, NSData *body) {
    NSData *scopeBytes = [scope dataUsingEncoding:NSUTF8StringEncoding];
    NSData *subjectBytes = [subject dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData *header = [NSMutableData data];
    uint8_t lead[2] = {SZFriendsSyncEventVersion, kind};
    [header appendBytes:lead length:2];
    [header appendData:author];
    SZFriendsSyncPutU64(header, seq);
    SZFriendsSyncPutU64(header, lamport);
    double ms = floor(date.timeIntervalSince1970 * 1000.0);
    SZFriendsSyncPutU64(header, ms > 0 ? (uint64_t)ms : 0);
    uint8_t scopeLength = (uint8_t)scopeBytes.length, subjectLength = (uint8_t)subjectBytes.length;
    [header appendBytes:&scopeLength length:1];
    [header appendData:scopeBytes];
    [header appendBytes:&subjectLength length:1];
    [header appendData:subjectBytes];
    uint32_t length = (uint32_t)body.length;
    uint8_t lengthBytes[4] = {(uint8_t)(length >> 24), (uint8_t)(length >> 16), (uint8_t)(length >> 8),
                              (uint8_t)length};
    [header appendBytes:lengthBytes length:4];
    [header appendData:SZFriendsSyncDigest(body)];
    return header;
}

static NSData *SZFriendsSyncSignedMessage(NSData *rootKey, NSData *unsignedHeader) {
    NSMutableData *message = [rootKey mutableCopy];
    [message appendData:unsignedHeader];
    return message;
}

+ (instancetype)eventSignedBy:(SZFriendsIdentity *)author
                      rootKey:(NSData *)rootKey
                         kind:(SZFriendsSyncKind)kind
                          seq:(uint64_t)seq
                      lamport:(uint64_t)lamport
                         date:(NSDate *)date
                        scope:(NSString *)scope
                      subject:(NSString *)subject
                         body:(NSData *)body {
    if (!SZFriendsSyncLabelIsValid(scope) || !SZFriendsSyncLabelIsValid(subject) ||
        body.length > SZFriendsSyncBodyMax) {
        [NSException raise:NSInvalidArgumentException format:@"a sync event outside its limits"];
    }
    NSMutableData *header =
        SZFriendsSyncUnsignedHeader(kind, author.publicKey, seq, lamport, date, scope, subject, body);
    [header appendData:[author signatureForMessage:SZFriendsSyncSignedMessage(rootKey, header)
                                            domain:SZFriendsSyncEventDomain]];
    SZFriendsSyncEvent *event = [self eventWithHeader:header body:body rootKey:rootKey error:NULL];
    if (event == nil) [NSException raise:NSInternalInconsistencyException format:@"a fresh sync event did not verify"];
    return event;
}

// Decodes the header's fields; `signedLength` receives the length the signature covers. Nil when malformed.
+ (nullable instancetype)decodedHeader:(NSData *)header signedLength:(NSUInteger *)signedLength
                            bodyDigest:(NSData *_Nullable *_Nonnull)digest bodyLength:(uint32_t *)bodyLength {
    if (header.length < SZFriendsSyncHeaderFixed ||
        header.length > SZFriendsSyncHeaderFixed + 2 * SZFriendsSyncLabelMax) {
        return nil;
    }
    const uint8_t *p = header.bytes;
    if (p[0] != SZFriendsSyncEventVersion || p[1] < SZFriendsSyncKindChain || p[1] > SZFriendsSyncKindRevocation) {
        return nil;
    }
    NSUInteger offset = 2 + 32 + 24;
    NSUInteger scopeLength = p[offset];
    if (offset + 1 + scopeLength + 1 > header.length) return nil;
    NSData *scopeBytes = [header subdataWithRange:NSMakeRange(offset + 1, scopeLength)];
    offset += 1 + scopeLength;
    NSUInteger subjectLength = p[offset];
    if (offset + 1 + subjectLength + 4 + 32 + 64 != header.length) return nil;
    NSData *subjectBytes = [header subdataWithRange:NSMakeRange(offset + 1, subjectLength)];
    offset += 1 + subjectLength;
    *bodyLength = ((uint32_t)p[offset] << 24) | ((uint32_t)p[offset + 1] << 16) | ((uint32_t)p[offset + 2] << 8) |
                  p[offset + 3];
    *digest = [header subdataWithRange:NSMakeRange(offset + 4, 32)];
    *signedLength = offset + 4 + 32;
    SZFriendsSyncEvent *event = [[self alloc] init];
    event->_kind = p[1];
    event->_author = [header subdataWithRange:NSMakeRange(2, 32)];
    event->_seq = SZFriendsSyncGetU64(p + 34);
    event->_lamport = SZFriendsSyncGetU64(p + 42);
    event->_date = [NSDate dateWithTimeIntervalSince1970:(double)SZFriendsSyncGetU64(p + 50) / 1000.0];
    event->_scope = [[NSString alloc] initWithData:scopeBytes encoding:NSUTF8StringEncoding];
    event->_subject = [[NSString alloc] initWithData:subjectBytes encoding:NSUTF8StringEncoding];
    if (!SZFriendsSyncLabelIsValid(event->_scope) || !SZFriendsSyncLabelIsValid(event->_subject)) return nil;
    if (event->_seq < 1 || event->_seq > INT64_MAX || event->_lamport < 1 || event->_lamport > INT64_MAX ||
        *bodyLength > SZFriendsSyncBodyMax) {
        return nil;
    }
    event->_header = [header copy];
    return event;
}

+ (nullable instancetype)eventWithHeader:(NSData *)header
                                    body:(nullable NSData *)body
                                 rootKey:(NSData *)rootKey
                                   error:(NSError **)error {
    NSUInteger signedLength = 0;
    NSData *digest = nil;
    uint32_t bodyLength = 0;
    SZFriendsSyncEvent *event = [self decodedHeader:header signedLength:&signedLength bodyDigest:&digest
                                         bodyLength:&bodyLength];
    if (event == nil || rootKey.length != 32) {
        SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"a sync event header that does not decode");
        return nil;
    }
    NSData *signature = [header subdataWithRange:NSMakeRange(signedLength, 64)];
    NSData *message = SZFriendsSyncSignedMessage(rootKey, [header subdataWithRange:NSMakeRange(0, signedLength)]);
    if (![SZFriendsIdentity verifySignature:signature forMessage:message domain:SZFriendsSyncEventDomain
                                  publicKey:event.author]) {
        SZFriendsSyncFail(error, SZFriendsSyncErrorForged, @"a sync event whose signature does not verify");
        return nil;
    }
    if (body != nil && (body.length != bodyLength ||
                        sodium_memcmp(SZFriendsSyncDigest(body).bytes, digest.bytes, 32) != 0)) {
        SZFriendsSyncFail(error, SZFriendsSyncErrorForged, @"a sync event body that does not match its header");
        return nil;
    }
    event->_body = [body copy];
    return event;
}

+ (nullable instancetype)eventWithLogEvent:(SZFriendsSyncLogEvent *)logEvent {
    NSUInteger signedLength = 0;
    NSData *digest = nil;
    uint32_t bodyLength = 0;
    SZFriendsSyncEvent *event = [self decodedHeader:logEvent.header signedLength:&signedLength bodyDigest:&digest
                                         bodyLength:&bodyLength];
    if (event != nil) event->_body = [logEvent.body copy];
    return event;
}

- (SZFriendsSyncLogEvent *)logEvent {
    SZFriendsSyncLogEvent *log = [[SZFriendsSyncLogEvent alloc] init];
    log.author = self.author;
    log.seq = self.seq;
    log.lamport = self.lamport;
    log.kind = self.kind;
    log.scope = self.scope;
    log.subject = self.subject;
    log.header = self.header;
    log.body = self.body;
    return log;
}

@end

#pragma mark - Vectors

static NSComparisonResult SZFriendsSyncCompareKeys(NSData *a, NSData *b) {
    int order = memcmp(a.bytes, b.bytes, MIN(a.length, b.length));
    if (order != 0) return order < 0 ? NSOrderedAscending : NSOrderedDescending;
    return a.length == b.length ? NSOrderedSame : (a.length < b.length ? NSOrderedAscending : NSOrderedDescending);
}

NSArray<NSData *> *SZFriendsSyncSortedKeys(NSArray<NSData *> *keys) {
    return [keys sortedArrayUsingComparator:^NSComparisonResult(NSData *a, NSData *b) {
        return SZFriendsSyncCompareKeys(a, b);
    }];
}

NSData *SZFriendsSyncEncodeVector(SZFriendsSyncVector *vector) {
    NSMutableData *data = [NSMutableData data];
    NSArray<NSData *> *authors = SZFriendsSyncSortedKeys(vector.allKeys);
    uint16_t count = 0;
    for (NSData *author in authors) {
        if (author.length == 32 && [vector[author] unsignedLongLongValue] > 0) count++;
    }
    uint8_t countBytes[2] = {(uint8_t)(count >> 8), (uint8_t)count};
    [data appendBytes:countBytes length:2];
    for (NSData *author in authors) {
        uint64_t seq = [vector[author] unsignedLongLongValue];
        if (author.length != 32 || seq == 0) continue;
        [data appendData:author];
        SZFriendsSyncPutU64(data, seq);
    }
    return data;
}

SZFriendsSyncVector *_Nullable SZFriendsSyncDecodeVector(NSData *data, NSUInteger *_Nullable consumed) {
    if (data.length < 2) return nil;
    const uint8_t *p = data.bytes;
    NSUInteger count = ((NSUInteger)p[0] << 8) | p[1];
    if (count > 256 || data.length < 2 + count * 40) return nil;
    NSMutableDictionary<NSData *, NSNumber *> *vector = [NSMutableDictionary dictionary];
    NSData *previous = nil;
    for (NSUInteger i = 0; i < count; i++) {
        NSData *author = [data subdataWithRange:NSMakeRange(2 + i * 40, 32)];
        uint64_t seq = SZFriendsSyncGetU64(p + 2 + i * 40 + 32);
        // One encoding per vector: authors strictly ascending, no empty entry.
        BOOL ascending = previous == nil || SZFriendsSyncCompareKeys(previous, author) == NSOrderedAscending;
        if (seq == 0 || seq > INT64_MAX || !ascending) {
            return nil;
        }
        previous = author;
        vector[author] = @(seq);
    }
    if (consumed) *consumed = 2 + count * 40;
    return vector;
}

BOOL SZFriendsSyncVectorCovers(SZFriendsSyncVector *vector, NSData *author, uint64_t seq) {
    return [vector[author] unsignedLongLongValue] >= seq;
}

NS_ASSUME_NONNULL_END
