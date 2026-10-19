// The run-loop byte stream (what L2CAP channels become) over in-memory stream pairs, and the network adapter's
// pure pieces: TXT records, instance names, interface classification and state.

#import "SZFriendsDiscoveryTestSupport.h"

#import "service/discovery/SZFriendsNetworkAdapterInternal.h"

static void MakePipe(NSInputStream **input, NSOutputStream **output) {
    CFReadStreamRef read = NULL;
    CFWriteStreamRef write = NULL;
    CFStreamCreateBoundPair(kCFAllocatorDefault, &read, &write, 8192);
    *input = CFBridgingRelease(read);
    *output = CFBridgingRelease(write);
}

static void TestRunLoopStream(void) {
    NSInputStream *aIn, *bIn;
    NSOutputStream *aOut, *bOut;
    MakePipe(&bIn, &aOut); // A writes, B reads
    MakePipe(&aIn, &bOut); // B writes, A reads
    SZFriendsRunLoopByteStream *a = [[SZFriendsRunLoopByteStream alloc] initWithInputStream:aIn
                                                                               outputStream:aOut
                                                                                      owner:nil
                                                                         preferredWriteSize:4096];
    SZFriendsRunLoopByteStream *b = [[SZFriendsRunLoopByteStream alloc] initWithInputStream:bIn
                                                                               outputStream:bOut
                                                                                      owner:nil
                                                                         preferredWriteSize:4096];
    CHECK(a.preferredWriteSize == 4096);
    dispatch_queue_t queue = dispatch_queue_create("test.stream", DISPATCH_QUEUE_SERIAL);
    NSMutableData *atA = [NSMutableData data], *atB = [NSMutableData data];
    __block NSUInteger completions = 0, aCloses = 0, bCloses = 0;
    __block NSError *bCloseError = [NSError errorWithDomain:@"unset" code:0 userInfo:nil];
    a.onData = ^(NSData *data) {
        [atA appendData:data];
    };
    b.onData = ^(NSData *data) {
        [atB appendData:data];
    };
    a.onClose = ^(NSError *error) {
        (void)error;
        aCloses++;
    };
    b.onClose = ^(NSError *error) {
        bCloseError = error;
        bCloses++;
    };
    [a startWithQueue:queue];
    [b startWithQueue:queue];

    // Larger than the pipe's buffer, so writes wait for space and must keep their order.
    NSMutableData *big = [NSMutableData dataWithLength:100000];
    for (NSUInteger i = 0; i < big.length; i++) ((uint8_t *)big.mutableBytes)[i] = (uint8_t)(i * 7);
    [a writeData:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]
      completion:^(NSError *error) {
          if (!error) completions++;
      }];
    [b writeData:big
      completion:^(NSError *error) {
          if (!error) completions++;
      }];
    CHECK(SZFTestWait(queue, 5, ^BOOL {
        return atB.length == 5 && atA.length == big.length && completions == 2;
    }), "B got %lu, A got %lu", (unsigned long)atB.length, (unsigned long)atA.length);
    dispatch_sync(queue, ^{
        CHECK([atA isEqual:big] && [atB isEqual:[@"hello" dataUsingEncoding:NSUTF8StringEncoding]]);
    });

    // A closes after one last write: B gets the bytes, then the end of the stream; A is not told about its own close.
    [a writeData:[@"bye" dataUsingEncoding:NSUTF8StringEncoding] completion:nil];
    [a close];
    CHECK(SZFTestWait(queue, 5, ^BOOL {
        return bCloses == 1;
    }));
    dispatch_sync(queue, ^{
        CHECK(bCloseError == nil && atB.length == 8 && aCloses == 0, "end of stream is a clean close: %@ %lu %lu",
              bCloseError, (unsigned long)atB.length, (unsigned long)aCloses);
    });
    __block NSError *late = nil;
    [a writeData:[NSData dataWithBytes:"x" length:1]
      completion:^(NSError *error) {
          late = error;
      }];
    CHECK(SZFTestWait(queue, 5, ^BOOL {
        return late != nil;
    }), "writing after close fails rather than vanishing");
    [b close];
}

static void TestTXT(void) {
    NSData *tag = SZFTestData(@"0102030405060708");
    NSArray<NSData *> *callbacks = @[ SZFTestData(@"1111111111111111"), SZFTestData(@"2222222222222222") ];
    NSDictionary<NSString *, NSData *> *hidden = SZFriendsNetworkTXTFields(tag, callbacks, NO);
    CHECK([hidden[@"v"] isEqual:[@"1" dataUsingEncoding:NSASCIIStringEncoding]]);
    CHECK([hidden[@"t"] isEqual:[@"0102030405060708" dataUsingEncoding:NSASCIIStringEncoding]]);
    CHECK([hidden[@"c"] isEqual:[@"11111111111111112222222222222222" dataUsingEncoding:NSASCIIStringEncoding]]);
    CHECK(hidden[@"p"] == nil);
    NSData *parsedTag = nil;
    NSArray<NSData *> *parsedCallbacks = nil;
    BOOL isPublic = YES;
    CHECK(SZFriendsNetworkParseTXT(hidden, &parsedTag, &parsedCallbacks, &isPublic));
    CHECK([parsedTag isEqual:tag] && [parsedCallbacks isEqual:callbacks] && !isPublic);

    NSDictionary<NSString *, NSData *> *publicEntry = SZFriendsNetworkTXTFields(tag, callbacks, YES);
    CHECK(publicEntry.count == 2 && publicEntry[@"t"] == nil && publicEntry[@"c"] == nil, "a public entry has no tag");
    CHECK(SZFriendsNetworkParseTXT(publicEntry, &parsedTag, &parsedCallbacks, &isPublic) && isPublic &&
          parsedTag == nil);
    CHECK(SZFriendsNetworkTXTFields(nil, @[], NO).count == 1);

    NSData *(^ascii)(NSString *) = ^NSData *(NSString *s) {
        return [s dataUsingEncoding:NSASCIIStringEncoding];
    };
    CHECK(!SZFriendsNetworkParseTXT(@{@"v" : ascii(@"2"), @"t" : ascii(@"0102030405060708")}, &parsedTag,
                                    &parsedCallbacks, &isPublic),
          "a later version is ignored, not misread");
    CHECK(!SZFriendsNetworkParseTXT(@{}, &parsedTag, &parsedCallbacks, &isPublic));
    CHECK(SZFriendsNetworkParseTXT(@{@"v" : ascii(@"1"), @"t" : ascii(@"01020304zz060708"), @"c" : ascii(@"11")},
                                   &parsedTag, &parsedCallbacks, &isPublic) &&
              parsedTag == nil && parsedCallbacks.count == 0,
          "malformed values read as absent");
    NSString *six = [@"" stringByPaddingToLength:16 * 6 withString:@"ab" startingAtIndex:0];
    CHECK(SZFriendsNetworkParseTXT(@{@"v" : ascii(@"1"), @"c" : ascii(six)}, &parsedTag, &parsedCallbacks, &isPublic) &&
          parsedCallbacks.count == 4, "at most 4 callback tags are taken from anyone");
    NSString *bad = [@"1111111111111111" stringByAppendingString:@"zz11111111111111"];
    CHECK(SZFriendsNetworkParseTXT(@{@"v" : ascii(@"1"), @"c" : ascii(bad)}, &parsedTag, &parsedCallbacks, &isPublic) &&
          parsedCallbacks.count == 0);

    NSString *name1 = SZFriendsRandomInstanceName(), *name2 = SZFriendsRandomInstanceName();
    CHECK(name1.length == 16 && ![name1 isEqual:name2] && SZFriendsDataFromHex(name1) != nil,
          "random, never the Mac's name");

    CHECK(SZFriendsRouteForInterfaceName(@"awdl0") == SZFriendsRouteMethodPeerToPeerWiFi);
    CHECK(SZFriendsRouteForInterfaceName(@"llw0") == SZFriendsRouteMethodPeerToPeerWiFi);
    CHECK(SZFriendsRouteForInterfaceName(@"en0") == SZFriendsRouteMethodLAN);
    CHECK(SZFriendsRouteForInterfaceName(@"lo0") == SZFriendsRouteMethodLAN);

    CHECK(SZFriendsNetworkAdapterState(NO, YES, YES, YES, YES, YES) == SZFriendsAdapterStateNotAsked);
    CHECK(SZFriendsNetworkAdapterState(YES, YES, YES, YES, YES, YES) == SZFriendsAdapterStateDenied);
    CHECK(SZFriendsNetworkAdapterState(YES, NO, YES, YES, YES, YES) == SZFriendsAdapterStateRadioOff);
    CHECK(SZFriendsNetworkAdapterState(YES, NO, NO, YES, YES, YES) == SZFriendsAdapterStateUnavailable);
    CHECK(SZFriendsNetworkAdapterState(YES, NO, NO, NO, YES, NO) == SZFriendsAdapterStateStarting);
    CHECK(SZFriendsNetworkAdapterState(YES, NO, NO, NO, YES, YES) == SZFriendsAdapterStateWorking);
    CHECK([SZFriendsBonjourServiceType isEqual:@"_szfriends._tcp"]);
    CHECK(SZFriendsDataFromHex(@"abc") == nil && [SZFriendsDataFromHex(@"ABcd") isEqual:SZFTestData(@"abcd")]);
}

// Verifier finding (wave 7b-A): a Bonjour name or TXT key that is not UTF-8 made @(cString) nil, and the browse
// handler threw on it, ending the helper. Such a name is skipped; such a key is dropped and the rest still parse.
static void TestNonUTF8BrowseResults(void) {
    // Names: Network.framework hands mDNS's bytes through; the browser reads them only through these.
    const char invalid[] = "\xff\xfe" "friend";
    CHECK([NSString stringWithUTF8String:invalid] == nil, "what @(name) returned before it threw");
    CHECK(SZFriendsStringFromLANBytes(invalid) == nil && SZFriendsStringFromLANBytes(NULL) == nil);
    CHECK(SZFriendsStringFromLANBytes("k\xc3") == nil, "a lone lead byte");
    CHECK([SZFriendsStringFromLANBytes("0a1b2c3d4e5f6071") isEqual:@"0a1b2c3d4e5f6071"]);
    CHECK([SZFriendsStringFromLANBytes("caf\xc3\xa9") isEqual:@"caf\u00e9"], "UTF-8 beyond ASCII still reads");
    nw_endpoint_t good = nw_endpoint_create_bonjour_service("0a1b2c3d4e5f6071", "_szfriends._tcp", "local");
    CHECK([SZFriendsBonjourServiceName(good) isEqual:@"0a1b2c3d4e5f6071"]);
    CHECK(SZFriendsBonjourServiceName(nw_endpoint_create_host("127.0.0.1", "9")) == nil, "not a Bonjour endpoint");
    CHECK(SZFriendsBonjourServiceName(nil) == nil);

    // TXT bytes as a LAN device sends them: v=1, t=<tag>, then a key "k\xc3" (a lone UTF-8 lead byte).
    // (Network.framework reads a record as empty when another key follows such a key, so it comes last here.)
    NSMutableData *raw = [NSMutableData data];
    void (^entry)(const char *) = ^(const char *bytes) {
        uint8_t length = (uint8_t)strlen(bytes);
        [raw appendBytes:&length length:1];
        [raw appendBytes:bytes length:length];
    };
    entry("v=1");
    entry("t=0102030405060708");
    entry("k\xc3=abc");
    nw_txt_record_t txt = nw_txt_record_create_with_bytes(raw.bytes, raw.length);
    CHECK(txt != nil && nw_txt_record_get_key_count(txt) == 3);
    __block BOOL sawBadKey = NO;
    if (txt) {
        nw_txt_record_apply(txt, ^bool(const char *key, nw_txt_record_find_key_t found, const uint8_t *value,
                                       size_t length) {
            (void)found, (void)value, (void)length;
            sawBadKey = sawBadKey || [NSString stringWithUTF8String:key] == nil;
            return true;
        });
    }
    CHECK(sawBadKey, "the record really carries a key that is not UTF-8");
    NSDictionary<NSString *, NSData *> *fields = SZFriendsNetworkTXTRecordFields(txt);
    CHECK(fields.count == 2 && fields[@"v"] && fields[@"t"], "%@", fields);
    NSData *tag = nil;
    NSArray<NSData *> *callbacks = nil;
    BOOL isPublic = YES;
    CHECK(SZFriendsNetworkParseTXT(fields, &tag, &callbacks, &isPublic) && !isPublic &&
              [tag isEqual:SZFTestData(@"0102030405060708")],
          "still a Friends entry");
    CHECK(SZFriendsNetworkTXTRecordFields(nil).count == 0);
}

void SZFriendsRunStreamAndTXTTests(void) {
    TestRunLoopStream();
    TestTXT();
    TestNonUTF8BrowseResults();
}
