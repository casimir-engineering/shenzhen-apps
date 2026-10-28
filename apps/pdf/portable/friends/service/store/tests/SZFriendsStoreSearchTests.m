// Search: Chinese short terms, folding, phrase ranking, scope, the scan-only path, restarts and excerpts.

#import "SZFriendsStoreTestSupport.h"

static void Seed(SZFriendsStore *store) {
    SZFTAddPerson(store, @"a", 1, SZFriendsRelationFriend, 1000);
    SZFTAddPerson(store, @"b", 2, SZFriendsRelationFriend, 1000);
    NSArray *rows = @[
        @[ @"a", @"a1", @"请把合同发给我", @900 ], @[ @"a", @"a2", @"合作愉快", @800 ],
        @[ @"b", @"b3", @"The contract (合同) report is ready", @700 ], @[ @"b", @"b4", @"Café menu", @600 ],
        @[ @"a", @"a5", @"CAFE closed", @500 ], @[ @"b", @"b6", @"naïve résumé attached", @400 ],
        @[ @"a", @"a7", @"is report ready", @1000 ], @[ @"a", @"a8", @"report is ready", @100 ],
        @[ @"a", @"a9", @"line one\nline two", @50 ]
    ];
    for (NSArray *row in rows) {
        [store insertItem:SZFTMessage(row[0], row[1], row[2], [row[3] doubleValue], SZFriendsDirectionIncoming)
                    error:NULL];
    }
    SZFriendsTransferRecord *transfer = [[SZFriendsTransferRecord alloc] init];
    transfer.transferID = @"t1";
    transfer.conversationID = @"b";
    transfer.fileName = @"Site photos.pdf";
    transfer.size = 10;
    transfer.contentDigest = SZFTBytes(1, 32);
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return SZFriendsTransferRowInsert(db, transfer, nil, error);
    } error:NULL];
    SZFriendsItemRecord *file = SZFTMessage(@"b", @"t1", nil, 300, SZFriendsDirectionIncoming);
    file.kind = SZFriendsItemKindTransfer;
    file.text = nil;
    file.transferID = @"t1";
    [store insertItem:file error:NULL];
    SZFriendsItemRecord *event = SZFTMessage(@"a", @"ev", @"report", 2000, SZFriendsDirectionIncoming);
    event.kind = SZFriendsItemKindEvent;
    event.eventKind = @"now_friends";
    [store insertItem:event error:NULL];
}

static NSArray<NSString *> *Hits(SZFriendsStore *store, NSString *query, NSArray *_Nullable scope, NSUInteger limit) {
    return [[store searchFor:query conversationIDs:scope limit:limit] valueForKey:@"itemID"];
}

static void CheckQueries(SZFriendsStore *store, NSString *mode) {
    NSDictionary<NSString *, NSArray *> *expected = @{
        @"合同" : @[ @"a1", @"b3" ],
        @"合" : @[ @"a1", @"a2", @"b3" ],
        @"合同 report" : @[ @"b3" ],
        @"report 合同" : @[ @"b3" ],
        @"cafe" : @[ @"b4", @"a5" ],
        @"ＣＡＦＥ" : @[ @"b4", @"a5" ],
        @"RÉSUMÉ" : @[ @"b6" ],
        @"naive resume" : @[ @"b6" ],
        @"photos" : @[ @"t1" ],
        @"line two" : @[ @"a9" ],
        @"zzz" : @[],
        @"   " : @[],
        @"report is" : @[ @"b3", @"a8", @"a7" ],
    };
    for (NSString *query in expected) {
        NSArray *hits = Hits(store, query, nil, 20);
        SZFTExpect([hits isEqual:expected[query]], @"%@: \"%@\" gave %@, want %@", mode, query, hits, expected[query]);
    }
    SZFTExpect([Hits(store, @"合同", @[], 20) count] == 0, @"%@: an empty scope sees nothing", mode);
    SZFTExpect([Hits(store, @"合同", @[ @"b" ], 20) isEqual:@[ @"b3" ]], @"%@: scoped to b", mode);
    SZFTExpect([Hits(store, @"合同", @[ @"a", @"b" ], 20) isEqual:(@[ @"a1", @"b3" ])], @"%@: scoped to both", mode);
    SZFTExpect([Hits(store, @"合", nil, 2) isEqual:(@[ @"a1", @"a2" ])], @"%@: limit keeps the newest", mode);
    SZFriendsSearchHit *cafe = [store searchFor:@"cafe" conversationIDs:@[ @"b" ] limit:1].firstObject;
    SZFTExpect([cafe.matchRanges isEqual:@[ [NSValue valueWithRange:NSMakeRange(0, 4)] ]], @"%@: range %@", mode,
               cafe.matchRanges);
    SZFriendsSearchHit *mixed = [store searchFor:@"合同 report" conversationIDs:nil limit:1].firstObject;
    NSArray *ranges = @[ [NSValue valueWithRange:NSMakeRange(14, 2)], [NSValue valueWithRange:NSMakeRange(18, 6)] ];
    SZFTExpect([mixed.matchRanges isEqual:ranges], @"%@: mixed ranges %@", mode, mixed.matchRanges);
    SZFriendsSearchHit *photo = [store searchFor:@"photos" conversationIDs:nil limit:1].firstObject;
    SZFTExpect(photo.kind == SZFriendsItemKindTransfer && [photo.text isEqualToString:@"Site photos.pdf"] &&
                   [photo.conversationID isEqualToString:@"b"], @"%@: file names are found", mode);
}

static void TestSearchWithIndexAndWithScan(void) {
    NSString *directory = SZFTTemporaryDirectory(@"search");
    SZFriendsStore *store = SZFTOpenStore(directory);
    Seed(store);
    SZFTExpect(store.searchUsesIndex == SZFTIndexExpected(), @"index");
    CheckQueries(store, @"index");
    [store close];
    SZFriendsStore *reopened = SZFTOpenStore(directory);
    SZFTExpect([Hits(reopened, @"合同", nil, 20) isEqual:(@[ @"a1", @"b3" ])], @"results survive a restart");
    SZFTExpect([Hits(reopened, @"contract", nil, 20) isEqual:@[ @"b3" ]], @"the index survives a restart");
    [reopened close];
    SZFriendsStoreOptions *scanOnly = [[SZFriendsStoreOptions alloc] init];
    scanOnly.disableTrigram = YES;
    SZFriendsStore *scanning = SZFTOpenStoreWithOptions(directory, scanOnly, NULL);
    SZFTExpect(scanning && !scanning.searchUsesIndex, @"forced probe failure scans");
    CheckQueries(scanning, @"scan");
    // Written while the index could not be maintained: the next helper with trigram must not trust a stale index.
    [scanning insertItem:SZFTMessage(@"a", @"late", @"written without the index", 3000, SZFriendsDirectionIncoming)
                   error:NULL];
    SZFTExpect([Hits(scanning, @"without", nil, 5) isEqual:@[ @"late" ]], @"scan finds it");
    [scanning close];
    SZFriendsStore *indexed = SZFTOpenStore(directory);
    SZFTExpect([Hits(indexed, @"without", nil, 5) isEqual:@[ @"late" ]], @"the stale index was rebuilt");
    SZFTExpect(!SZFTIndexExpected() || !SZFTScalar(indexed, @"SELECT value FROM meta WHERE key = 'search_stale'", @[]),
               @"stale flag cleared");
}

static void TestExcerpts(void) {
    NSArray *ranges = nil;
    NSString *shortText = @"short message";
    NSString *same = SZFriendsSearchExcerpt(shortText, @[ [NSValue valueWithRange:NSMakeRange(6, 7)] ], 280, &ranges);
    SZFTExpect([same isEqualToString:shortText] && [ranges isEqual:@[ [NSValue valueWithRange:NSMakeRange(6, 7)] ]],
               @"short text unchanged");
    NSMutableString *longText = [NSMutableString string];
    for (int i = 0; i < 100; i++) [longText appendString:@"filler words "];
    NSUInteger matchAt = longText.length;
    [longText appendString:@"合同 deadline"];
    for (int i = 0; i < 100; i++) [longText appendString:@" more text"];
    NSArray *match = @[ [NSValue valueWithRange:NSMakeRange(matchAt, 2)] ];
    NSString *excerpt = SZFriendsSearchExcerpt(longText, match, 280, &ranges);
    SZFTExpect(excerpt.length <= 280, @"bounded: %lu", (unsigned long)excerpt.length);
    SZFTExpect([excerpt hasPrefix:@"…"] && [excerpt hasSuffix:@"…"], @"cuts are marked");
    NSRange shown = [ranges.firstObject rangeValue];
    SZFTExpect(ranges.count == 1 && [[excerpt substringWithRange:shown] isEqualToString:@"合同"], @"range shifted");
    NSString *emoji = [@"" stringByPaddingToLength:150 withString:@"👍" startingAtIndex:0];
    NSString *cut = SZFriendsSearchExcerpt(emoji, @[ [NSValue valueWithRange:NSMakeRange(100, 2)] ], 41, NULL);
    SZFTExpect(cut.length <= 41, @"emoji bounded");
    SZFTExpect([[cut stringByReplacingOccurrencesOfString:@"…" withString:@""]
                   stringByReplacingOccurrencesOfString:@"👍" withString:@""].length == 0, @"no half emoji: %@", cut);
    NSString *lines = SZFriendsSearchExcerpt(@"one\r\ntwo", @[], 280, NULL);
    SZFTExpect([lines isEqualToString:@"one  two"], @"line breaks become spaces: %@", lines);
}

static void TestSearchSpeed(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"speed"));
    SZFTAddPerson(store, @"a", 1, SZFriendsRelationFriend, 1000);
    NSArray *phrases = @[ @"请把合同发给我", @"meeting notes for Thursday", @"发票已经寄出", @"photos from the site visit" ];
    const int count = 10000;
    [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        for (int i = 0; i < count; i++) {
            SZFriendsItemRecord *item = SZFTMessage(@"a", [NSString stringWithFormat:@"m%d", i],
                                                    [NSString stringWithFormat:@"%@ %d", phrases[i % 4], i], i,
                                                    SZFriendsDirectionIncoming);
            if (!SZFriendsStoreInsertItem(db, item, NULL, error)) return NO;
        }
        return YES;
    } error:NULL];
    for (NSString *query in @[ @"合同", @"site visit", @"合" ]) {
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        for (int run = 0; run < 20; run++) {
            NSDate *start = [NSDate date];
            NSArray *hits = [store searchFor:query conversationIDs:nil limit:21];
            [times addObject:@(-[start timeIntervalSinceNow] * 1000)];
            SZFTExpect(hits.count == 21, @"\"%@\" fills the page", query);
        }
        [times sortUsingSelector:@selector(compare:)];
        double p95 = times[18].doubleValue;
        printf("search \"%s\" over %d messages: p95 %.1f ms\n", query.UTF8String, count, p95);
        // The budget is 100 ms (ADR 0003); this bound only catches a pathological plan on a busy machine.
        SZFTExpect(p95 < 1000, @"\"%@\" p95 %.1f ms", query, p95);
    }
}

void SZFTRunSearchTests(void) {
    TestSearchWithIndexAndWithScan();
    TestExcerpts();
    TestSearchSpeed();
}
