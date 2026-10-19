// The two-port classifier against scripted STUN servers on loopback (one that answers like a NAT mapping each
// destination anew), against the host's own responder (server/friends/src/stun.js) when Node.js is here, and the
// class cache.

#import "SZFriendsNATTestSupport.h"

#import "service/online/nat/SZFriendsNATClassifier.h"
#import "service/online/nat/SZFriendsNATStun.h"

typedef struct {
    SZFriendsNATClassification *classification;
    NSError *error;
} ClassifyResult;

static ClassifyResult Classify(SZFriendsNATEndpoint *primary, SZFriendsNATEndpoint *secondary, BOOL loopbackOnly,
                               NSTimeInterval budget) {
    SZFriendsNATClassifier *classifier = [[SZFriendsNATClassifier alloc] initWithPrimary:primary
                                                                              secondary:secondary
                                                                           loopbackOnly:loopbackOnly];
    classifier.budget = budget;
    classifier.retransmits = @[ @0.1, @0.3 ];
    __block ClassifyResult result = {nil, nil};
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [classifier classifyOnQueue:SZFTestQueue("szf.test.classify")
                     completion:^(SZFriendsNATClassification *classification, NSError *error) {
                         result.classification = classification;
                         result.error = error;
                         dispatch_semaphore_signal(done);
                     }];
    CHECK(SZFTestWait(done, budget + 2), "the classifier finishes within its budget");
    return result;
}

static void TestScripted(void) {
    SZFTestUDPServer *primary = SZFTestStunServer(@"127.0.0.1", 0);
    SZFTestUDPServer *same = SZFTestStunServer(@"127.0.0.1", 0);
    SZFTestUDPServer *sequential = SZFTestStunServer(@"127.0.0.1", 2);
    SZFTestUDPServer *random = SZFTestStunServer(@"127.0.0.1", 3001);
    SZFTestUDPHandler nothing = ^NSArray<NSData *> *(NSData *p, SZFriendsNATEndpoint *f) {
        (void)p, (void)f;
        return @[];
    };
    SZFTestUDPServer *silent = [[SZFTestUDPServer alloc] initWithHost:@"127.0.0.1" port:0 handler:nothing];
    CHECK(primary && same && sequential && random && silent);

    ClassifyResult result = Classify(primary.endpoint, same.endpoint, YES, 2);
    CHECK(result.classification.natClass == SZFriendsNATClassEndpointIndependent && result.error == nil);
    CHECK(result.classification.mappedPrimary.port == result.classification.mappedSecondary.port &&
          result.classification.mappedPrimary.scope == SZFriendsNATAddressScopeLoopback);

    result = Classify(primary.endpoint, sequential.endpoint, YES, 2);
    CHECK(result.classification.natClass == SZFriendsNATClassPerDestination && result.classification.step == 2 &&
          result.classification.predictable, "a sequential NAT: step 2");

    result = Classify(primary.endpoint, random.endpoint, YES, 2);
    CHECK(result.classification.natClass == SZFriendsNATClassPerDestination && !result.classification.predictable,
          "a random NAT: nothing to predict");

    NSUInteger before = silent.received;
    result = Classify(primary.endpoint, silent.endpoint, YES, 0.6);
    CHECK(result.classification.natClass == SZFriendsNATClassUnknown && result.classification.mappedPrimary != nil &&
          result.classification.mappedSecondary == nil && result.error == nil, "3479 silent: unknown");
    CHECK(silent.received - before == 3, "sent at 0, 0.1 and 0.3 s, then gave up (got %lu)",
          (unsigned long)(silent.received - before));

    result = Classify(silent.endpoint, silent.endpoint, YES, 0.5);
    CHECK(result.classification == nil && result.error.code == SZFriendsNATErrorTimedOut, "no answer at all");

    SZFriendsNATEndpoint *lan = [SZFriendsNATEndpoint endpointWithHost:@"192.168.1.1" port:3478];
    result = Classify(lan, primary.endpoint, YES, 0.5);
    CHECK(result.error.code == SZFriendsNATErrorAddressRefused, "loopback-only refuses the LAN");
    result = Classify(primary.endpoint, primary.endpoint, NO, 0.5);
    CHECK(result.error.code == SZFriendsNATErrorAddressRefused, "production refuses anything but a global server");
    [primary close], [same close], [sequential close], [random close], [silent close];
}

// A server that has another socket answer for it: the answer comes from the wrong address and must not count.
static void TestAnswerFromElsewhere(void) {
    SZFTestUDPServer *liar = SZFTestStunServer(@"127.0.0.1", 0);
    SZFTestUDPServer *relay = [[SZFTestUDPServer alloc] initWithHost:@"127.0.0.1" port:0
                                                             handler:^NSArray<NSData *> *(NSData *packet,
                                                                                          SZFriendsNATEndpoint *from) {
        SZFriendsStunMessage message;
        if (!SZFriendsStunParse(packet.bytes, packet.length, &message)) return @[];
        struct sockaddr_storage storage;
        [from getSockaddr:&storage];
        uint8_t answer[128];
        size_t length = SZFriendsStunWriteBindingSuccess(answer, sizeof answer, message.transaction,
                                                         (struct sockaddr *)&storage, NULL, 0);
        [liar sendData:[NSData dataWithBytes:answer length:length] to:from];
        return @[];
    }];
    SZFTestUDPServer *honest = SZFTestStunServer(@"127.0.0.1", 0);
    ClassifyResult result = Classify(honest.endpoint, relay.endpoint, YES, 0.6);
    CHECK(result.classification.natClass == SZFriendsNATClassUnknown && result.classification.mappedSecondary == nil,
          "an answer from another address is ignored");
    [liar close], [relay close], [honest close];
}

// The host's responder, as deployed on 3479, started by Node on two loopback ports.
static void TestHostResponder(NSString *serverDirectory) {
    NSString *stun = [serverDirectory stringByAppendingPathComponent:@"src/stun.js"];
    if (serverDirectory == nil || ![[NSFileManager defaultManager] fileExistsAtPath:stun]) {
        fprintf(stderr, "    skipped: the host's responder (no server/friends directory given)\n");
        return;
    }
    NSString *script = [NSString stringWithFormat:
        @"const { StunResponder } = await import(%@);"
         "const r = new StunResponder();"
         "const ports = await r.start([{ address: '127.0.0.1', port: 0, type: 'udp4' },"
         "{ address: '127.0.0.1', port: 0, type: 'udp4' }]);"
         "console.log(JSON.stringify(ports));"
         "process.stdin.on('end', () => process.exit(0)); process.stdin.resume();"
         "setTimeout(() => process.exit(0), 15000).unref();",
        [NSString stringWithFormat:@"'%@'", [NSURL fileURLWithPath:stun.stringByStandardizingPath].absoluteString]];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    task.arguments = @[ @"node", @"--input-type=module", @"-e", script ];
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![task launchAndReturnError:NULL]) {
        fprintf(stderr, "    skipped: the host's responder (Node.js not found)\n");
        return;
    }
    __block NSData *line = nil;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        line = [output.fileHandleForReading availableData];
        dispatch_semaphore_signal(ready);
    });
    NSArray<NSNumber *> *ports = nil;
    if (SZFTestWait(ready, 8) && line.length > 0) {
        ports = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    }
    if (![ports isKindOfClass:[NSArray class]] || ports.count != 2) {
        fprintf(stderr, "    skipped: the host's responder (Node.js 22.16 or later did not start it)\n");
    } else {
        ClassifyResult result =
            Classify([SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:ports[0].unsignedShortValue],
                     [SZFriendsNATEndpoint endpointWithHost:@"127.0.0.1" port:ports[1].unsignedShortValue], YES, 2);
        CHECK(result.classification.natClass == SZFriendsNATClassEndpointIndependent,
              "the host's own responder answers our requests on both ports");
    }
    [input.fileHandleForWriting closeFile];
    dispatch_semaphore_t exited = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *ended) {
        (void)ended;
        dispatch_semaphore_signal(exited);
    };
    if (task.running && !SZFTestWait(exited, 3)) [task terminate];
}

static void TestCache(void) {
    __block NSTimeInterval now = 1000;
    SZFriendsNATClassCache *cache = [[SZFriendsNATClassCache alloc] initWithMaximumAge:60
                                                                                 clock:^NSTimeInterval {
                                                                                     return now;
                                                                                 }];
    SZFriendsNATEndpoint *mapped = [SZFriendsNATEndpoint endpointWithHost:@"8.8.8.8" port:5];
    SZFriendsNATClassification *eim = [SZFriendsNATClassification classificationWithPrimary:mapped secondary:mapped];
    [cache setClassification:eim forNetwork:@"en0|192.168.1.1"];
    CHECK([cache classificationForNetwork:@"en0|192.168.1.1"] == eim && ![cache classificationForNetwork:@"en1|x"]);
    now += 61;
    CHECK([cache classificationForNetwork:@"en0|192.168.1.1"] == nil, "expired");
    [cache setClassification:eim forNetwork:@"en0|192.168.1.1"];
    [cache networkDidChange];
    CHECK([cache classificationForNetwork:@"en0|192.168.1.1"] == nil, "a network change measures again");
}

void SZFTestClassifier(NSString *serverDirectory) {
    TestScripted();
    TestAnswerFromElsewhere();
    TestHostResponder(serverDirectory);
    TestCache();
}
