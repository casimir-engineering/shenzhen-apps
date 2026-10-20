// Presentation tests: every golden fixture under fixtures/snapshots/ rebuilt from the facts behind it, plus the
// Add by ID, search and error replies and the welcome's static strings. Compared as parsed JSON, strictly
// (booleans are not numbers), and every built snapshot is also validated against PROTOCOL.md's schema blocks.
//
// Usage: SZFriendsPresentationTests <PROTOCOL.md> <fixtures dir>

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"

int SZPFailures;
static NSString *FixturesDirectory;
static SZFSchemas *Schemas;

void SZPFail(NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    fprintf(stderr, "FAIL %s\n", message.UTF8String);
    SZPFailures++;
}

static BOOL IsBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

NSString *SZPDifference(id actual, id expected, NSString *path) {
    if ([expected isKindOfClass:NSDictionary.class]) {
        if (![actual isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"%@: not an object", path];
        NSMutableSet *keys = [NSMutableSet setWithArray:[expected allKeys]];
        [keys addObjectsFromArray:[actual allKeys]];
        for (NSString *key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *child = [NSString stringWithFormat:@"%@.%@", path, key];
            if (!actual[key]) return [NSString stringWithFormat:@"%@: missing (expected %@)", child, expected[key]];
            if (!expected[key]) return [NSString stringWithFormat:@"%@: unexpected %@", child, actual[key]];
            NSString *difference = SZPDifference(actual[key], expected[key], child);
            if (difference) return difference;
        }
        return nil;
    }
    if ([expected isKindOfClass:NSArray.class]) {
        if (![actual isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"%@: not an array", path];
        for (NSUInteger i = 0; i < MAX([actual count], [expected count]); i++) {
            NSString *child = [NSString stringWithFormat:@"%@[%lu]", path, (unsigned long)i];
            if (i >= [actual count] || i >= [expected count])
                return [NSString stringWithFormat:@"%@: array lengths %lu vs %lu", child, (unsigned long)[actual count],
                                                  (unsigned long)[expected count]];
            NSString *difference = SZPDifference(actual[i], expected[i], child);
            if (difference) return difference;
        }
        return nil;
    }
    if (IsBoolean(expected) != IsBoolean(actual))
        return [NSString stringWithFormat:@"%@: %@ vs %@ (boolean against number)", path, actual, expected];
    if (![actual isEqual:expected])
        return [NSString stringWithFormat:@"%@:\n  built    %@\n  expected %@", path, actual, expected];
    return nil;
}

id SZPFixture(NSString *relative) {
    NSData *data = [NSData dataWithContentsOfFile:[FixturesDirectory stringByAppendingPathComponent:relative]];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (!json) SZPFail(@"cannot read fixture %@", relative);
    return json;
}

// Round-trips through NSJSONSerialization first: what the helper sends is the serialized form, so a value that
// does not survive serialization (an int where a bool belongs, a non-JSON object) must fail here.
static id Serialized(id object, NSString *label) {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        SZPFail(@"%@: not a JSON object", label);
        return nil;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

static void Validate(NSDictionary *frame, NSArray<NSString *> *schemaIDs, NSString *label) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    SZFValidate(Serialized(frame, label) ?: @{}, schemaIDs, Schemas, label, errors);
    for (NSString *error in errors) SZPFail(@"%@: %@", label, error);
}

void SZPValidateSnapshot(NSDictionary *data, NSString *view, NSString *label) {
    NSDictionary *frame = @{@"type" : @"snapshot", @"subscription" : @"s_1", @"view" : view, @"rev" : @1,
                            @"data" : data ?: @{}};
    Validate(frame, @[ @"frame.snapshot", [@"snapshot." stringByAppendingString:view] ], label);
}

void SZPValidateResult(NSDictionary *result, NSString *intent, NSString *label) {
    NSDictionary *frame = @{@"type" : @"reply", @"re" : @"1", @"ok" : @YES, @"result" : result ?: @{}};
    Validate(frame, @[ @"frame.reply", [@"result." stringByAppendingString:intent] ], label);
}

static void ExpectSnapshot(NSDictionary *built, NSString *fixture, NSString *view) {
    NSDictionary *expected = SZPFixture([@"snapshots/" stringByAppendingString:fixture])[@"data"];
    NSString *difference = SZPDifference(Serialized(built, fixture), expected, @"data");
    if (difference) SZPFail(@"%@ differs at %@", fixture, difference);
    SZPValidateSnapshot(built, view, fixture);
}

void SZPExpectFixture(NSDictionary *built, NSString *fixture, NSString *view) {
    ExpectSnapshot(built, fixture, view);
}

static void TestFixtures(void) {
    SZFriendsAudience *audience = SZPAudience();
    SZFriendsSnapshotBuilder *builder = SZPBuilder(audience);
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();
    NSArray<SZFriendsPersonFacts *> *everyone = people.allValues;
    NSDate *now = SZPNow();

    ExpectSnapshot([builder badgeWithPeople:everyone], @"badge.json", @"badge");
    ExpectSnapshot([builder listWithPeople:everyone previewItems:SZPPreviewItems() profile:SZPProfileRaph() query:@""
                                       now:now],
                   @"list.json", @"list");
    ExpectSnapshot([builder listWithPeople:@[] previewItems:@{} profile:SZPProfileIDChanged() query:@"" now:now],
                   @"list-id-changed.json", @"list");
    ExpectSnapshot([builder nearbyWithFacts:SZPNearbyVisibleBluetoothOff() profile:SZPProfileRaph() query:@"" now:now],
                   @"nearby-visible-bluetooth-off.json", @"nearby");
    ExpectSnapshot([builder nearbyWithFacts:SZPNearbyLocalNetworkDenied() profile:SZPProfileRaph() query:@"" now:now],
                   @"nearby-local-network-denied.json", @"nearby");
    // waitingElsewhere: Lena's request and Kenji's offer wait; each conversation counts the others.
    ExpectSnapshot([builder conversationForPerson:people[@"c_mei"] items:SZPItemsFor(@"c_mei") hasEarlier:NO
                                  highlightItemID:nil waitingElsewhere:2 now:now],
                   @"conversation-mei.json", @"conversation");
    ExpectSnapshot([builder conversationForPerson:people[@"c_kenji"] items:SZPItemsFor(@"c_kenji") hasEarlier:YES
                                  highlightItemID:nil waitingElsewhere:1 now:now],
                   @"conversation-kenji-offer.json", @"conversation");
    ExpectSnapshot([builder conversationForPerson:people[@"c_priya"] items:SZPItemsFor(@"c_priya") hasEarlier:NO
                                  highlightItemID:nil waitingElsewhere:2 now:now],
                   @"conversation-priya-queued.json", @"conversation");
    ExpectSnapshot([builder conversationForPerson:people[@"c_lena"] items:@[] hasEarlier:NO highlightItemID:nil
                                 waitingElsewhere:1 now:now],
                   @"conversation-request-lena.json", @"conversation");
    // Every view below the list carries the same count as the list: Lena's request and Kenji's offer wait while
    // Mei's details and the profile are open.
    ExpectSnapshot([builder detailsForPerson:people[@"c_mei"] waitingElsewhere:2 now:now], @"details-mei.json",
                   @"details");
    ExpectSnapshot([builder profileWithFacts:SZPProfileRaph() waitingElsewhere:2], @"profile-unreserved.json",
                   @"profile");
    ExpectSnapshot([builder settingsWithProfile:SZPProfileRaph() people:everyone], @"settings.json", @"settings");
    // A chosen folder shows its name; a helper without received.folder shows no folder name and no Change….
    SZFriendsProfileFacts *chosen = SZPProfileRaph();
    chosen.receivedDirectory = @"/Users/raph/Documents/From friends";
    chosen.receivedFolderName = @"From friends";
    NSDictionary *received = [builder settingsWithProfile:chosen people:everyone][@"received"];
    if (![received[@"value"] isEqual:@"From friends"] || ![received[@"path"] isEqual:chosen.receivedDirectory] ||
        ![received[@"action"][@"path"] isEqual:chosen.receivedDirectory] ||
        ![received[@"change"][@"action"] isEqual:@"choose_received_folder"]) {
        SZPFail(@"a chosen folder: %@", received);
    }
    // The last file could not be saved in the folder: the note says where it went instead, from the person's side.
    chosen.receivedFallback = SZFriendsReceivedFallbackFactsDownloads;
    received = [builder settingsWithProfile:chosen people:everyone][@"received"];
    SZPExpect([received[@"note"] isEqual:@"The last file couldn’t be saved here, so it went to Downloads."],
              @"fallback to Downloads: %@", received[@"note"]);
    chosen.receivedFallback = SZFriendsReceivedFallbackFactsKept;
    received = [builder settingsWithProfile:chosen people:everyone][@"received"];
    NSString *kept = [NSString stringWithFormat:@"The last file couldn’t be saved here, so %@ kept it. Open it "
                                                @"from its chat.", SZPAudience().appName];
    SZPExpect([received[@"note"] isEqual:kept], @"kept by the app: %@", received[@"note"]);
    SZFriendsAudience *older = SZPAudience();
    older.helperCapabilities = [NSSet set];
    received = [SZPBuilder(older) settingsWithProfile:SZPProfileRaph() people:everyone][@"received"];
    if (received[@"value"] || received[@"path"] || received[@"change"] || ![received[@"note"] isEqual:@""]) {
        SZPFail(@"without received.folder: %@", received);
    }
}

static void TestReplies(void) {
    SZFriendsAudience *audience = SZPAudience();
    SZFriendsSnapshotBuilder *builder = SZPBuilder(audience);
    SZFriendsStrings *strings = builder.strings;
    NSDictionary<NSString *, SZFriendsPersonFacts *> *people = SZPPeople();

    NSDictionary *welcome = SZPFixture(@"frames/welcome.json");
    NSString *difference = SZPDifference(strings.staticStrings, welcome[@"strings"], @"strings");
    if (difference) SZPFail(@"welcome.strings differs at %@", difference);

    NSDictionary *addByID = SZPFixture(@"replies/add_by_id.json");
    SZPExpect([[strings addByIDSentMessageForID:@"willow-breeze"] isEqualToString:addByID[@"result"][@"message"]],
              @"add_by_id message: %@", [strings addByIDSentMessageForID:@"willow-breeze"]);
    // Online, with any number of computers or phones on either side, Macs or not.
    NSString *online = [strings addByIDSentMessageForID:@"willow-breeze" online:YES];
    SZPExpect([online isEqualToString:@"Request sent to willow‑breeze. They’ll get it while ShenzhenPDF, Shenzhen "
                                      @"Files or Shenzhen 3D is open for both of you, and you’ll be friends once "
                                      @"they accept."],
              @"add_by_id online message: %@", online);

    NSDictionary *error = SZPFixture(@"frames/reply-error.json")[@"error"];
    NSMutableDictionary *details = [error[@"details"] mutableCopy];
    details[@"file_name"] = @"Site photos.pdf"; // the helper names the offer for the sentence, not on the wire
    NSString *message = [strings messageForErrorCode:error[@"code"] details:details];
    SZPExpect([message isEqualToString:error[@"message"]], @"disk_full message: %@", message);

    SZFriendsSearchHitFacts *first = [[SZFriendsSearchHitFacts alloc] init];
    first.conversationID = @"c_mei";
    first.itemID = @"m_a4109f52";
    first.sentAt = SZPHongKong(@"2026-10-12 14:32:05");
    first.text = @"Can you check pages 3–5 before Friday?";
    first.matchRanges = @[ [NSValue valueWithRange:NSMakeRange(14, 5)] ];
    SZFriendsSearchHitFacts *second = [[SZFriendsSearchHitFacts alloc] init];
    second.conversationID = @"c_mei";
    second.itemID = @"m_5f2a90c1";
    second.sentAt = SZPHongKong(@"2026-10-12 09:14:22");
    second.outgoing = YES;
    second.text = @"Here it is. Pages 3–5 changed.";
    second.matchRanges = @[ [NSValue valueWithRange:NSMakeRange(12, 5)] ];
    NSDictionary *result = [builder searchResultWithHits:@[ first, second ] people:people more:NO now:SZPNow()];
    difference = SZPDifference(Serialized(result, @"search"), SZPFixture(@"replies/search_messages.json")[@"result"],
                               @"result");
    if (difference) SZPFail(@"search_messages result differs at %@", difference);
    SZPValidateResult(result, @"search_messages", @"search_messages");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s <PROTOCOL.md> <fixtures dir>\n", argv[0]);
            return 2;
        }
        NSString *markdown = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:NULL];
        FixturesDirectory = @(argv[2]);
        // The real animal set from the repository: an animal avatar's color is its manifest color (PROTOCOL.md
        // § Shared objects), so the fixtures must agree with the manifest, not with a copy of it.
        NSString *friends = [@(argv[1]) stringByDeletingLastPathComponent];
        if (!friends.isAbsolutePath)
            friends = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:friends];
        SZPFriendsDirectory = friends.stringByStandardizingPath;
        NSString *manifest = [friends stringByAppendingPathComponent:@"avatars/animals/manifest.json"];
        setenv("SZFRIENDS_AVATARS_MANIFEST", manifest.stringByStandardizingPath.fileSystemRepresentation, 1);
        if (![SZFriendsAnimalSet bundledSet]) SZPFail(@"the animal set did not load from %@", manifest);
        Schemas = SZFParseSchemas(markdown ?: @"", @"PROTOCOL.md");
        if (Schemas.count < 10) SZPFail(@"PROTOCOL.md schemas did not load");
        SZPRunFixtureTests();
        SZPRunLabelTests();
        SZPRunViewEdgeTests();
        SZPRunFailureTests();
        SZPRunReaderTests();
        SZPRunAssistantTests();
        SZPRunMentionTextTests();
        SZPRunMentionTests();
        SZPRunOnlineTests();
        SZPRunLinksTests();
        SZPRunHistoryTests();
        SZPRunJoinTests();
        SZPRunDevicesTests();
        SZPRunDevicesBuildTests();
        SZPRunRemoveTests();
        // Keys under "test." are looked up on purpose by the lookup test.
        NSSet<NSString *> *missing = [SZFriendsMissingCatalogKeys()
            objectsPassingTest:^BOOL(NSString *key, BOOL *stop) {
              (void)stop;
              return ![key hasPrefix:@"test."];
            }];
        if (missing.count)
            SZPFail(@"catalog keys looked up but missing: %@",
                    [[missing.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "]);
        if (SZPFailures || SZFFailures) {
            fprintf(stderr, "SZFriendsPresentationTests: %d failures\n", SZPFailures + SZFFailures);
            return 1;
        }
        printf("SZFriendsPresentationTests passed\n");
        return 0;
    }
}

void SZPRunFixtureTests(void) {
    TestFixtures();
    TestReplies();
}
