// friends-sync-check, ADR 0016: the AGAIN exchange on its own. A file copies whole and is handed over only when its
// digest matches; a cut session resumes from what arrived; "not here" ends the request and "not now" leaves it; a file
// that changed while it was read is not kept; the server copies one file at a time; a message that does not decode
// ends the session.

#import <sodium.h>

#import "SZFriendsSyncTestSupport.h"
#import "service/sync/SZFriendsAgain.h"

static NSString *const SZFAID = @"0123456789abcdef0123456789abcdef";

static NSData *SZFAContent(NSUInteger size, uint8_t salt) {
    NSMutableData *bytes = [NSMutableData dataWithLength:size];
    for (NSUInteger i = 0; i < size; i++) ((uint8_t *)bytes.mutableBytes)[i] = (uint8_t)(i * 13 + salt);
    return bytes;
}

static SZFriendsAgainFile *SZFAFile(NSString *transferID, NSData *content) {
    SZFriendsAgainFile *file = [[SZFriendsAgainFile alloc] init];
    file.transferID = transferID;
    file.size = content.length;
    uint8_t digest[32];
    crypto_generichash(digest, sizeof digest, content.bytes, content.length, NULL, 0);
    file.digest = [NSData dataWithBytes:digest length:32];
    return file;
}

// A requester and a server joined by queues; `cutAfter` PART messages reach the requester before the link drops.
@interface SZFAPair : NSObject
@property(nonatomic, strong) SZFriendsAgainExchange *requester, *server;
@property(nonatomic, strong) NSMutableArray<NSData *> *toRequester, *toServer;
@property(nonatomic) NSInteger cutAfter;
@property(nonatomic, strong) NSMutableArray<NSString *> *arrived, *gone;
@property(nonatomic, copy) NSString *servedPath;
@property(nonatomic) SZFriendsAgainAnswer answer;
@property(nonatomic) uint64_t firstOffset;
@end

@implementation SZFAPair
- (void)run {
    while (self.toRequester.count > 0 || self.toServer.count > 0) {
        if (self.toServer.count > 0) {
            NSData *message = self.toServer.firstObject;
            [self.toServer removeObjectAtIndex:0];
            SZFSExpect([self.server receiveMessage:message], @"the server reads a WANT");
        }
        if (self.toRequester.count > 0) {
            NSData *message = self.toRequester.firstObject;
            [self.toRequester removeObjectAtIndex:0];
            if (((const uint8_t *)message.bytes)[0] == 2 && self.cutAfter >= 0 && self.cutAfter-- == 0) return;
            SZFSExpect([self.requester receiveMessage:message], @"the requester reads an answer");
        }
    }
}
@end

static SZFAPair *SZFAConnect(NSString *partial, NSArray<SZFriendsAgainFile *> *wanted) {
    SZFAPair *pair = [[SZFAPair alloc] init];
    pair.toRequester = [NSMutableArray array];
    pair.toServer = [NSMutableArray array];
    pair.arrived = [NSMutableArray array];
    pair.gone = [NSMutableArray array];
    pair.cutAfter = -1;
    pair.firstOffset = UINT64_MAX;
    __weak SZFAPair *weak = pair;
    pair.requester = [[SZFriendsAgainExchange alloc] initWithPartialDirectory:partial send:^(NSData *m) {
        SZFAPair *strong = weak;
        if (strong.firstOffset == UINT64_MAX && m.length == 27) {
            uint64_t at = 0;
            for (int i = 17; i < 25; i++) at = (at << 8) | ((const uint8_t *)m.bytes)[i];
            strong.firstOffset = at;
        }
        [strong.toServer addObject:m];
    }];
    pair.server = [[SZFriendsAgainExchange alloc] initWithPartialDirectory:partial send:^(NSData *m) {
        [weak.toRequester addObject:m];
    }];
    NSMutableArray<SZFriendsAgainFile *> *left = [wanted mutableCopy];
    pair.requester.wanted = ^NSArray<SZFriendsAgainFile *> * { return left; };
    pair.requester.arrived = ^(SZFriendsAgainFile *file, NSString *path) {
        [weak.arrived addObject:[NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL]
                                    ?: @""];
        [left removeObject:file];
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    };
    pair.requester.notThere = ^(NSString *transferID) {
        [weak.gone addObject:transferID];
        [left filterUsingPredicate:[NSPredicate predicateWithFormat:@"transferID != %@", transferID]];
    };
    pair.server.servePath = ^NSString *_Nullable(NSString *transferID, uint64_t *size, SZFriendsAgainAnswer *answer) {
        SZFAPair *strong = weak;
        *answer = strong.answer;
        if (strong.servedPath == nil || ![transferID isEqualToString:SZFAID]) return nil;
        *size = [[NSFileManager.defaultManager attributesOfItemAtPath:strong.servedPath error:NULL] fileSize];
        return strong.servedPath;
    };
    return pair;
}

static void TestCopiesWholeAndResumes(void) {
    NSString *directory = SZFSTemporaryDirectory(@"again");
    NSString *partial = [directory stringByAppendingPathComponent:@"partial"];
    NSString *source = [directory stringByAppendingPathComponent:@"Site photos.pdf"];
    NSData *content = SZFAContent(30 * SZFriendsSyncFilePartMax + 77, 3);
    [content writeToFile:source atomically:YES];
    SZFriendsAgainFile *file = SZFAFile(SZFAID, content);

    SZFAPair *cut = SZFAConnect(partial, @[ file ]);
    cut.servedPath = source;
    cut.cutAfter = 5;
    [cut.requester pump];
    [cut run];
    [cut.requester stop];
    SZFSExpect(cut.arrived.count == 0 && cut.gone.count == 0, @"cut mid-copy: nothing yet");

    SZFAPair *again = SZFAConnect(partial, @[ file ]);
    again.servedPath = source;
    [again.requester pump];
    [again run];
    SZFSExpect(again.firstOffset == 5 * SZFriendsSyncFilePartMax, @"resumed from what arrived: %llu",
               again.firstOffset);
    SZFSExpect(again.arrived.count == 1 &&
                   [again.arrived[0] isEqualToString:[[NSString alloc] initWithData:content
                                                                           encoding:NSISOLatin1StringEncoding]],
               @"the whole file arrived");
}

static void TestAnswersAndChanges(void) {
    NSString *directory = SZFSTemporaryDirectory(@"again-answers");
    NSString *partial = [directory stringByAppendingPathComponent:@"partial"];
    NSString *source = [directory stringByAppendingPathComponent:@"plan.pdf"];
    NSData *content = SZFAContent(3 * SZFriendsSyncFilePartMax, 9);
    [content writeToFile:source atomically:YES];
    SZFriendsAgainFile *file = SZFAFile(SZFAID, content);

    SZFAPair *notNow = SZFAConnect(partial, @[ file ]);
    notNow.answer = SZFriendsAgainAnswerNotNow;
    [notNow.requester pump];
    [notNow run];
    SZFSExpect(notNow.gone.count == 0 && notNow.arrived.count == 0, @"not now leaves it asked");

    SZFAPair *notHere = SZFAConnect(partial, @[ file ]);
    [notHere.requester pump];
    [notHere run];
    SZFSExpect([notHere.gone isEqualToArray:@[ SZFAID ]], @"not here ends it");

    // The friend's file has the same size and other bytes: what arrives is not kept.
    [SZFAContent(content.length, 200) writeToFile:source atomically:YES];
    SZFAPair *changed = SZFAConnect(partial, @[ file ]);
    changed.servedPath = source;
    [changed.requester pump];
    [changed run];
    NSString *partialFile = [partial stringByAppendingPathComponent:[@"again-" stringByAppendingString:SZFAID]];
    SZFSExpect([changed.gone isEqualToArray:@[ SZFAID ]] && changed.arrived.count == 0 &&
                   ![NSFileManager.defaultManager fileExistsAtPath:partialFile],
               @"a changed file is not kept");
}

static void TestServerLimits(void) {
    NSString *directory = SZFSTemporaryDirectory(@"again-limits");
    NSString *source = [directory stringByAppendingPathComponent:@"big.pdf"];
    [SZFAContent(40 * SZFriendsSyncFilePartMax, 1) writeToFile:source atomically:YES];
    NSMutableArray<NSData *> *sent = [NSMutableArray array];
    SZFriendsAgainExchange *server = [[SZFriendsAgainExchange alloc]
        initWithPartialDirectory:directory send:^(NSData *m) { [sent addObject:m]; }];
    server.servePath = ^NSString *_Nullable(NSString *transferID, uint64_t *size, SZFriendsAgainAnswer *answer) {
        (void)transferID;
        *answer = SZFriendsAgainAnswerNotHere;
        *size = 40 * SZFriendsSyncFilePartMax;
        return source;
    };
    NSMutableData *want = [NSMutableData dataWithBytes:(uint8_t[]){1} length:1];
    for (NSUInteger i = 0; i < 16; i++) [want appendBytes:(uint8_t[]){(uint8_t)(i * 17)} length:1];
    [want appendData:[NSMutableData dataWithLength:8]];
    [want appendBytes:(uint8_t[]){0xff, 0xff} length:2];
    SZFSExpect([server receiveMessage:want] && sent.count == 16, @"at most 16 parts per WANT: %lu",
               (unsigned long)sent.count);
    [sent removeAllObjects];
    NSMutableData *other = [want mutableCopy];
    ((uint8_t *)other.mutableBytes)[1] ^= 0xff;
    SZFSExpect([server receiveMessage:other] && sent.count == 1 && sent[0].length == 18 &&
                   ((const uint8_t *)sent[0].bytes)[0] == 3 && ((const uint8_t *)sent[0].bytes)[17] == 1,
               @"another file while one is unfinished: not now");
    SZFSExpect(![server receiveMessage:[want subdataWithRange:NSMakeRange(0, 20)]], @"a short WANT ends the session");
}

void SZFSRunAgainTests(void) {
    TestCopiesWholeAndResumes();
    TestAnswersAndChanges();
    TestServerLimits();
}
