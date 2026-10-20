// The facts behind the golden fixtures (see SZFriendsPresentationWorld.h). Times are Hong Kong wall-clock times,
// matching the fixtures' labels and their RFC 3339 instants (14:32 here is 06:32:05Z in assistant_read.json).

#import "SZFriendsPresentationWorld.h"

#import "service/identity/SZFriendsIdentity.h"
#import "service/presentation/SZFriendsMentions.h"
#import "service/presentation/SZFriendsPresentationPrivate.h"
#import "service/store/SZFriendsOutbox.h"
#import "service/store/SZFriendsTransfers.h"

static NSTimeZone *HongKong(void) {
    return [NSTimeZone timeZoneWithName:@"Asia/Hong_Kong"];
}

NSDate *SZPHongKong(NSString *wallClock) {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = HongKong();
    formatter.dateFormat = wallClock.length > 16 ? @"yyyy-MM-dd HH:mm:ss" : @"yyyy-MM-dd HH:mm";
    NSDate *date = [formatter dateFromString:wallClock];
    if (!date) SZPFail(@"bad wall clock %@", wallClock);
    return date ?: [NSDate date];
}

NSDate *SZPNow(void) {
    return SZPHongKong(@"2026-10-12 14:47:48");
}

SZFriendsAudience *SZPAudience(void) {
    SZFriendsAudience *audience = [[SZFriendsAudience alloc] init];
    audience.appName = @"ShenzhenPDF";
    audience.revealIn = @"Finder";
    audience.locale = @"en-GB";
    audience.capabilities = [NSSet setWithArray:@[ @"attach.items", @"drop.files", @"drop.tabs", @"search.export" ]];
    audience.openFormats = [NSSet setWithArray:@[ @"pdf", @"epub", @"xps", @"cbz", @"md", @"markdown" ]];
    audience.timeZone = HongKong();
    // The fixtures show a helper that saves received files to Downloads or a chosen folder.
    audience.helperCapabilities = [NSSet setWithObject:@"received.folder"];
    return audience;
}

SZFriendsSnapshotBuilder *SZPBuilder(SZFriendsAudience *audience) {
    SZFriendsStrings *strings = [[SZFriendsStrings alloc] initWithAudience:audience];
    SZFriendsSnapshotBuilder *builder = [[SZFriendsSnapshotBuilder alloc] initWithStrings:strings audience:audience];
    builder.animalSet = [SZFriendsAnimalSet bundledSet];
    return builder;
}

static NSData *Base64URLDecode(NSString *text) {
    NSMutableString *standard = [[text stringByReplacingOccurrencesOfString:@"-" withString:@"+"] mutableCopy];
    [standard replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, standard.length)];
    while (standard.length % 4) [standard appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:standard options:0];
}

NSData *SZPKey(NSString *base64url) {
    return Base64URLDecode(base64url);
}

SZFriendsProfileFacts *SZPProfileRaph(void) {
    SZFriendsProfileFacts *profile = [[SZFriendsProfileFacts alloc] init];
    profile.name = @"Raph";
    profile.friendsID = @"cottage-violet";
    profile.friendsIDState = SZFriendsIDStateUnreserved;
    profile.picture = [SZFriendsPicture animalWithSet:1 index:0];
    profile.identityPublicKey = Base64URLDecode(@"C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E");
    profile.receivedDirectory = @"/Users/raph/Downloads";
    return profile;
}

SZFriendsProfileFacts *SZPProfileIDChanged(void) {
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    profile.name = nil;
    profile.friendsID = @"walnut-garden";
    profile.previousFriendsID = @"walnut-valley";
    profile.friendsIDState = SZFriendsIDStateChanged;
    profile.picture = [SZFriendsPicture animalWithSet:1 index:10];
    return profile;
}

static SZFriendsPersonFacts *Person(NSString *conversationID, NSString *name, NSString *friendsID, NSInteger animal,
                                    SZFriendsPersonRelation relation, SZFriendsRouteKind kind,
                                    SZFriendsRouteMethod method, NSString *lastInteraction, NSString *previewItemID) {
    SZFriendsPersonFacts *person = [[SZFriendsPersonFacts alloc] init];
    person.conversationID = conversationID;
    person.name = name;
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture animalWithSet:1 index:animal];
    person.relation = relation;
    person.routeKind = kind;
    person.routeMethod = method;
    person.lastInteractionAt = SZPHongKong(lastInteraction);
    person.lastPreviewItemID = previewItemID;
    return person;
}

NSDictionary<NSString *, SZFriendsPersonFacts *> *SZPPeople(void) {
    SZFriendsPersonFacts *lena = Person(@"c_lena", @"Lena Weber", @"amber-falcon", 3,
                                        SZFriendsPersonRelationIncomingRequest, SZFriendsRouteKindLocal,
                                        SZFriendsRouteMethodLAN, @"2026-10-12 14:40", nil);
    lena.identityKey = SZPKey(SZPKeyLena);
    lena.requestAt = SZPHongKong(@"2026-10-12 14:40");
    lena.requestFoundNearby = YES;
    lena.comparisonCode = @"418270";

    SZFriendsPersonFacts *mei = Person(@"c_mei", @"Mei Lin", @"jasmine-street", 7, SZFriendsPersonRelationFriend,
                                       SZFriendsRouteKindLocal, SZFriendsRouteMethodLAN, @"2026-10-12 14:32:05",
                                       @"m_a4109f52");
    mei.identityKey = SZPKey(SZPKeyMei);
    mei.unreadCount = 1;
    mei.verified = YES;
    mei.verifiedAt = SZPHongKong(@"2026-10-03 10:12");
    mei.autoAccept = YES;
    mei.receivedFileCount = 14;
    mei.receivedRevealPath = @"/Users/raph/Downloads";

    SZFriendsPersonFacts *kenji = Person(@"c_kenji", @"Kenji Sato", @"cedar-lantern", 1,
                                         SZFriendsPersonRelationFriend, SZFriendsRouteKindLocal,
                                         SZFriendsRouteMethodBluetooth, @"2026-10-12 13:10", @"t_kenji_site");
    kenji.identityKey = SZPKey(SZPKeyKenji);
    kenji.offersWaiting = 1;

    SZFriendsPersonFacts *daniel = Person(@"c_daniel", @"Daniel Ortiz", @"quiet-harvest", 5,
                                          SZFriendsPersonRelationFriend, SZFriendsRouteKindLocal,
                                          SZFriendsRouteMethodPeerToPeerWiFi, @"2026-10-12 11:05", @"t_daniel_guide");
    daniel.identityKey = SZPKey(SZPKeyDaniel);
    daniel.autoAccept = YES;

    SZFriendsPersonFacts *priya = Person(@"c_priya", @"Priya Raman", @"silver-ocean", 9,
                                         SZFriendsPersonRelationFriend, SZFriendsRouteKindOffline,
                                         SZFriendsRouteMethodNone, @"2026-10-11 18:02:10", @"t_6a2f90b8");
    priya.identityKey = SZPKey(SZPKeyPriya);

    // Added by ID; the Friends host confirmed the answer came from the ID's holder, so the row marks the ID.
    SZFriendsPersonFacts *orchid = Person(@"c_tulip", nil, @"tulip-canyon", 11, SZFriendsPersonRelationFriend,
                                          SZFriendsRouteKindOffline, SZFriendsRouteMethodNone, @"2026-10-03 16:00",
                                          @"e_tulip_friends");
    orchid.friendsIDConfirmed = YES;
    orchid.identityKey = SZPKey(SZPKeyTulip);

    // Blocked two weeks ago: the row stays so the person can unblock, drawn muted. No session, so no route. The duck
    // is Tomás's in the Nearby fixtures too: animals are drawn at random, and the fixtures keep to README's indexes.
    SZFriendsPersonFacts *jonas = Person(@"c_jonas", @"Jonas Berg", @"copper-pebble", 4,
                                         SZFriendsPersonRelationBlocked, SZFriendsRouteKindNone,
                                         SZFriendsRouteMethodNone, @"2026-09-28 11:40", nil);
    jonas.identityKey = SZPKey(SZPKeyJonas);
    return @{@"c_lena" : lena, @"c_mei" : mei, @"c_kenji" : kenji, @"c_daniel" : daniel, @"c_priya" : priya,
             @"c_tulip" : orchid, @"c_jonas" : jonas};
}

SZFriendsItemFacts *SZPMessage(NSString *itemID, BOOL outgoing, NSString *wallClock, NSString *text, NSInteger outbox) {
    SZFriendsItemFacts *item = [[SZFriendsItemFacts alloc] init];
    item.itemID = itemID;
    item.kind = SZFriendsItemFactsKindMessage;
    item.outgoing = outgoing;
    item.sentAt = SZPHongKong(wallClock);
    item.text = text;
    item.outboxState = outbox;
    return item;
}

SZFriendsItemFacts *SZPTransfer(NSString *itemID, BOOL outgoing, NSString *wallClock, NSString *name, uint64_t size,
                                NSInteger state) {
    SZFriendsItemFacts *item = [[SZFriendsItemFacts alloc] init];
    item.itemID = itemID;
    item.transferID = itemID;
    item.kind = SZFriendsItemFactsKindTransfer;
    item.outgoing = outgoing;
    item.sentAt = SZPHongKong(wallClock);
    item.fileName = name;
    item.fileExtension = name.pathExtension;
    // What the helper derives from the name's extension (every fixture file is a PDF).
    item.fileTypeIdentifier = [name.pathExtension.lowercaseString isEqualToString:@"pdf"] ? @"com.adobe.pdf" : nil;
    item.fileSize = size;
    item.transferState = state;
    return item;
}

// A preview in the helper's cache, named as the helper names them (random, never by the sender).
static SZFriendsItemFacts *SZPWithThumbnail(SZFriendsItemFacts *item, NSString *name, NSUInteger width,
                                            NSUInteger height, BOOL fromSender) {
    item.thumbnailPath = [@"/Users/raph/Library/Application Support/Shenzhen Friends/thumbnails/"
        stringByAppendingString:name];
    item.thumbnailWidth = width;
    item.thumbnailHeight = height;
    item.thumbnailFromSender = fromSender;
    return item;
}

SZFriendsItemFacts *SZPEvent(NSString *itemID, NSString *wallClock, NSString *kind) {
    SZFriendsItemFacts *item = [[SZFriendsItemFacts alloc] init];
    item.itemID = itemID;
    item.kind = SZFriendsItemFactsKindEvent;
    item.sentAt = SZPHongKong(wallClock);
    item.eventKind = kind;
    return item;
}

static SZFriendsItemFacts *DanielGuide(void) {
    SZFriendsItemFacts *guide = SZPTransfer(@"t_daniel_guide", NO, @"2026-10-12 11:05", @"Enclosure assembly guide.pdf",
                                            3120000, SZFriendsTransferStateReceived);
    guide.acceptedAutomatically = YES;
    guide.localPath = @"/Users/raph/Library/Application Support/Shenzhen Friends/received/Enclosure assembly guide.pdf";
    return guide;
}

// Daniel names people in every way a mention resolves for Raph (PROTOCOL.md § Mentions): Mei, a friend, under
// Daniel's own name for her; Leo, whom Raph does not know; Raph himself; Lena, who asked Raph to be friends; Jonas,
// whom Raph blocked; and "Kenji" under a key that is not Kenji's, which shows as plain text. Raph's reply names Priya.
// The guide Daniel sent afterwards (the list's preview) is left out: this conversation is about messages, and the
// transfer items' own fixtures belong with the other conversations.
static NSArray<SZFriendsItemFacts *> *DanielItems(void) {
    NSString *mei = SZFriendsMentionLink(@"Mei", @"jasmine-street", SZPKey(SZPKeyMei));
    NSString *leo = SZFriendsMentionLink(@"Leo Park", @"bonfire-otter", SZPKey(SZPKeyLeo));
    NSString *raph = SZFriendsMentionLink(@"Raph", @"cottage-violet", SZPKey(SZPKeyRaph));
    NSString *lena = SZFriendsMentionLink(@"Lena", @"amber-falcon", SZPKey(SZPKeyLena));
    NSString *jonas = SZFriendsMentionLink(@"Jonas", @"copper-pebble", SZPKey(SZPKeyJonas));
    NSString *forged = SZFriendsMentionLink(@"Kenji", @"cedar-lantern", SZPKey(SZPKeyForged));
    NSString *priya = SZFriendsMentionLink(@"Priya Raman", @"silver-ocean", SZPKey(SZPKeyPriya));
    NSString *format = @"%@ has the bracket drawing. Ask her for rev B.";
    return @[
        SZPMessage(@"m_d0a1", NO, @"2026-10-12 10:40", [NSString stringWithFormat:format, mei], 0),
        SZPMessage(@"m_d0a2", NO, @"2026-10-12 10:41",
                   [NSString stringWithFormat:@"%@ can review the enclosure too. %@ met him at the fair.", leo, raph],
                   0),
        SZPMessage(@"m_d0a3", NO, @"2026-10-12 10:42",
                   [NSString stringWithFormat:@"%@ and %@ asked about it as well.", lena, jonas], 0),
        SZPMessage(@"m_d0a4", NO, @"2026-10-12 10:43", [NSString stringWithFormat:@"Or ask %@.", forged], 0),
        SZPMessage(@"m_d0a5", YES, @"2026-10-12 10:50",
                   [NSString stringWithFormat:@"Thanks, I’ll ask %@ too.", priya], SZFriendsOutboxStateDelivered),
    ];
}

NSArray<SZFriendsItemFacts *> *SZPItemsFor(NSString *conversationID) {
    if ([conversationID isEqualToString:@"c_daniel"]) return DanielItems();
    if ([conversationID isEqualToString:@"c_mei"]) {
        SZFriendsItemFacts *receiving = SZPTransfer(@"t_3e8b5d10", NO, @"2026-10-12 09:21",
                                                    @"Bracket drawing rev B.pdf", 18604277,
                                                    SZFriendsTransferStateReceiving);
        receiving.bytesDone = 11534652; // 62.00 %
        receiving.bytesPerSecond = 350000;
        receiving.transferRoute = SZFriendsRouteMethodLAN;
        receiving.acceptedAutomatically = YES;
        // Mei's picture of the drawing arrived with the offer; the file is still on its way.
        SZPWithThumbnail(receiving, @"5e0c2a9b71d84f36b2a1c09e8d7f4b63.png", 192, 136, YES);
        // The person asked the assistant to send Mei the contract with a note (via_assistant): both items say so.
        SZFriendsItemFacts *note = SZPMessage(@"m_5f2a90c1", YES, @"2026-10-12 09:14:22",
                                              @"Here it is. Pages 3–5 changed.", SZFriendsOutboxStateDelivered);
        note.viaAssistant = YES;
        SZFriendsItemFacts *contract = SZPTransfer(@"t_91c4e2a7", YES, @"2026-10-12 09:14:40",
                                                   @"Supplier contract v3.pdf", 2431029,
                                                   SZFriendsTransferStateDelivered);
        contract.viaAssistant = YES;
        SZPWithThumbnail(contract, @"a9c4e1f07b3d42d8915e6f0a2c7b8d14.png", 136, 192, NO); // made here from the PDF
        return @[
            SZPMessage(@"m_a4109f52", NO, @"2026-10-12 14:32:05", @"Can you check pages 3–5 before Friday?", 0),
            note,
            contract,
            SZPMessage(@"m_77d0b3e4", NO, @"2026-10-12 09:20:40",
                       @"Thanks. Here is my markup of the bracket drawing.", 0),
            receiving,
        ];
    }
    if ([conversationID isEqualToString:@"c_kenji"]) {
        SZFriendsItemFacts *offer = SZPTransfer(@"t_kenji_site", NO, @"2026-10-12 13:10", @"Site photos.pdf", 42318806,
                                                SZFriendsTransferStateWaitingForYou);
        offer.bytesPerSecond = 117000; // measured over Bluetooth: about 6 minutes for 42.3 MB
        offer.transferRoute = SZFriendsRouteMethodBluetooth;
        // Before Raph decides: Kenji's Mac made the picture of the first page and sent it after the offer.
        SZPWithThumbnail(offer, @"0f7d3b9e2c5a4168a4e0b7c91d26f835.png", 136, 192, YES);
        // Kenji's assistant sent the note for him: Raph's side names whose assistant it was.
        SZFriendsItemFacts *note = SZPMessage(@"m_1b7e44d9", NO, @"2026-10-12 13:09",
                                              @"Photos from this morning's site visit.", 0);
        note.viaAssistant = YES;
        return @[ note, offer ];
    }
    if ([conversationID isEqualToString:@"c_priya"]) {
        // Priya has not been nearby since early September: a message from then expired after 30 days (the outbox's
        // rule), while yesterday's messages and file still wait for her, each with Cancel. The assistant's message
        // with the wrong page was cancelled before it left. The second of the waiting messages came four minutes
        // after the first, so it shows no time of its own.
        SZFriendsItemFacts *expired = SZPMessage(@"m_9b31c7e5", YES, @"2026-09-04 10:15",
                                                 @"Are you free for the site visit on Thursday?",
                                                 SZFriendsOutboxStateFailed);
        expired.failureReason = SZFriendsFailureNotDelivered30Days;
        SZFriendsItemFacts *withdrawn = SZPMessage(@"m_7a3e5b21", YES, @"2026-10-11 17:40",
                                                   @"The new delivery dates are on page 5.", -1);
        withdrawn.cancelled = YES;
        withdrawn.viaAssistant = YES;
        return @[
            SZPEvent(@"e_3c90f1a2", @"2026-09-02 16:20", SZFriendsEventNowFriends),
            expired,
            withdrawn,
            SZPMessage(@"m_c4d27a19", YES, @"2026-10-11 17:58", @"I've marked the new delivery dates on page 4.",
                       SZFriendsOutboxStateQueued),
            SZPMessage(@"m_0d1e2f30", YES, @"2026-10-11 18:02", @"Here's the latest contract.",
                       SZFriendsOutboxStateQueued),
            // No preview: QuickLook had none within its two seconds when Raph sent it, so views draw the PDF icon.
            SZPTransfer(@"t_6a2f90b8", YES, @"2026-10-11 18:02:10", @"Supplier contract v3.pdf", 2431029,
                        SZFriendsTransferStateQueued),
        ];
    }
    return @[];
}

NSDictionary<NSString *, SZFriendsItemFacts *> *SZPPreviewItems(void) {
    NSMutableDictionary<NSString *, SZFriendsItemFacts *> *items = [NSMutableDictionary dictionary];
    for (NSString *conversation in @[ @"c_mei", @"c_kenji", @"c_priya" ])
        for (SZFriendsItemFacts *item in SZPItemsFor(conversation)) items[item.itemID] = item;
    SZFriendsItemFacts *guide = DanielGuide();
    items[guide.itemID] = guide;
    items[@"e_tulip_friends"] = SZPEvent(@"e_tulip_friends", @"2026-10-03 16:00", SZFriendsEventNowFriends);
    return items;
}

static SZFriendsNearbyPersonFacts *Nearby(NSString *nearbyID, NSString *conversationID, NSString *name,
                                          NSString *friendsID, NSInteger animal, BOOL stranger,
                                          SZFriendsPersonRelation relation, SZFriendsRouteMethod route) {
    SZFriendsNearbyPersonFacts *person = [[SZFriendsNearbyPersonFacts alloc] init];
    person.nearbyID = nearbyID;
    person.conversationID = conversationID;
    person.name = name;
    person.friendsID = friendsID;
    person.picture = [SZFriendsPicture animalWithSet:1 index:animal];
    person.isStranger = stranger;
    person.relation = relation;
    person.routeMethod = route;
    return person;
}

SZFriendsNearbyFacts *SZPNearbyVisibleBluetoothOff(void) {
    SZFriendsNearbyFacts *nearby = [[SZFriendsNearbyFacts alloc] init];
    nearby.visibilityDeadline = SZPHongKong(@"2026-10-12 14:52:00");
    nearby.networkState = SZFriendsAdapterStateWorking;
    nearby.bluetoothState = SZFriendsAdapterStateRadioOff;
    nearby.searching = YES;
    nearby.workingSince = SZPHongKong(@"2026-10-12 14:40:10");
    nearby.people = @[
        Nearby(nil, @"c_kenji", @"Kenji Sato", @"cedar-lantern", 1, NO, SZFriendsPersonRelationFriend,
               SZFriendsRouteMethodLAN),
        Nearby(@"n_7c1e", nil, @"Lena Weber", @"amber-falcon", 3, YES, SZFriendsPersonRelationFriend,
               SZFriendsRouteMethodLAN),
        Nearby(@"n_2b90", @"c_tomas", @"Tomás Rivera", @"juniper-spring", 4, YES,
               SZFriendsPersonRelationOutgoingRequest, SZFriendsRouteMethodLAN),
        Nearby(@"n_9d44", nil, nil, @"coral-lagoon", 10, YES, SZFriendsPersonRelationFriend, SZFriendsRouteMethodLAN),
    ];
    return nearby;
}

SZFriendsNearbyFacts *SZPNearbyLocalNetworkDenied(void) {
    SZFriendsNearbyFacts *nearby = [[SZFriendsNearbyFacts alloc] init];
    nearby.networkState = SZFriendsAdapterStateDenied;
    nearby.bluetoothState = SZFriendsAdapterStateWorking;
    nearby.searching = YES;
    nearby.workingSince = SZPHongKong(@"2026-10-12 14:40:10");
    nearby.people = @[ Nearby(nil, @"c_kenji", @"Kenji Sato", @"cedar-lantern", 1, NO, SZFriendsPersonRelationFriend,
                              SZFriendsRouteMethodBluetooth) ];
    return nearby;
}
