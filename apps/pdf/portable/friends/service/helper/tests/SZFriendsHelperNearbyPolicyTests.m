// friends-helper-check: the nearby orchestration's security decisions, each tied to the review finding it closes.

#import "SZFriendsHelperNearbyTests.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <sodium.h>

#import "service/helper/SZFriendsHelperTesting.h"

static SZFriendsNearbyService *SZFNNearby(SZFriendsHelperServices *services, NSArray *adapters) {
    SZFriendsNearbyService *nearby = [[SZFriendsNearbyService alloc] initWithServices:services adapters:adapters
                                                                                queue:dispatch_get_main_queue()];
    services.nearby = nearby;
    return nearby;
}

// Review (callback tags): every device that heard REQUEST_BY_ID could compute our callback tags for the request's
// 7 days. Each day now has its own secret, keyed from a master that never leaves this Mac, and its tags go on the
// air only within 6 hours of a broadcast that carried that day's secret.
void SZFNTestCallbackSecrets(NSString *scratch) {
    NSDate *created = [NSDate dateWithTimeIntervalSince1970:1791787870];
    EXPECT(SZFriendsCallbackDay(created, created) == 0 &&
           SZFriendsCallbackDay(created, [created dateByAddingTimeInterval:86399]) == 0);
    EXPECT(SZFriendsCallbackDay(created, [created dateByAddingTimeInterval:86400]) == 1);
    EXPECT(SZFriendsCallbackDay(created, [created dateByAddingTimeInterval:-5]) == 0, "a clock set back is day 0");
    NSMutableData *master = [NSMutableData dataWithLength:32];
    randombytes_buf(master.mutableBytes, 32);
    NSData *day0 = SZFriendsCallbackSecretForDay(master, 0), *day1 = SZFriendsCallbackSecretForDay(master, 1);
    EXPECT(day0.length == 32 && day1.length == 32 && ![day0 isEqualToData:day1] && ![day0 isEqualToData:master]);
    EXPECT([SZFriendsCallbackSecretForDay(master, 1) isEqualToData:day1], "the same day gives the same secret");
    uint8_t expected[32];
    uint8_t message[] = "SZFriends callback day v1\0\0\0\0\0\0\0\1";
    crypto_generichash(expected, 32, message, sizeof message - 1, master.bytes, 32);
    EXPECT([day1 isEqualToData:[NSData dataWithBytes:expected length:32]], "keyed BLAKE2b, domain and u64be day");
    EXPECT(SZFriendsCallbackSecretForDay([NSData data], 0).length == 0, "a malformed master gives nothing");

    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"callbacks");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearby(services, @[]);
    SZFriendsPersonRecord *row = [[SZFriendsPersonRecord alloc] init];
    row.conversationID = SZFriendsNewIdentifier();
    row.friendsID = @"someone-else";
    row.picture = [SZFriendsPicture placeholder];
    row.relation = SZFriendsRelationOutgoingRequest;
    row.lastInteractionAt = [NSDate date];
    EXPECT([services.store savePerson:row error:NULL]);
    NSDate *now = [NSDate date];
    SZFriendsIDRequestRecord *request = [[SZFriendsIDRequestRecord alloc] init];
    request.conversationID = row.conversationID;
    request.targetFriendsID = row.friendsID;
    request.requestToken = [SZFriendsHelperServices randomBytes:16];
    request.callbackSecret = master;
    request.createdAt = now;
    request.expiresAt = [now dateByAddingTimeInterval:7 * 86400];
    NSError *error = nil;
    EXPECT([services.store saveIDRequest:request error:&error], "%@", error);
    EXPECT(SZFriendsCallbackTagsToAdvertise([nearby advertisedCallbacksAtDate:now], now).count == 0,
           "nothing on the air before a device heard the request");
    nearby.callbackBroadcasts[SZFriendsLinkHex(request.requestToken)] = now;
    NSArray<NSData *> *tags = SZFriendsCallbackTagsToAdvertise([nearby advertisedCallbacksAtDate:now], now);
    NSData *expectedTag =
        SZFriendsPresenceTag(SZFriendsCallbackSecretForDay(master, 0), SZFriendsPresenceWindowIndex(now));
    EXPECT(tags.count == 1 && [tags.firstObject isEqualToData:expectedTag], "today's tag after a broadcast: %@", tags);
    EXPECT(![tags.firstObject isEqualToData:SZFriendsPresenceTag(master, SZFriendsPresenceWindowIndex(now))],
           "never the master's tag, which the old helper advertised for 7 days");
    NSDate *later = [now dateByAddingTimeInterval:7 * 3600];
    EXPECT(SZFriendsCallbackTagsToAdvertise([nearby advertisedCallbacksAtDate:later], later).count == 0,
           "off the air 6 hours after the broadcast");
    NSDate *tomorrow = [now dateByAddingTimeInterval:86400 + 60];
    EXPECT(SZFriendsCallbackTagsToAdvertise([nearby advertisedCallbacksAtDate:tomorrow], tomorrow).count == 0,
           "yesterday's broadcast puts nothing of today's on the air");
    [services close];
}

// Review (comparison codes; work before authentication): XX on the public entry at most 20 a minute per listener and
// 3 per remote address, NN 60 a minute, applied by the adapters before any Diffie-Hellman. The helper sets them.
void SZFNTestAdmissionLimits(NSString *scratch) {
    SZFriendsAdmissionLimits *limits = SZFriendsNearbyAdmissionLimits();
    EXPECT(limits.xxPerMinutePerListener == 20 && limits.xxPerMinutePerAddress == 3, "review: XX admissions");
    EXPECT(limits.nnPerMinutePerListener == 60, "ADR 0004 step 2");
    EXPECT(limits.ikPerMinutePerListener == 0 && limits.ikPerMinutePerAddress == 0, "friends are never rate-limited");
    EXPECT(limits.pendingPerListener == [SZFriendsAdmissionLimits defaultLimits].pendingPerListener);
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"admission");
    if (services == nil) return;
    SZFNRecordingAdapter *adapter = [[SZFNRecordingAdapter alloc] init];
    SZFriendsNearbyService *nearby = SZFNNearby(services, @[ adapter ]);
    // Review (presence tag relay): a failed IK at an endpoint backs that endpoint off for that person, so a device
    // re-advertising a captured tag learns little from who dials it. The racer keeps the backoff; the helper reports.
    SZFriendsRouteRacer *racer = nearby.coordinator.racer;
    EXPECT(racer.nextBackoffEnd == nil);
    [nearby noteDialToEndpoint:@"relayed" method:SZFriendsDiscoveryMethodNetwork conversation:@"c1" succeeded:NO];
    EXPECT(racer.nextBackoffEnd != nil, "a failed handshake starts a backoff for that endpoint");
    [nearby noteDialToEndpoint:@"relayed" method:SZFriendsDiscoveryMethodNetwork conversation:@"c1" succeeded:YES];
    EXPECT(racer.nextBackoffEnd == nil, "a session that went live clears it");
    EXPECT(nearby != nil && adapter.admissionLimits.xxPerMinutePerAddress == 3 &&
           adapter.admissionLimits.nnPerMinutePerListener == 60, "every adapter gets them: %@",
           adapter.admissionLimits);
    [services close];
}

// Review (presence secret rotation): a PresenceSecret entry carries no secret; the session sends our current one.
// It now goes only to someone who is a friend at the moment of sending, and is refused otherwise.
void SZFNTestPresenceSecretOnlyToFriends(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"secret");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearby(services, @[]);
    SZFriendsPersonRecord *removed = SZFNSavePerson(services.store, SZFriendsRelationRemoved);
    SZFriendsOutboxEntry *entry = [[SZFriendsOutboxEntry alloc] init];
    entry.entryID = SZFriendsNewIdentifier();
    entry.conversationID = removed.conversationID;
    entry.kind = SZFriendsOutboxKindPresenceSecret;
    entry.createdAt = [NSDate date];
    EXPECT([services.outbox enqueue:entry error:NULL]);
    NSString *wireID = nil;
    EXPECT([nearby frameForEntry:entry person:removed wireID:&wireID] == nil, "no secret for a removed person");
    EXPECT([services.outbox entryWithID:entry.entryID].state == SZFriendsOutboxStateFailed, "and the entry is refused");
    for (NSNumber *relation in @[ @(SZFriendsRelationIncomingRequest), @(SZFriendsRelationOutgoingRequest),
                                  @(SZFriendsRelationBlocked) ]) {
        removed.relation = (SZFriendsRelation)relation.integerValue;
        EXPECT([nearby frameForEntry:entry person:removed wireID:&wireID] == nil, "relation %@", relation);
    }
    SZFriendsPersonRecord *friend = SZFNSavePerson(services.store, SZFriendsRelationFriend);
    entry.conversationID = friend.conversationID;
    SZFriendsFrame *frame = [nearby frameForEntry:entry person:friend wireID:&wireID];
    EXPECT(frame.type == SZFriendsFrameTypePresenceSecret &&
           [[frame dataForTag:SZFriendsFieldSecret] isEqualToData:services.store.ownPresenceSecret],
           "a friend gets our current secret");
    [services close];
}

static NSData *SZFNJPEG(void) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, 256, 256, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGContextSetRGBFillColor(context, 0.9, 0.5, 0.2, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 256, 256));
    CGContextSetRGBFillColor(context, 0.2, 0.3, 0.8, 1);
    CGContextFillEllipseInRect(context, CGRectMake(48, 48, 160, 160));
    CGImageRef image = CGBitmapContextCreateImage(context);
    NSMutableData *jpeg = [NSMutableData data];
    CGImageDestinationRef destination =
        CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
    NSDictionary *options = @{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @0.8};
    CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)options);
    CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    CGContextRelease(context);
    CGColorSpaceRelease(space);
    return jpeg;
}

// Review (stranger pictures): a public entry's message 2 carries up to 48 KiB of photo from anyone nearby, which the
// helper decoded with ImageIO as soon as Nearby was open. Strangers now show their animal or the placeholder.
void SZFNTestStrangerPictures(NSString *scratch) {
    SZFriendsHelperServices *services = SZFNOpenServices(scratch, @"pictures");
    if (services == nil) return;
    SZFriendsNearbyService *nearby = SZFNNearby(services, @[]);
    NSData *jpeg = SZFNJPEG();
    EXPECT(jpeg.length > 0 && [SZFriendsPicturePipeline normalizedReceivedImage:jpeg error:NULL] != nil,
           "a photo the avatars pipeline would have accepted and stored (%lu bytes)", (unsigned long)jpeg.length);
    SZFriendsPicture *photo = [nearby publicPictureForKey:@"stranger-photo" fields:@{@(SZFriendsFieldData) : jpeg}];
    EXPECT(photo.kind == SZFriendsPictureKindPlaceholder, "never decoded: %ld", (long)photo.kind);
    NSArray *pictures = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:services.paths.picturesDirectory
                                                                            error:NULL];
    EXPECT(pictures.count == 0, "and nothing written to pictures/: %@", pictures);
    NSDictionary *animal = @{
        @(SZFriendsFieldPictureSet) : [SZFriendsFrame fieldWithUInt64:1 tag:SZFriendsFieldPictureSet],
        @(SZFriendsFieldPictureIndex) : [SZFriendsFrame fieldWithUInt64:4 tag:SZFriendsFieldPictureIndex],
        @(SZFriendsFieldData) : jpeg,
    };
    SZFriendsPicture *drawn = [nearby publicPictureForKey:@"stranger-animal" fields:animal];
    EXPECT(drawn.kind == SZFriendsPictureKindAnimal && drawn.animalSet == 1 && drawn.animalIndex == 4,
           "their animal is drawn from our own copy");
    [services close];
}
