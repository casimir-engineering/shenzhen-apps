// The check-in client's online side (SZFriendsHostRendezvous.h): whether the connection takes online messages,
// this device's rendezvous record once per host period, lookups, and the request bookkeeping the sid side shares.
// Sids and relay credentials are in SZFriendsHostSignaling.m. Everything runs on the check-in client's queue.

#import "service/host/SZFriendsHostRendezvousInternal.h"

#import "service/host/SZFriendsCheckInClientPrivate.h"
#import "service/host/SZFriendsHostInternal.h"
#import "service/identity/SZFriendsIdentity.h"

#import <os/log.h>

NSErrorDomain const SZFriendsHostOnlineErrorDomain = @"SZFriendsHostOnlineErrorDomain";
NSString *const SZFriendsHostLinkEndedKey = @"link_ended";
const NSUInteger SZFriendsHostSealedRecordLength = 512;
const NSUInteger SZFriendsHostLookupKeysMax = 32;
const NSUInteger SZFriendsHostSignalPayloadMax = 4096;
const NSUInteger SZFriendsHostSignalMessagesMax = 64;
const NSTimeInterval SZFriendsHostRecordPeriod = 60;
const NSTimeInterval SZFriendsHostRecordLifetime = 300;
const NSTimeInterval SZFriendsHostOnlineTimeout = 10;

NSError *SZFriendsHostOnlineMakeError(SZFriendsHostOnlineError code, NSString *description) {
    return [NSError errorWithDomain:SZFriendsHostOnlineErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}

@implementation SZFriendsHostPending
@end

// A lookup split into messages of at most 32 keys; completes once, when every message is answered or one fails.
@interface SZFriendsHostLookupBatch : NSObject
@property(nonatomic) NSMutableArray *blobs; // NSData, or NSNull while unanswered
@property(nonatomic) NSUInteger outstanding;
@property(nonatomic, copy, nullable) void (^completion)(NSArray<NSData *> *_Nullable, NSError *_Nullable);
@end

@implementation SZFriendsHostLookupBatch
@end

@implementation SZFriendsCheckInClient (Online)

- (SZFriendsHostOnline *)online {
    @synchronized(self) {
        if (_online == nil) _online = [[SZFriendsHostOnline alloc] initWithClient:self identity:_identity queue:_queue];
        return _online;
    }
}

@end

@implementation SZFriendsHostOnline

- (instancetype)initWithClient:(SZFriendsCheckInClient *)client
                      identity:(SZFriendsIdentity *)identity
                         queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _client = client;
        _identity = identity;
        _queue = queue;
        _relayURIs = @[];
        _pending = [NSMutableDictionary dictionary];
        _signals = [NSMutableDictionary dictionary];
        _nextReq = 1;
    }
    return self;
}

- (void)dealloc {
    if (_publishTimer) dispatch_source_cancel(_publishTimer);
    for (SZFriendsHostPending *pending in _pending.allValues) {
        if (pending.timer) dispatch_source_cancel(pending.timer);
    }
}

- (BOOL)available {
    return _available;
}

- (NSString *)hostID {
    return _available ? _entry.hostID : nil;
}

- (NSTimeInterval)hostNow {
    return [NSDate date].timeIntervalSince1970 + _skew;
}

- (BOOL)sendType:(NSString *)type fields:(NSDictionary<NSString *, id> *)fields {
    SZFriendsCheckInClient *client = _client;
    if (!_available || client == nil) return NO;
    [client send:type fields:fields];
    return YES;
}

- (dispatch_source_t)timerAfter:(NSTimeInterval)delay handler:(void (^)(SZFriendsHostOnline *online))handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0) * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 20);
    NSUInteger generation = _generation;
    __weak SZFriendsHostOnline *weakSelf = self;
    __weak dispatch_source_t weakTimer = timer;
    dispatch_source_set_event_handler(timer, ^{
        dispatch_source_t strongTimer = weakTimer;
        if (strongTimer) dispatch_source_cancel(strongTimer);
        SZFriendsHostOnline *online = weakSelf;
        if (online && online->_generation == generation) handler(online);
    });
    dispatch_resume(timer);
    return timer;
}

#pragma mark - Requests

- (NSInteger)addPending:(SZFriendsHostPending *)pending {
    NSInteger req = _nextReq++;
    _pending[@(req)] = pending;
    pending.timer = [self timerAfter:SZFriendsHostOnlineTimeout
                             handler:^(SZFriendsHostOnline *online) {
                                 SZFriendsHostPending *late = [online takePending:@(req) kind:pending.kind];
                                 if (late) [online failPending:late code:SZFriendsHostOnlineErrorTimedOut];
                             }];
    return req;
}

- (SZFriendsHostPending *)takePending:(id)req kind:(NSString *)kind {
    long long number = 0;
    if (!SZFriendsHostJSONInteger(req, 0, INT32_MAX, &number)) return nil;
    SZFriendsHostPending *pending = _pending[@(number)];
    if (![pending.kind isEqualToString:kind]) return nil;
    [_pending removeObjectForKey:@(number)];
    if (pending.timer) dispatch_source_cancel(pending.timer);
    pending.timer = nil;
    return pending;
}

- (void)failPending:(SZFriendsHostPending *)pending code:(SZFriendsHostOnlineError)code {
    NSError *error = SZFriendsHostOnlineMakeError(code, @"The Friends host did not complete an online request.");
    if ([pending.kind isEqualToString:@"lookup"]) {
        [self finishLookupBatch:pending.batch blobs:nil error:error];
    } else if (pending.completion) {
        ((void (^)(id, NSError *))pending.completion)(nil, error);
    }
}

#pragma mark - Connection (called by the check-in client)

- (void)connectionDidReceiveChallenge:(NSDictionary<NSString *, id> *)message {
    NSString *time = [message[@"time"] isKindOfClass:[NSString class]] ? message[@"time"] : nil;
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    NSDate *hostTime = time ? [formatter dateFromString:time] : nil;
    if (time && hostTime == nil) {
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        hostTime = [formatter dateFromString:time];
    }
    // A host without a time, or a nonsensical one, is taken to agree with this Mac.
    NSTimeInterval skew = hostTime ? hostTime.timeIntervalSinceNow : 0;
    _skew = fabs(skew) < 86400 ? skew : 0;
}

- (void)connectionDidCheckInWithWelcome:(NSDictionary<NSString *, id> *)message
                                  entry:(SZFriendsHostEntry *)entry
                                   list:(SZFriendsHostList *)list {
    if (_available || ![message[@"online"] isEqual:@YES]) return;
    _entry = entry;
    _relayURIs = [self relayURIsFromList:list entry:entry];
    _available = YES;
    os_log_info(OS_LOG_DEFAULT, "Friends: the host takes online messages");
    [self.delegate hostOnline:self didChangeAvailability:YES];
    if (_available) [self publish];
}

- (BOOL)connectionDidReceive:(NSDictionary<NSString *, id> *)message {
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"rdv_published"]) {
        if (_available) [self receivePublished:message];
        return YES;
    }
    if ([type isEqualToString:@"rdv_records"]) {
        if (_available) [self receiveRecords:message];
        return YES;
    }
    return [self receiveSignalingMessage:message type:type];
}

- (void)connectionDidClose {
    if (!_available && _pending.count == 0 && _signals.count == 0) return;
    _generation += 1;
    if (_publishTimer) dispatch_source_cancel(_publishTimer);
    _publishTimer = nil;
    _recordShownFrom = nil;
    NSDictionary<NSNumber *, SZFriendsHostPending *> *pending = [_pending copy];
    [_pending removeAllObjects];
    for (NSNumber *req in [pending.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (pending[req].timer) dispatch_source_cancel(pending[req].timer);
        [self failPending:pending[req] code:SZFriendsHostOnlineErrorUnavailable];
    }
    [self endAllSignals];
    BOOL was = _available;
    _available = NO;
    _entry = nil;
    if (was) [self.delegate hostOnline:self didChangeAvailability:NO];
}

// The turn: URIs credentials are for: the connected host's when it relays, else every relay host's in list order.
- (NSArray<NSString *> *)relayURIsFromList:(SZFriendsHostList *)list entry:(SZFriendsHostEntry *)entry {
    NSMutableArray<NSString *> *own = [NSMutableArray array], *others = [NSMutableArray array];
    for (SZFriendsHostEntry *host in list.entries) {
        if ((host.roles & SZFriendsHostRoleRelay) == 0) continue;
        for (NSString *uri in host.turnURIs) {
            if (![uri hasPrefix:@"turn:"]) continue;
            [[host.hostID isEqualToString:entry.hostID] ? own : others addObject:uri];
        }
    }
    return own.count ? own : others;
}

#pragma mark - Records

// Once per host period, at a random moment in the first half of the next one, so the record arrives in time to be
// shown for the period after (HOST-PROTOCOL-ONLINE.md § Rendezvous records). The first goes out at once.
- (void)scheduleNextPublishAfterHostTime:(NSTimeInterval)periodStart {
    if (_publishTimer) dispatch_source_cancel(_publishTimer);
    NSTimeInterval target = periodStart + 1 + arc4random_uniform((uint32_t)(SZFriendsHostRecordPeriod / 2 - 2));
    _publishTimer = [self timerAfter:target - [self hostNow]
                             handler:^(SZFriendsHostOnline *online) {
                                 online->_publishTimer = nil;
                                 [online publish];
                             }];
}

- (void)publish {
    NSTimeInterval now = [self hostNow];
    NSTimeInterval period = SZFriendsHostRecordPeriod;
    [self scheduleNextPublishAfterHostTime:(floor(now / period) + 1) * period];
    NSData *sealed = self.sealedRecordProvider ? self.sealedRecordProvider() : nil;
    // Filed under the person's key, which the host derives from the root this device checked in for (§ Several
    // devices); each device signs its own record.
    NSData *rdvKey = SZFriendsHostRendezvousKey(_client.personKey ?: _identity.publicKey);
    if (sealed == nil || rdvKey == nil || _entry.hostID == nil) return;
    if (sealed.length != SZFriendsHostSealedRecordLength) {
        os_log_error(OS_LOG_DEFAULT, "Friends: a rendezvous record of the wrong size was not published");
        return;
    }
    uint64_t millis = (uint64_t)([NSDate date].timeIntervalSince1970 * 1000);
    _seq = MAX(_seq + 1, millis);
    int64_t expires = (int64_t)floor(now) + (int64_t)SZFriendsHostRecordLifetime;
    NSData *signed_ = SZFriendsHostRendezvousRecordMessage(_entry.hostID, rdvKey, _seq, expires, sealed);
    NSData *signature = [_identity signatureForMessage:signed_ domain:SZFriendsHostRendezvousRecordDomain];
    [self sendType:@"rdv_publish"
            fields:@{
                @"seq" : @(_seq),
                @"expires" : @(expires),
                @"sealed" : SZFriendsHostBase64URLEncode(sealed),
                @"sig" : SZFriendsHostBase64URLEncode(signature),
            }];
}

- (void)receivePublished:(NSDictionary<NSString *, id> *)message {
    long long shownFrom = 0;
    if ([message[@"accepted"] isEqual:@YES] && SZFriendsHostJSONInteger(message[@"shown_from"], 0, INT64_MAX >> 11,
                                                                        &shownFrom)) {
        _recordShownFrom = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)shownFrom - _skew];
        // The host's own period is the one to follow: the next publish goes in the first half of the period it
        // named, whatever this Mac's estimate of the host's clock said.
        [self scheduleNextPublishAfterHostTime:(NSTimeInterval)shownFrom];
        return;
    }
    NSString *reason = [message[@"reason"] isKindOfClass:[NSString class]] ? message[@"reason"] : @"?";
    os_log_info(OS_LOG_DEFAULT, "Friends: the host did not take the rendezvous record (%{public}@)", reason);
    // A sequence number the host already has (a clock that went back across a reconnect): jump past it once.
    if ([reason isEqualToString:@"stale"]) _seq += 3600 * 1000;
}

#pragma mark - Lookups

- (void)lookupRendezvousKeys:(NSArray<NSData *> *)keys
                  completion:(void (^)(NSArray<NSData *> *, NSError *))completion {
    dispatch_assert_queue_debug(_queue);
    SZFriendsHostLookupBatch *batch = [[SZFriendsHostLookupBatch alloc] init];
    batch.completion = completion;
    BOOL valid = keys.count > 0;
    for (NSData *key in keys) valid = valid && [key isKindOfClass:[NSData class]] && key.length == 32;
    if (!valid || !_available) {
        [self finishLookupBatch:batch
                          blobs:nil
                          error:SZFriendsHostOnlineMakeError(valid ? SZFriendsHostOnlineErrorUnavailable
                                                                   : SZFriendsHostOnlineErrorInvalid,
                                                             @"A lookup needs 32-byte keys and an online host.")];
        return;
    }
    batch.blobs = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; i++) [batch.blobs addObject:[NSNull null]];
    for (NSUInteger offset = 0; offset < keys.count; offset += SZFriendsHostLookupKeysMax) {
        NSUInteger count = MIN(SZFriendsHostLookupKeysMax, keys.count - offset);
        SZFriendsHostPending *pending = [[SZFriendsHostPending alloc] init];
        pending.kind = @"lookup";
        pending.batch = batch;
        pending.offset = offset;
        pending.count = count;
        batch.outstanding += 1;
        NSMutableArray<NSString *> *encoded = [NSMutableArray array];
        for (NSData *key in [keys subarrayWithRange:NSMakeRange(offset, count)]) {
            [encoded addObject:SZFriendsHostBase64URLEncode(key)];
        }
        NSInteger req = [self addPending:pending];
        [self sendType:@"rdv_lookup" fields:@{@"req" : @(req), @"keys" : encoded}];
    }
}

- (void)receiveRecords:(NSDictionary<NSString *, id> *)message {
    SZFriendsHostPending *pending = [self takePending:message[@"req"] kind:@"lookup"];
    SZFriendsHostLookupBatch *batch = pending.batch;
    if (batch == nil || batch.completion == nil) return;
    NSArray *records = [message[@"records"] isKindOfClass:[NSArray class]] ? message[@"records"] : nil;
    if (records == nil) {
        BOOL limited = [message[@"reason"] isEqual:@"rate_limited"];
        [self finishLookupBatch:batch
                          blobs:nil
                          error:SZFriendsHostOnlineMakeError(limited ? SZFriendsHostOnlineErrorRateLimited
                                                                     : SZFriendsHostOnlineErrorUnavailable,
                                                             @"The Friends host refused a lookup.")];
        return;
    }
    for (NSUInteger i = 0; i < pending.count; i++) {
        NSData *blob = i < records.count ? SZFriendsHostBase64URLDecode(records[i], SZFriendsHostSealedRecordLength)
                                         : nil;
        if (blob == nil || records.count != pending.count) {
            [self finishLookupBatch:batch
                              blobs:nil
                              error:SZFriendsHostOnlineMakeError(SZFriendsHostOnlineErrorUnavailable,
                                                                 @"The Friends host answered a lookup wrongly.")];
            return;
        }
        batch.blobs[pending.offset + i] = blob;
    }
    batch.outstanding -= 1;
    if (batch.outstanding == 0) [self finishLookupBatch:batch blobs:batch.blobs error:nil];
}

// Completes a lookup once; any later answer for the same batch finds no completion.
- (void)finishLookupBatch:(SZFriendsHostLookupBatch *)batch blobs:(NSArray *)blobs error:(NSError *)error {
    void (^completion)(NSArray<NSData *> *, NSError *) = batch.completion;
    batch.completion = nil;
    if (completion) completion(blobs ? [blobs copy] : nil, error);
}

@end
