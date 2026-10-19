// Downloads that carry on after their connection drops (the relay ends every session after an hour; networks
// change): the opener connects again with fresh nonces and keys and asks for the chunks from the first one it has not
// written; the sender starts there, after hashing the bytes before it again; an app's file keeps arriving into the
// same transfer (ADR 0001). And an opening the host says has ended (revoked or expired) ends Ended at once.

#import "SZFLinksTestSupport.h"

#import <sodium.h>

#import "service/identity/SZFriendsIdentity.h"

// A byte stream that keeps what is written to it; the test hands it records through onData.
@interface SZFLFakeStream : NSObject <SZFriendsByteStream>
@property(nonatomic, readonly) NSMutableArray<NSData *> *written;
@property(nonatomic) BOOL closed;
@end

@implementation SZFLFakeStream
@synthesize onData = _onData;
@synthesize onClose = _onClose;

- (instancetype)init {
    if ((self = [super init])) _written = [NSMutableArray array];
    return self;
}

- (NSUInteger)preferredWriteSize {
    return 65536;
}

- (void)startWithQueue:(dispatch_queue_t)queue {
    (void)queue;
}

- (void)writeData:(NSData *)data completion:(void (^)(NSError *))completion {
    [_written addObject:data];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
}

- (void)close {
    self.closed = YES;
}

@end

// Forwards to another sink and counts what it hears; past `dropAt` bytes it runs `drop` once.
@interface SZFLWatchingSink : NSObject <SZFriendsLinkSink>
@property(nonatomic, strong) id<SZFriendsLinkSink> inner;
@property(nonatomic) NSUInteger metadataCalls;
@property(nonatomic) uint64_t received, dropAt;
@property(nonatomic, copy, nullable) void (^drop)(void);
@end

@implementation SZFLWatchingSink
- (BOOL)linkDidReceiveMetadata:(SZFriendsLinkMetadata *)metadata {
    self.metadataCalls += 1;
    return [self.inner linkDidReceiveMetadata:metadata];
}

- (BOOL)linkDidReceiveBytes:(NSData *)bytes atOffset:(uint64_t)offset {
    self.received += bytes.length;
    if (self.drop && self.received > self.dropAt) {
        void (^drop)(void) = self.drop;
        self.drop = nil;
        dispatch_async(dispatch_get_main_queue(), drop);
    }
    return [self.inner linkDidReceiveBytes:bytes atOffset:offset];
}

- (BOOL)linkDidFinish {
    return [self.inner linkDidFinish];
}

- (void)linkDidStop:(SZFriendsLinkOutcome)outcome {
    [self.inner linkDidStop:outcome];
}
@end

static NSData *SHA256(NSData *data) {
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    crypto_hash_sha256(digest.mutableBytes, data.bytes, data.length);
    return digest;
}

static NSData *Chunk(NSData *file, uint64_t index) {
    uint64_t at = index * SZFriendsLinkChunkBytes;
    NSUInteger length = (NSUInteger)MIN(SZFriendsLinkChunkBytes, file.length - at);
    return [file subdataWithRange:NSMakeRange((NSUInteger)at, length)];
}

static NSData *Control(NSData *key, uint64_t index, NSDictionary *message) {
    return SZFriendsLinkSealRecord(key, SZFriendsLinkRecordControl, index,
                                   [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL]);
}

static NSDictionary *OpenControl(NSData *key, uint64_t index, NSData *record) {
    NSData *plain = SZFriendsLinkOpenRecord(key, @[ @(SZFriendsLinkRecordControl) ], index, record, NULL);
    return plain ? [NSJSONSerialization JSONObjectWithData:plain options:0 error:NULL] : nil;
}

static SZFriendsLinkMetadata *MetadataFor(NSData *file) {
    SZFriendsLinkMetadata *metadata = [SZFriendsLinkMetadata new];
    metadata.name = @"Site photos.pdf";
    metadata.size = file.length;
    metadata.mediaType = @"application/pdf";
    metadata.sha256 = SHA256(file);
    return metadata;
}

// The app's download through the helper's own opener: the connection is cut a third of the way in, and the file still
// arrives whole into one transfer, after a second setup and connection.
static void TestAnAppDownloadCarriesOnAfterItsConnectionDrops(void) {
    SZFLSenderWorld *sender = SZFLSender(@"resume-sender");
    NSData *bytes = SZFLRandom(3 * 1024 * 1024 + 77);
    SZFriendsDownloadLinkPayload *payload = SZFLMakeLink(sender, bytes, NULL);
    NSString *mine = SZFLTemporaryDirectory(@"resume-opener");
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:mine error:NULL];
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store stateDirectory:mine];
    SZFLWatchingSink *sink = [SZFLWatchingSink new];
    sink.inner = [[SZFriendsLinkReceiver alloc] initWithStore:store transfers:transfers
                                                  ownIdentity:SZFLNewIdentity().publicKey
                                                       linkID:payload.linkID];
    SZFLCountingTransport *transport = [[SZFLCountingTransport alloc] initWithTransport:SZFLLoopbackTransport()];
    sink.dropAt = bytes.length / 3;
    sink.drop = ^{
        for (id<SZFriendsOnlineConnection> connection in [transport.connections copy]) [connection close];
    };
    SZFriendsLinkEnvironment *environment = SZFLEnvironment(transport);
    environment.stallTimeout = 2; // whichever notices first: the closed channel, or the silence
    SZFriendsLinkOpening *opening = [[SZFriendsLinkOpening alloc] initWithLinkID:payload.linkID secret:payload.secret
                                                                     environment:environment sink:sink];
    __block NSInteger outcome = -1;
    __block NSUInteger opens = 0;
    SZFriendsLinkService *service = sender.service;
    [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
        opens += 1;
        NSArray<SZFLChannel *> *pair = [SZFLChannel pair];
        [service receiveOpenOfLinkID:payload.linkID channel:pair[1] payload:hello];
        done(pair[0], YES);
    }
        completion:^(SZFriendsLinkOutcome result) { outcome = result; }];
    SZFL_CHECK(SZFLWaitUntil(10, ^BOOL { return outcome >= 0; }), @"the opening ends");
    SZFL_CHECK(outcome == SZFriendsLinkOutcomeDone, @"outcome %ld", (long)outcome);
    SZFL_CHECK(opens == 2 && transport.opened == 2, @"a second setup and connection: %lu, %lu", (unsigned long)opens,
               (unsigned long)transport.opened);
    SZFL_CHECK(sink.metadataCalls == 1, @"one transfer, made once: %lu", (unsigned long)sink.metadataCalls);
    SZFL_CHECK(sink.received == bytes.length, @"every byte once: %llu", sink.received);
    SZFriendsPersonRecord *person = [store personWithIdentityKey:sender.identity.publicKey];
    SZFriendsTransferRecord *transfer = [transfers transfersInConversation:person.conversationID].firstObject;
    SZFL_CHECK(transfer.state == SZFriendsTransferStateReceived &&
                   [[NSData dataWithContentsOfFile:transfer.receivedPath] isEqualToData:bytes],
               @"the transfer's file is whole: %@", transfer.receivedPath);
    SZFLSpin(1.5);
    SZFL_CHECK([sender.store downloadLinkWithID:payload.linkID].downloads == 1, @"one download counted");
}

// A connection that goes quiet (no close, as a relay that ended a session may leave it) counts as dropped after the
// stall timeout, without telling the sink; the next download carries on from the first chunk not written, with its
// own key, and the sink hears the metadata only once. Another file's metadata on the new connection ends it.
static void TestAQuietDownloadCarriesOnFromItsNextChunk(void) {
    NSData *file = SZFLRandom(3 * SZFriendsLinkChunkBytes + 100);
    SZFriendsLinkMetadata *metadata = MetadataFor(file);
    NSData *key1 = SZFLRandom(32), *key2 = SZFLRandom(32);
    SZFLSink *sink = [SZFLSink new];
    SZFLFakeStream *first = [SZFLFakeStream new];
    SZFriendsLinkDownload *one = [[SZFriendsLinkDownload alloc] initWithStream:first contentKey:key1 sink:sink
                                                                         queue:dispatch_get_main_queue()
                                                                  resumingFrom:nil];
    one.stallTimeout = 0.3;
    __block NSInteger outcome1 = -1;
    one.onFinish = ^(SZFriendsLinkOutcome outcome) { outcome1 = outcome; };
    [one start];
    first.onData(SZFriendsLinkSealRecord(key1, SZFriendsLinkRecordMetadata, 0, [metadata recordPlaintext]));
    NSDictionary *start = OpenControl(key1, 0, first.written.firstObject);
    SZFL_CHECK([start[@"t"] isEqual:@"start"] && start[@"from"] == nil, @"a first start: %@", start);
    first.onData(SZFriendsLinkSealRecord(key1, SZFriendsLinkRecordChunk, 0, Chunk(file, 0)));
    first.onData(SZFriendsLinkSealRecord(key1, SZFriendsLinkRecordChunk, 1, Chunk(file, 1)));
    SZFL_CHECK(SZFLWaitUntil(3, ^BOOL { return outcome1 >= 0; }), @"silence ends it");
    SZFL_CHECK(outcome1 == SZFriendsLinkOutcomeFailed && one.lost && one.nextChunk == 2 && first.closed,
               @"lost at chunk %llu", one.nextChunk);
    SZFL_CHECK(sink.stopped == -1 && sink.bytes.length == 2 * SZFriendsLinkChunkBytes, @"the sink was not told");
    SZFriendsLinkMetadata *heard = sink.metadata;

    SZFLFakeStream *second = [SZFLFakeStream new];
    SZFriendsLinkDownload *two = [[SZFriendsLinkDownload alloc] initWithStream:second contentKey:key2 sink:sink
                                                                         queue:dispatch_get_main_queue()
                                                                  resumingFrom:one];
    __block NSInteger outcome2 = -1;
    two.onFinish = ^(SZFriendsLinkOutcome outcome) { outcome2 = outcome; };
    [two start];
    second.onData(SZFriendsLinkSealRecord(key2, SZFriendsLinkRecordMetadata, 0, [metadata recordPlaintext]));
    NSDictionary *resume = OpenControl(key2, 0, second.written.firstObject);
    SZFL_CHECK([resume[@"t"] isEqual:@"start"] && [resume[@"from"] isEqual:@2] && [resume[@"upto"] isEqual:@66],
               @"carries on from chunk 2, under the new key: %@", resume);
    SZFL_CHECK(OpenControl(key1, 0, second.written.firstObject) == nil, @"not under the old one");
    second.onData(SZFriendsLinkSealRecord(key2, SZFriendsLinkRecordChunk, 2, Chunk(file, 2)));
    second.onData(SZFriendsLinkSealRecord(key2, SZFriendsLinkRecordFinal, 3, Chunk(file, 3)));
    SZFL_CHECK(outcome2 == SZFriendsLinkOutcomeDone && [sink.bytes isEqualToData:file] && sink.finished,
               @"outcome %ld, %lu bytes", (long)outcome2, (unsigned long)sink.bytes.length);
    SZFL_CHECK(sink.metadata == heard, @"the sink heard the metadata once");

    SZFLSink *other = [SZFLSink new];
    SZFLFakeStream *third = [SZFLFakeStream new];
    SZFriendsLinkDownload *three = [[SZFriendsLinkDownload alloc] initWithStream:third contentKey:key2 sink:other
                                                                           queue:dispatch_get_main_queue()
                                                                    resumingFrom:one];
    __block NSInteger outcome3 = -1;
    three.onFinish = ^(SZFriendsLinkOutcome outcome) { outcome3 = outcome; };
    [three start];
    third.onData(SZFriendsLinkSealRecord(key2, SZFriendsLinkRecordMetadata, 0,
                                         [MetadataFor(SZFLRandom(file.length)) recordPlaintext]));
    SZFL_CHECK(outcome3 == SZFriendsLinkOutcomeFailed && !three.lost && other.stopped == SZFriendsLinkOutcomeFailed &&
                   third.written.count == 0,
               @"another file: outcome %ld", (long)outcome3);
}

static SZFriendsLinkUpload *Upload(SZFLFakeStream *stream, SZFriendsDownloadLinkRecord *link, NSData *key,
                                   NSInteger *finished) {
    SZFriendsLinkMetadata *metadata = [SZFriendsLinkMetadata new];
    metadata.name = link.fileName;
    metadata.size = link.size;
    metadata.mediaType = @"application/pdf";
    metadata.sha256 = link.sha256;
    SZFriendsLinkUpload *upload = [[SZFriendsLinkUpload alloc] initWithStream:stream link:link metadata:metadata
                                                                   contentKey:key queue:dispatch_get_main_queue()];
    *finished = -1;
    upload.onFinish = ^(BOOL downloaded) { *finished = downloaded; };
    [upload start];
    return upload;
}

// The sender starts at the chunk the opener asks for, after hashing every byte before it again: the final chunk goes
// only when the whole file is still the one the link was made for. A chunk the file does not have ends the upload.
static void TestTheSenderStartsWhereTheOpenerAsks(void) {
    NSString *path = [SZFLTemporaryDirectory(@"upload-from") stringByAppendingPathComponent:@"Site photos.pdf"];
    NSData *file = SZFLRandom(4 * SZFriendsLinkChunkBytes + 10);
    [file writeToFile:path atomically:NO];
    SZFriendsDownloadLinkRecord *link = [SZFriendsDownloadLinkRecord new];
    link.linkID = SZFLRandom(16);
    link.fileName = @"Site photos.pdf";
    link.size = file.length;
    link.sha256 = SHA256(file);
    link.snapshotPath = path;
    NSData *key = SZFLRandom(32);
    NSInteger finished = -1;
    SZFLFakeStream *stream = [SZFLFakeStream new];
    SZFriendsLinkUpload *upload = Upload(stream, link, key, &finished);
    stream.onData(Control(key, 0, @{@"t" : @"start", @"from" : @3, @"upto" : @67}));
    SZFL_CHECK(SZFLWaitUntil(5, ^BOOL { return stream.written.count == 3; }), @"%lu records",
               (unsigned long)stream.written.count);
    SZFriendsLinkRecordType type = 0;
    NSData *three = SZFriendsLinkOpenRecord(key, @[ @(SZFriendsLinkRecordChunk) ], 3, stream.written[1], &type);
    NSData *four = SZFriendsLinkOpenRecord(key, @[ @(SZFriendsLinkRecordFinal) ], 4, stream.written[2], &type);
    SZFL_CHECK([three isEqualToData:Chunk(file, 3)] && [four isEqualToData:Chunk(file, 4)],
               @"chunk 3, then the final chunk 4");
    stream.onData(Control(key, 1, @{@"t" : @"done", @"ok" : @YES}));
    SZFL_CHECK(finished == YES, @"the opener's done counts");
    [upload close];

    // The bytes before the start changed since the link was made: "changed", never the final chunk.
    NSMutableData *edited = [file mutableCopy];
    ((uint8_t *)edited.mutableBytes)[10] ^= 0xff;
    [edited writeToFile:path atomically:NO];
    SZFLFakeStream *again = [SZFLFakeStream new];
    upload = Upload(again, link, key, &finished);
    again.onData(Control(key, 0, @{@"t" : @"start", @"from" : @3, @"upto" : @67}));
    SZFL_CHECK(SZFLWaitUntil(5, ^BOOL { return again.written.count == 3; }), @"%lu",
               (unsigned long)again.written.count);
    NSData *end = SZFriendsLinkOpenRecord(key, @[ @(SZFriendsLinkRecordEnd) ], 0, again.written.lastObject, NULL);
    SZFL_CHECK([end isEqualToData:[@"{\"reason\":\"changed\"}" dataUsingEncoding:NSUTF8StringEncoding]],
               @"the end says changed");
    [upload close];

    for (id from in @[ @5, @(-1), @1.5, @"2" ]) {
        SZFLFakeStream *bad = [SZFLFakeStream new];
        upload = Upload(bad, link, key, &finished);
        bad.onData(Control(key, 0, @{@"t" : @"start", @"from" : from, @"upto" : @64}));
        SZFLSpin(0.2);
        SZFL_CHECK(finished == NO && bad.written.count == 1, @"from %@: nothing but the metadata", from);
        [upload close];
    }
}

// The host answered that nobody holds the link and its sender ended it: the opening ends Ended (the app's not_found),
// not Unavailable (link_offline), and asks nothing more.
static void TestAnOpeningTheHostSaysEndedIsEnded(void) {
    for (int told = 0; told < 2; told++) {
        SZFLSink *sink = [SZFLSink new];
        SZFriendsLinkEnvironment *environment = SZFLEnvironment(SZFLLoopbackTransport());
        SZFriendsLinkOpening *opening = [[SZFriendsLinkOpening alloc] initWithLinkID:SZFLRandom(16)
                                                                              secret:SZFLRandom(32)
                                                                         environment:environment
                                                                                sink:sink];
        __block NSInteger outcome = -1;
        __weak SZFriendsLinkOpening *weakOpening = opening;
        [opening startWithOpen:^(NSData *hello, void (^done)(id, BOOL)) {
            (void)hello;
            if (told) [weakOpening noteLinkEnded];
            done(nil, NO);
        }
            completion:^(SZFriendsLinkOutcome result) { outcome = result; }];
        SZFL_CHECK(SZFLWaitUntil(2, ^BOOL { return outcome >= 0; }), @"ends at once");
        SZFriendsLinkOutcome expected = told ? SZFriendsLinkOutcomeEnded : SZFriendsLinkOutcomeUnavailable;
        SZFL_CHECK(outcome == expected && sink.stopped == expected, @"told %d: outcome %ld", told, (long)outcome);
    }
}

void SZFLRunResumeTests(void) {
    TestAQuietDownloadCarriesOnFromItsNextChunk();
    TestTheSenderStartsWhereTheOpenerAsks();
    TestAnOpeningTheHostSaysEndedIsEnded();
    TestAnAppDownloadCarriesOnAfterItsConnectionDrops();
}
