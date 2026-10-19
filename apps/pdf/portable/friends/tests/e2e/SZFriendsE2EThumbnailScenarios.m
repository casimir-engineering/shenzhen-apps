// friends-e2e-check: file previews (brief § Transfers, Thumbnails before acceptance; PROTOCOL.md § Thumbnails).
// Between two real helpers, an offer shows the sender's preview before it is accepted, the recipient's own preview
// replaces it once the file arrives, and declining or cancelling deletes it on both Macs. Against a peer under the
// test's control, previews for offers that are not waiting, oversized or malformed ones and a second one are refused
// and change nothing, and the helper's own preview reaches the peer after its OFFER.

#import "SZFriendsE2EScenarios.h"

#import <CoreGraphics/CoreGraphics.h>

#import "SZFriendsE2ERogue.h"
#import "service/thumbnails/SZFriendsThumbnails.h"
#import "service/thumbnails/szfriends_qoi.h"

static NSString *SZFE2EThumbHex(NSData *data) {
    NSMutableString *hex = [NSMutableString string];
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)data.bytes)[i]];
    return hex;
}

static NSDictionary *SZFE2EThumbTransfer(NSDictionary *conversation, NSString *transferID) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"transfer")) {
        if ([item[@"transfer_id"] isEqual:transferID]) return item;
    }
    return nil;
}

// The item's preview when it has one, else nil.
static NSDictionary *SZFE2EThumbOf(NSDictionary *conversation, NSString *transferID) {
    id thumbnail = SZFE2EThumbTransfer(conversation, transferID)[@"thumbnail"];
    return [thumbnail isKindOfClass:[NSDictionary class]] ? thumbnail : nil;
}

// A one-page PDF of one colour, as a document a person would send.
static NSString *SZFE2EThumbPDF(SZFE2EWorld *world, NSString *name, CGFloat red, CGFloat green, CGFloat blue) {
    NSString *path = [world.scenarioDirectory stringByAppendingPathComponent:name];
    CGRect box = CGRectMake(0, 0, 595, 842);
    CGContextRef pdf = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &box, NULL);
    CGPDFContextBeginPage(pdf, NULL);
    CGContextSetRGBFillColor(pdf, red, green, blue, 1);
    CGContextFillRect(pdf, box);
    CGPDFContextEndPage(pdf);
    CGPDFContextClose(pdf);
    CGContextRelease(pdf);
    return path;
}

// Width and height from a PNG's IHDR, which the helper wrote: what the snapshot promised is what the file holds.
static BOOL SZFE2EThumbPNGSize(NSString *path, NSUInteger *width, NSUInteger *height) {
    NSData *png = [NSData dataWithContentsOfFile:path];
    const uint8_t *b = png.bytes;
    if (png.length < 33 || memcmp(b, "\x89PNG\r\n\x1a\n", 8) != 0 || memcmp(b + 12, "IHDR", 4) != 0) return NO;
    *width = (NSUInteger)b[16] << 24 | (NSUInteger)b[17] << 16 | (NSUInteger)b[18] << 8 | b[19];
    *height = (NSUInteger)b[20] << 24 | (NSUInteger)b[21] << 16 | (NSUInteger)b[22] << 8 | b[23];
    return YES;
}

static NSArray<NSString *> *SZFE2EThumbFiles(SZFE2EHelper *helper) {
    NSString *directory = [helper.stateDirectory stringByAppendingPathComponent:@"thumbnails"];
    return [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:NULL] ?: @[];
}

// A preview the snapshot shows as `source`, whose PNG exists in that helper's cache with the size it claims.
static BOOL SZFE2EThumbIsReal(NSDictionary *thumbnail, NSString *source, SZFE2EHelper *helper) {
    NSUInteger width = 0, height = 0;
    NSString *cache = [[helper.stateDirectory stringByAppendingPathComponent:@"thumbnails"]
        stringByResolvingSymlinksInPath];
    NSString *path = thumbnail[@"path"];
    return [thumbnail[@"source"] isEqual:source] && [path.stringByResolvingSymlinksInPath hasPrefix:cache] &&
           SZFE2EThumbPNGSize(path, &width, &height) && width == [thumbnail[@"width"] unsignedIntegerValue] &&
           height == [thumbnail[@"height"] unsignedIntegerValue] && MAX(width, height) <= 192;
}

BOOL SZFE2EScenarioThumbnails(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSArray<NSString *> *paths = @[
        SZFE2EThumbPDF(world, @"Bracket drawing.pdf", 0.85, 0.1, 0.1),
        SZFE2EThumbPDF(world, @"Old quote.pdf", 0.1, 0.6, 0.2), SZFE2EThumbPDF(world, @"Wrong file.pdf", 0.2, 0.2, 0.8),
        [world fileOfSize:4096 named:@"Firmware.bin"]
    ];
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *path in paths) [files addObject:@{@"path" : path}];
    NSDictionary *reply = [pair.a intent:@"send_files" fields:@{@"conversation_id" : pair.bAtA, @"files" : files,
                                                                  @"client_token" : SZFE2EToken()}];
    NSArray<NSString *> *ids = reply[@"result"][@"transfer_ids"];
    CHECK(ids.count == 4, "four offers: %@", reply);
    NSString *accepted = ids[0], *declined = ids[1], *cancelled = ids[2], *unknown = ids[3];
    NSString *atB = [pair.b openConversation:pair.aAtB], *atA = [pair.a openConversation:pair.bAtA];
    // Before anyone accepts: Ben sees Ana's pictures of the three PDFs; the binary has none and says what it is.
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *conversation = [pair.b dataFor:atB];
              for (NSString *transferID in @[ accepted, declined, cancelled ]) {
                  NSDictionary *item = SZFE2EThumbTransfer(conversation, transferID);
                  if (![item[@"state"] isEqual:@"waiting_for_you"] ||
                      !SZFE2EThumbIsReal(SZFE2EThumbOf(conversation, transferID), @"sender", pair.helperB)) {
                      return NO;
                  }
              }
              return YES;
          }),
          "previews before acceptance: %@", [pair.b dataFor:atB][@"items"]);
    NSDictionary *page = SZFE2EThumbOf([pair.b dataFor:atB], accepted);
    CHECK([page[@"height"] integerValue] > [page[@"width"] integerValue], "a portrait page: %@", page);
    SZFE2EPump(1.0);
    NSDictionary *binary = SZFE2EThumbTransfer([pair.b dataFor:atB], unknown);
    CHECK(binary[@"thumbnail"] == [NSNull null] && [binary[@"file"][@"extension"] isEqual:@"bin"],
          "no preview for an unknown format, its type for the icon: %@", binary);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return SZFE2EThumbIsReal(SZFE2EThumbOf([pair.a dataFor:atA], accepted), @"local", pair.helperA);
          }),
          "Ana sees her own preview: %@", SZFE2EThumbTransfer([pair.a dataFor:atA], accepted));
    // Accepted: once the file arrives and its digest checks, Ben's own preview replaces Ana's.
    NSString *sentPath = SZFE2EThumbOf([pair.b dataFor:atB], accepted)[@"path"];
    CHECK([[pair.b intent:@"accept_offer" fields:@{@"transfer_id" : accepted}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *conversation = [pair.b dataFor:atB];
              return [SZFE2EThumbTransfer(conversation, accepted)[@"state"] isEqual:@"received"] &&
                     SZFE2EThumbIsReal(SZFE2EThumbOf(conversation, accepted), @"local", pair.helperB);
          }),
          "replaced after the digest: %@", SZFE2EThumbTransfer([pair.b dataFor:atB], accepted));
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:sentPath], "Ana's picture is gone from Ben's Mac");
    // Declined by Ben, cancelled by Ana: no picture left on either Mac.
    CHECK([[pair.b intent:@"decline_offer" fields:@{@"transfer_id" : declined}][@"ok"] boolValue]);
    CHECK([[pair.a intent:@"cancel_transfer" fields:@{@"transfer_id" : cancelled}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *atBen = [pair.b dataFor:atB], *atAna = [pair.a dataFor:atA];
              for (NSString *transferID in @[ declined, cancelled ]) {
                  if (SZFE2EThumbOf(atBen, transferID) != nil || SZFE2EThumbOf(atAna, transferID) != nil) return NO;
              }
              return [SZFE2EThumbTransfer(atAna, declined)[@"state"] isEqual:@"declined"] &&
                     [SZFE2EThumbTransfer(atBen, cancelled)[@"state"] isEqual:@"cancelled"] &&
                     [SZFE2EThumbTransfer(atAna, accepted)[@"state"] isEqual:@"delivered"];
          }),
          "declined and cancelled lose their previews: %@ / %@", [pair.b dataFor:atB][@"items"],
          [pair.a dataFor:atA][@"items"]);
    CHECK(SZFE2EThumbFiles(pair.helperB).count == 1 && SZFE2EThumbFiles(pair.helperA).count == 1,
          "only the received file's preview is left: %@ / %@", SZFE2EThumbFiles(pair.helperB),
          SZFE2EThumbFiles(pair.helperA));
    return YES;
}

#pragma mark - Refusals

static NSData *SZFE2EThumbQOI(uint32_t width, uint32_t height, uint32_t rgba) {
    NSMutableData *pixels = [NSMutableData dataWithLength:(NSUInteger)width * height * 4];
    uint8_t *p = pixels.mutableBytes;
    for (NSUInteger i = 0; i < (NSUInteger)width * height; i++, p += 4) {
        p[0] = (uint8_t)(rgba >> 24), p[1] = (uint8_t)(rgba >> 16), p[2] = (uint8_t)(rgba >> 8), p[3] = (uint8_t)rgba;
    }
    NSMutableData *qoi = [NSMutableData dataWithLength:(NSUInteger)width * height * 5 + 32];
    qoi.length = szfriends_qoi_encode(pixels.bytes, width, height, 3, qoi.mutableBytes, qoi.length);
    return qoi;
}

static SZFriendsFrame *SZFE2EThumbFrame(NSData *offerID, uint64_t width, uint64_t height, NSData *qoi) {
    return [SZFriendsFrame frameWithType:SZFriendsFrameTypeThumbnail
                                  fields:@{
                                      @(SZFriendsFieldID) : offerID,
                                      @(SZFriendsFieldWidth) : [SZFriendsFrame fieldWithUInt64:width
                                                                                           tag:SZFriendsFieldWidth],
                                      @(SZFriendsFieldHeight) : [SZFriendsFrame fieldWithUInt64:height
                                                                                            tag:SZFriendsFieldHeight],
                                      @(SZFriendsFieldData) : qoi,
                                  }];
}

static NSUInteger SZFE2EAcksFor(SZFE2ERogueSession *session, NSData *wire) {
    NSUInteger count = 0;
    for (SZFriendsFrame *frame in session.frames) {
        if (frame.type == SZFriendsFrameTypeAck && [[frame dataForTag:SZFriendsFieldID] isEqualToData:wire]) count++;
    }
    return count;
}

BOOL SZFE2EScenarioThumbnailRefusals(SZFE2EWorld *world) {
    SZFE2EHelper *helper = nil;
    SZFE2EClient *b = nil;
    NSString *list = nil;
    if (!SZFE2EStartSingle(world, @"b", @"Ben", nil, &helper, &b, &list)) return NO;
    CHECK([[b intent:@"start_visibility" fields:nil][@"ok"] boolValue], "Ben is visible");
    SZFE2ERogue *rogue = SZFE2EStartRogue(world, YES);
    CHECK(rogue != nil);
    SZFE2ERogueSession *session = [rogue dial:rogue.publicEndpoint options:SZFE2EOptions(SZFriendsHandshakeXX, NO)];
    CHECK(SZFE2EWaitEstablished(session), "XX to the public entry: %@", session.closeError);
    CHECK([session send:SZFE2EProfileFrame(@"Rogue")] && [session send:SZFE2ERequestFrame()]);
    __block NSString *rowID = nil;
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              rowID = SZFE2ERowTitled([b dataFor:list], @"Rogue")[@"conversation_id"];
              return rowID != nil;
          }),
          "the request arrives: %@", [b dataFor:list]);
    CHECK([[b intent:@"accept_request" fields:@{@"conversation_id" : rowID}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2ERowWithID([b dataFor:list], rowID)[@"drop_label"] isKindOfClass:[NSString class]];
          }),
          "a friend now: %@", SZFE2ERowWithID([b dataFor:list], rowID));
    NSData *offer = SZFE2ERandomBytes(16), *stranger = SZFE2ERandomBytes(16);
    NSString *offerID = SZFE2EThumbHex(offer);
    NSDictionary *offerFields = @{
        @(SZFriendsFieldID) : offer,
        @(SZFriendsFieldName) : [@"Plan.pdf" dataUsingEncoding:NSUTF8StringEncoding],
        @(SZFriendsFieldSize) : [SZFriendsFrame fieldWithUInt64:1000 tag:SZFriendsFieldSize],
        @(SZFriendsFieldDigest) : SZFE2ERandomBytes(32),
    };
    CHECK([session send:[SZFriendsFrame frameWithType:SZFriendsFrameTypeOffer fields:offerFields]]);
    NSString *atB = [b openConversation:rowID];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [SZFE2EThumbTransfer([b dataFor:atB], offerID)[@"state"] isEqual:@"waiting_for_you"];
          }),
          "the offer waits for Ben: %@", [b dataFor:atB][@"items"]);
    // Each refused preview is still acknowledged (so ACKs keep their order) and leaves nothing behind.
    NSData *good = SZFE2EThumbQOI(64, 48, 0xd03030ff), *bad = [good subdataWithRange:NSMakeRange(0, good.length - 9)];
    NSMutableData *lying = [good mutableCopy];
    ((uint8_t *)lying.mutableBytes)[11] = 40; // the header says 64 x 40 under a frame that says 64 x 48
    struct {
        NSData *wire;
        uint64_t width, height;
        NSData *qoi;
        const char *what;
    } refused[] = {
        {stranger, 64, 48, good, "for no offer of theirs"},
        {offer, 400, 300, SZFE2EThumbQOI(400, 300, 0x3030d0ff), "400 x 300"},
        {offer, 64, 48, lying, "a header that disagrees"},
        {offer, 64, 48, bad, "a truncated stream"},
    };
    NSUInteger expected = 1; // the OFFER's own ACK
    for (size_t i = 0; i < sizeof refused / sizeof refused[0]; i++) {
        NSData *wire = refused[i].wire;
        NSUInteger before = SZFE2EAcksFor(session, wire);
        CHECK([session send:SZFE2EThumbFrame(wire, refused[i].width, refused[i].height, refused[i].qoi)],
              "sent %s", refused[i].what);
        CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EAcksFor(session, wire) > before; }), "acknowledged: %s",
              refused[i].what);
        if (refused[i].wire == offer) expected++;
        CHECK(SZFE2EThumbOf([b dataFor:atB], offerID) == nil && SZFE2EThumbFiles(helper).count == 0,
              "refused, nothing kept: %s", refused[i].what);
    }
    CHECK(!session.closed && SZFE2EAcksFor(session, offer) == expected, "the session carries on");
    CHECK([session send:SZFE2EThumbFrame(offer, 64, 48, good)]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return SZFE2EThumbIsReal(SZFE2EThumbOf([b dataFor:atB], offerID), @"sender", helper);
          }),
          "a good preview is kept: %@", SZFE2EThumbTransfer([b dataFor:atB], offerID));
    NSString *kept = SZFE2EThumbOf([b dataFor:atB], offerID)[@"path"];
    NSData *keptBytes = [NSData dataWithContentsOfFile:kept];
    CHECK([session send:SZFE2EThumbFrame(offer, 64, 48, SZFE2EThumbQOI(64, 48, 0x30d030ff))]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EAcksFor(session, offer) == expected + 2; }), "both acknowledged");
    CHECK([SZFE2EThumbOf([b dataFor:atB], offerID)[@"path"] isEqual:kept] &&
              [[NSData dataWithContentsOfFile:kept] isEqualToData:keptBytes] && SZFE2EThumbFiles(helper).count == 1,
          "a second preview changes nothing");
    // Declined: the preview goes, and one sent afterwards is refused.
    CHECK([[b intent:@"decline_offer" fields:@{@"transfer_id" : offerID}][@"ok"] boolValue]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EThumbFiles(helper).count == 0; }), "gone after the decline");
    CHECK([session send:SZFE2EThumbFrame(offer, 64, 48, good)]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return SZFE2EAcksFor(session, offer) >= expected + 3; }), "acknowledged");
    CHECK(SZFE2EThumbFiles(helper).count == 0 && SZFE2EThumbOf([b dataFor:atB], offerID) == nil,
          "nothing for a declined offer");
    // The other way: Ben's own preview reaches the peer on the wire after its OFFER, within the limits.
    NSString *pdf = SZFE2EThumbPDF(world, @"Site plan.pdf", 0.9, 0.5, 0.1);
    NSDictionary *sent = [b intent:@"send_files" fields:@{@"conversation_id" : rowID, @"files" : @[ @{@"path" : pdf} ],
                                                          @"client_token" : SZFE2EToken()}];
    NSString *outgoing = [sent[@"result"][@"transfer_ids"] firstObject];
    CHECK(outgoing != nil, "Ben offers a file: %@", sent);
    __block NSUInteger offerAt = NSNotFound, thumbnailAt = NSNotFound;
    __block SZFriendsFrame *thumbnail = nil;
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSArray<SZFriendsFrame *> *frames = session.frames;
              for (NSUInteger i = 0; i < frames.count; i++) {
                  if (![SZFE2EThumbHex([frames[i] dataForTag:SZFriendsFieldID]) isEqual:outgoing]) continue;
                  if (frames[i].type == SZFriendsFrameTypeOffer && offerAt == NSNotFound) offerAt = i;
                  if (frames[i].type == SZFriendsFrameTypeThumbnail && thumbnailAt == NSNotFound) {
                      thumbnailAt = i;
                      thumbnail = frames[i];
                  }
              }
              return thumbnail != nil;
          }),
          "Ben's preview arrives: %@", session.frames);
    uint64_t width = 0, height = 0;
    CHECK(offerAt < thumbnailAt && [thumbnail getUInt64:&width forTag:SZFriendsFieldWidth] &&
              [thumbnail getUInt64:&height forTag:SZFriendsFieldHeight] && height > width && height <= 192 &&
              SZFriendsPNGFromReceivedThumbnail([thumbnail dataForTag:SZFriendsFieldData], width, height, NULL),
          "after the OFFER, a portrait page that passes the recipient's checks (%llu x %llu)", width, height);
    [rogue stop];
    return YES;
}
