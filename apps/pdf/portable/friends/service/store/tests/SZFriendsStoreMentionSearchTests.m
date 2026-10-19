// Search over mentions (ADR 0007; ADR 0003, Corrections): the index holds each mention as the "@Name" label a reader
// sees, never the Friends ID and key its link carries. Nothing is found through them, every hit has a match a view can
// show (so a page of results is never cut short by hits the presentation drops), and rows written before the fold are
// refolded when the store opens.

#import "SZFriendsStoreTestSupport.h"

#import "service/presentation/SZFriendsMentions.h"

// A key whose base64url spelling holds "Otter" eight times, and the ID brave-otter: a search for "otter" would find
// every message mentioning this person if destinations were indexed. The last character carries no stray bits, so the
// spelling is canonical.
static NSString *const SZFTOtterKey = @"OtterOtterOtterOtterOtterOtterOtterOtterOtA";
static NSString *const SZFTMeiKey = @"C7p4jaaHK1zWWJGVH-YasjrlEk8qfJvd3KLmn0IFY3E";

static NSString *SZFTMention(NSString *name, NSString *friendsID, NSString *key) {
    NSData *identityKey = SZFriendsMentionKeyFromString(key);
    NSString *link = identityKey ? SZFriendsMentionLink(name, friendsID, identityKey) : nil;
    SZFTExpect(link != nil, @"a well-formed mention of %@", name);
    return link ?: @"";
}

static NSArray<NSString *> *SZFTHits(SZFriendsStore *store, NSString *query, NSUInteger limit) {
    return [[store searchFor:query conversationIDs:nil limit:limit] valueForKey:@"itemID"];
}

static void SZFTInsert(SZFriendsStore *store, NSString *itemID, NSString *text, NSTimeInterval sentAt) {
    SZFTExpect([store insertItem:SZFTMessage(@"a", itemID, text, sentAt, SZFriendsDirectionIncoming) error:NULL],
               @"insert %@", itemID);
}

static NSString *SZFTOttoLink(void) {
    return SZFTMention(@"Otto", @"brave-otter", SZFTOtterKey);
}

static void SZFTSeedMentions(SZFriendsStore *store) {
    SZFTAddPerson(store, @"a", 1, SZFriendsRelationFriend, 1000);
    SZFTInsert(store, @"m1", [NSString stringWithFormat:@"Ask %@ about it",
                                                        SZFTMention(@"Mei Lin", @"jasmine-street", SZFTMeiKey)], 100);
    SZFTInsert(store, @"m2", @"jasmine tea is ready", 90);
    SZFTInsert(store, @"m3", [NSString stringWithFormat:@"%@ sent it",
                                                        SZFTMention(@"Mei_Lin", @"jasmine-street", SZFTMeiKey)], 80);
    SZFTInsert(store, @"otto", [SZFTOttoLink() stringByAppendingString:@"'s otter"], 70);
    SZFTInsert(store, @"p1", @"an otter swam by", 60);
    SZFTInsert(store, @"p2", @"otters everywhere", 50);
    SZFTInsert(store, @"p3", @"sea otter", 40);
    // Newer than all of the above, each mentioning brave-otter and nothing else about otters.
    for (int i = 0; i < 25; i++) {
        NSString *text = [NSString stringWithFormat:@"%@ says hi %d", SZFTMention(@"Leo", @"brave-otter", SZFTOtterKey),
                                                    i];
        SZFTInsert(store, [NSString stringWithFormat:@"n%d", i], text, 1000 + i);
    }
}

static void SZFTCheckMentionQueries(SZFriendsStore *store, NSString *mode) {
    NSDictionary<NSString *, NSArray *> *expected = @{
        @"jasmine" : @[ @"m2" ],
        @"street" : @[],
        @"C7p4jaaHK1" : @[],
        @"szfriends" : @[],
        @"mention" : @[],
        @"key=" : @[],
        @"Mei Lin" : @[ @"m1", @"m3" ], // every term, in any order: "Mei_Lin" holds both, the phrase ranks first
        @"mei_lin" : @[ @"m3" ],
        @"@Leo says" : @[ @"n24", @"n23" ],
    };
    for (NSString *query in expected) {
        NSUInteger limit = [query hasPrefix:@"@Leo"] ? 2 : 20;
        NSArray *hits = SZFTHits(store, query, limit);
        SZFTExpect([hits isEqual:expected[query]], @"%@: \"%@\" gave %@, want %@", mode, query, hits, expected[query]);
    }
    // A page of three: the 25 newer messages mention brave-otter, but none says "otter" where a reader sees it, so
    // they take no place in it (the presentation would have dropped every one, leaving the page empty).
    NSArray *page = SZFTHits(store, @"otter", 3);
    SZFTExpect([page isEqual:(@[ @"otto", @"p1", @"p2" ])], @"%@: a full page of real matches: %@", mode, page);

    // Ranges are in the stored text: a match in a mention covers its label, never its destination, which holds
    // "otter" nine times here; a match running from the label into the words after it keeps both parts.
    NSUInteger link = SZFTOttoLink().length;
    SZFriendsSearchHit *otto = [store searchFor:@"ott" conversationIDs:nil limit:1].firstObject;
    NSArray *ranges =
        @[ [NSValue valueWithRange:NSMakeRange(1, 5)], [NSValue valueWithRange:NSMakeRange(link + 3, 3)] ];
    SZFTExpect([otto.itemID isEqual:@"otto"] && [otto.matchRanges isEqual:ranges], @"%@: \"ott\" lights the label and "
               @"the word, nothing in the link: %@ %@", mode, otto.itemID, otto.matchRanges);
    SZFTExpect([[otto.text substringWithRange:NSMakeRange(1, 5)] isEqualToString:@"@Otto"], @"%@: the label", mode);
    SZFriendsSearchHit *spanning = [store searchFor:@"otto's" conversationIDs:nil limit:1].firstObject;
    ranges = @[ [NSValue valueWithRange:NSMakeRange(1, 5)], [NSValue valueWithRange:NSMakeRange(link, 2)] ];
    SZFTExpect([spanning.itemID isEqual:@"otto"] && [spanning.matchRanges isEqual:ranges],
               @"%@: a term across the label's end: %@ %@", mode, spanning.itemID, spanning.matchRanges);
}

static void SZFTTestMentionsFoldToLabels(void) {
    NSString *directory = SZFTTemporaryDirectory(@"mention-search");
    SZFriendsStore *store = SZFTOpenStore(directory);
    SZFTSeedMentions(store);
    SZFTExpect(store.searchUsesIndex, @"index");
    SZFTCheckMentionQueries(store, @"index");
    NSNumber *leaks = SZFTScalar(store, @"SELECT count(*) FROM messages WHERE folded LIKE '%szfriends%' OR folded "
                                        @"LIKE '%jasmine-street%' OR folded LIKE '%otterotter%'", @[]);
    SZFTExpect(leaks.integerValue == 0, @"the folded column holds no mention's ID, key or scheme (%@ rows)", leaks);
    NSString *folded = SZFTScalar(store, @"SELECT folded FROM messages WHERE item_id = 'm3'", @[]);
    SZFTExpect([folded isEqualToString:@"@mei_lin sent it"], @"the label as a reader sees it, unescaped: %@", folded);
    [store close];
    SZFriendsStoreOptions *scanOnly = [[SZFriendsStoreOptions alloc] init];
    scanOnly.disableTrigram = YES;
    SZFriendsStore *scanning = SZFTOpenStoreWithOptions(directory, scanOnly, NULL);
    SZFTExpect(scanning && !scanning.searchUsesIndex, @"scan-only");
    SZFTCheckMentionQueries(scanning, @"scan");
    [scanning close];
}

// A store whose rows were folded before mentions were (a helper from before this change): opening refolds them, with
// the index kept in step, or rebuilt when the scan-only path wrote meanwhile.
static void SZFTTestRefoldAtOpen(BOOL index) {
    NSString *mode = index ? @"index" : @"scan";
    NSString *directory = SZFTTemporaryDirectory(@"mention-refold");
    SZFriendsStoreOptions *options = [[SZFriendsStoreOptions alloc] init];
    options.disableTrigram = !index;
    SZFriendsStore *store = SZFTOpenStoreWithOptions(directory, options, NULL);
    SZFTAddPerson(store, @"a", 1, SZFriendsRelationFriend, 1000);
    NSString *text = [NSString stringWithFormat:@"Ask %@ about it",
                                                SZFTMention(@"Mei Lin", @"jasmine-street", SZFTMeiKey)];
    SZFTInsert(store, @"m1", text, 100);
    BOOL rewound = [store performWrite:^BOOL(SZFriendsStoreDB *db, NSError **error) {
        return [db run:@"UPDATE messages SET folded = ? WHERE item_id = 'm1'" binds:@[ SZFriendsSearchFold(text) ]
                   row:nil error:error] &&
               [db exec:@"DELETE FROM meta WHERE key = 'search_fold'" error:error];
    } error:NULL];
    SZFTExpect(rewound && [SZFTHits(store, @"jasmine", 5) isEqual:@[ @"m1" ]],
               @"%@: a row folded the old way is found by the ID", mode);
    [store close];
    store = SZFTOpenStoreWithOptions(directory, options, NULL);
    SZFTExpect([SZFTHits(store, @"jasmine", 5) count] == 0 && [SZFTHits(store, @"Mei Lin", 5) isEqual:@[ @"m1" ]],
               @"%@: refolded at open: %@", mode, SZFTHits(store, @"jasmine", 5));
    SZFTExpect([SZFTScalar(store, @"SELECT value FROM meta WHERE key = 'search_fold'", @[]) isEqual:@"labels"],
               @"%@: recorded, so it runs once", mode);
    [store close];
    // Scan-only writes leave the index stale; the next helper with trigram rebuilds it from the refolded rows.
    SZFriendsStore *indexed = SZFTOpenStore(directory);
    SZFTExpect([SZFTHits(indexed, @"jasmine", 5) count] == 0, @"%@: the index agrees", mode);
    [indexed close];
}

void SZFTRunMentionSearchTests(void) {
    SZFTTestMentionsFoldToLabels();
    SZFTTestRefoldAtOpen(YES);
    SZFTTestRefoldAtOpen(NO);
}
