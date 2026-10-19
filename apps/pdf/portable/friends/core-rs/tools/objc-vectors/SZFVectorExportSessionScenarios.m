// Session transcripts: the scenarios (SZFVectorExportSession.h). Each is what the helper's nearby service does with a
// channel, played by a script: a friend request over XX with codes, browsing a public entry, the IK callback after Add
// by ID carrying a file across rekeys, Add by ID over NN, and the quiet refusals.

#import "SZFVectorExportSession.h"

#import <sodium.h>

#import "SZFVectorExport.h"

static NSData *U(uint64_t value, SZFriendsFieldTag tag) { return [SZFriendsFrame fieldWithUInt64:value tag:tag]; }
static NSData *D(NSString *label, NSUInteger length) { return SZFDerive(label, length); }

static SZFriendsFrame *Frame(SZFriendsFrameType type, NSDictionary<NSNumber *, NSData *> *fields) {
    return [SZFriendsFrame frameWithType:type fields:fields];
}

static SZFriendsHandshakeOptions *Options(SZFriendsHandshakePattern pattern) {
    SZFriendsHandshakeOptions *options = [[SZFriendsHandshakeOptions alloc] init];
    options.pattern = pattern;
    options.route = SZFriendsRouteMethodLAN;
    return options;
}

static SZFriendsRemoteKeyPolicy Always(BOOL answer) {
    return ^BOOL(NSData *key, SZFriendsHandshakePattern pattern, NSData *token) {
        (void)key, (void)pattern, (void)token;
        return answer;
    };
}

static NSDictionary *PublicProfile(NSString *name) {
    return @{@(SZFriendsFieldName) : SZFUTF8(name), @(SZFriendsFieldPictureSet) : U(1, SZFriendsFieldPictureSet),
             @(SZFriendsFieldPictureIndex) : U(17, SZFriendsFieldPictureIndex)};
}

// A friend request on a public entry (ADR 0001 § Comparison codes, Review amendments 1): PROFILE and REQUEST, the
// durable ACK, both sides' codes, the acceptance and the presence secrets, then a goodbye.
static NSDictionary *SZFXXRequest(void) {
    SZFTranscript *t = [[SZFTranscript alloc] initWithName:@"xx_request"];
    [t setInitiatorIdentity:@"alice" options:Options(SZFriendsHandshakeXX)];
    [t setResponderIdentity:@"bob" profile:PublicProfile(@"Bob") policy:Always(YES)];
    t.initiator.localAttestation = D(@"alice attestation", 120);
    t.responder.localAttestation = D(@"bob attestation", 96);
    [t start];
    NSData *requestID = D(@"xx request id", 16);
    [t send:Frame(SZFriendsFrameTypeProfile, @{@(SZFriendsFieldName) : SZFUTF8(@"Alice")}) from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeRequest, @{@(SZFriendsFieldID) : requestID,
                                               @(SZFriendsFieldSentAt) : U(1791787668000, SZFriendsFieldSentAt),
                                               @(SZFriendsFieldText) : SZFUTF8(@"Hi, it's Alice from the café")})
        from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : requestID}) from:SZFSideResponder];
    [t runCodeOn:SZFSideResponder];
    [t runCodeOn:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeAccept, @{@(SZFriendsFieldID) : requestID}) from:SZFSideResponder];
    [t send:Frame(SZFriendsFrameTypePresenceSecret, @{@(SZFriendsFieldID) : D(@"bob secret id", 16),
                                                      @(SZFriendsFieldSecret) : D(@"bob presence", 32)})
        from:SZFSideResponder];
    [t send:Frame(SZFriendsFrameTypePresenceSecret, @{@(SZFriendsFieldID) : D(@"alice secret id", 16),
                                                      @(SZFriendsFieldSecret) : D(@"alice presence", 32)})
        from:SZFSideInitiator];
    // A second code exchange is refused, and so is a frame the channel owns.
    [t runCodeOn:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypePing, @{}) from:SZFSideInitiator];
    [t closeSide:SZFSideInitiator reason:SZFriendsCloseReasonNormal];
    return [t export];
}

// Browsing a public entry: message 2's profile, then the initiator leaves without revealing itself.
static NSDictionary *SZFXXBrowse(void) {
    SZFTranscript *t = [[SZFTranscript alloc] initWithName:@"xx_browse"];
    SZFriendsHandshakeOptions *options = Options(SZFriendsHandshakeXX);
    options.browseOnly = YES;
    [t setInitiatorIdentity:@"carol" options:options];
    [t setResponderIdentity:@"bob" profile:PublicProfile(@"Bob") policy:Always(YES)];
    [t start];
    return [t export];
}

// The holder's IK callback after Add by ID: the token admits an unknown key, the codes run, and a file crosses the
// link with a preview, PROGRESS through a small window and a REKEY before nearly every frame each way.
static NSDictionary *SZFIKCallbackTransfer(void) {
    SZFTranscript *t = [[SZFTranscript alloc] initWithName:@"ik_callback_transfer"];
    t.rekeyAfterBytes = 2048;
    SZFriendsHandshakeOptions *options = Options(SZFriendsHandshakeIK);
    SZFriendsIdentity *bob = SZFVectorIdentity(@"bob");
    NSData *token = D(@"add by id token", 16);
    options.remoteStaticKey = bob.staticPublicKey;
    options.expectedIdentityKey = bob.publicKey;
    options.requestToken = token;
    [t setInitiatorIdentity:@"alice" options:options];
    [t setResponderIdentity:@"bob" profile:nil policy:^BOOL(NSData *key, SZFriendsHandshakePattern pattern,
                                                            NSData *presented) {
        (void)key;
        return pattern == SZFriendsHandshakeIK && [presented isEqualToData:token];
    }];
    t.initiator.localAttestation = D(@"alice attestation", 512);
    [t start];
    [t runCodeOn:SZFSideInitiator];
    [t runCodeOn:SZFSideResponder];
    [t send:Frame(SZFriendsFrameTypeChain, @{@(SZFriendsFieldChain) : D(@"bob chain", 48)}) from:SZFSideResponder];
    NSMutableData *file = [NSMutableData data];
    for (NSUInteger i = 0; file.length < 10000; i++) {
        [file appendData:D([NSString stringWithFormat:@"file %lu", i], 64)];
    }
    file.length = 10000;
    NSMutableData *digest = [NSMutableData dataWithLength:32];
    crypto_generichash(digest.mutableBytes, 32, file.bytes, file.length, NULL, 0);
    NSData *offerID = D(@"offer id", 16);
    [t send:Frame(SZFriendsFrameTypeOffer, @{@(SZFriendsFieldID) : offerID,
                                             @(SZFriendsFieldName) : SZFUTF8(@"Plan.pdf"),
                                             @(SZFriendsFieldFileType) : SZFUTF8(@"com.adobe.pdf"),
                                             @(SZFriendsFieldSize) : U(file.length, SZFriendsFieldSize),
                                             @(SZFriendsFieldDigest) : digest})
        from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeThumbnail, @{@(SZFriendsFieldID) : offerID, @(SZFriendsFieldWidth) :
                                                     U(4, SZFriendsFieldWidth), @(SZFriendsFieldHeight) :
                                                     U(4, SZFriendsFieldHeight), @(SZFriendsFieldData) :
                                                     D(@"thumbnail", 40)})
        from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeOfferReply, @{@(SZFriendsFieldID) : offerID, @(SZFriendsFieldAccept) :
                                                      U(1, SZFriendsFieldAccept), @(SZFriendsFieldOffset) :
                                                      U(0, SZFriendsFieldOffset)})
        from:SZFSideResponder];
    SZFriendsChunkSender *sender = [[SZFriendsChunkSender alloc] initWithOfferID:offerID size:file.length
                                                                    resumeOffset:0 chunkBytes:4096 window:8192];
    for (NSNumber *progress in @[ @8192, @10000 ]) {
        uint64_t offset = 0;
        NSUInteger length = 0;
        while ([sender getNextChunkOffset:&offset length:&length]) {
            NSData *data = [file subdataWithRange:NSMakeRange(offset, length)];
            [t send:[sender chunkFrameWithData:data] from:SZFSideInitiator];
        }
        if (sender.allSent) {
            [t send:Frame(SZFriendsFrameTypeDone, @{@(SZFriendsFieldID) : offerID, @(SZFriendsFieldDigest) : digest})
                from:SZFSideInitiator];
        }
        SZFriendsFrame *frame = Frame(SZFriendsFrameTypeProgress, @{@(SZFriendsFieldID) : offerID,
                                                                    @(SZFriendsFieldOffset) :
                                                                        U(progress.unsignedLongLongValue,
                                                                          SZFriendsFieldOffset)});
        [t send:frame from:SZFSideResponder];
        [sender handleProgressFrame:frame error:NULL];
    }
    [t send:Frame(SZFriendsFrameTypeAck, @{@(SZFriendsFieldID) : offerID}) from:SZFSideResponder];
    [t closeSide:SZFSideResponder reason:SZFriendsCloseReasonSuperseded];
    return [t export];
}

// Add by ID nearby: NN, REQUEST_BY_ID signed over this session's hash, the uniform RECEIVED, and nothing else.
static NSDictionary *SZFNNRequestByID(void) {
    SZFTranscript *t = [[SZFTranscript alloc] initWithName:@"nn_request_by_id"];
    [t setInitiatorIdentity:@"alice" options:Options(SZFriendsHandshakeNN)];
    [t setResponderIdentity:@"bob" profile:nil policy:^BOOL(NSData *key, SZFriendsHandshakePattern p, NSData *token) {
        (void)key, (void)token;
        return p == SZFriendsHandshakeNN;
    }];
    [t start];
    [t runCodeOn:SZFSideInitiator];
    SZFriendsFrame *request = SZFriendsMakeRequestByIDFrame(SZFVectorIdentity(@"alice"), @"maple-otter",
                                                            D(@"nn token", 16), D(@"nn callback", 32),
                                                            t.initiator.handshakeHash);
    [t send:request from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeMessage, @{@(SZFriendsFieldID) : D(@"nn msg", 16), @(SZFriendsFieldSentAt) :
                                                   U(1, SZFriendsFieldSentAt)})
        from:SZFSideInitiator];
    [t send:Frame(SZFriendsFrameTypeReceived, @{}) from:SZFSideResponder];
    [t closeSide:SZFSideResponder reason:SZFriendsCloseReasonNormal];
    return [t export];
}

// The quiet refusals: a stranger's IK, and XX at a hidden listener. Nothing is written back, and the link closes
// the refusal delay after the deciding bytes.
static NSDictionary *SZFRefusal(NSString *name, SZFriendsHandshakePattern pattern) {
    SZFTranscript *t = [[SZFTranscript alloc] initWithName:name];
    SZFriendsHandshakeOptions *options = Options(pattern);
    options.remoteStaticKey = pattern == SZFriendsHandshakeIK ? SZFVectorIdentity(@"bob").staticPublicKey : nil;
    [t setInitiatorIdentity:@"carol" options:options];
    [t setResponderIdentity:@"bob" profile:nil policy:Always(NO)];
    [t start];
    [t advance:1.0];
    [t advance:0.5];
    return [t export];
}

NSArray<NSDictionary *> *SZFExportSessionScenarios(void) {
    return @[
        SZFXXRequest(), SZFXXBrowse(), SZFIKCallbackTransfer(), SZFNNRequestByID(),
        SZFRefusal(@"ik_stranger_refused", SZFriendsHandshakeIK), SZFRefusal(@"xx_hidden_refused", SZFriendsHandshakeXX)
    ];
}
