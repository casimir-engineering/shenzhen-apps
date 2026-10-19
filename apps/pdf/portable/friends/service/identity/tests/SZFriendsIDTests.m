// Friends IDs: what Add by ID accepts, how IDs are drawn, when they get three words, and the reservation states.

#import "service/identity/SZFriendsIdentityInternal.h"
#import "SZFriendsIdentityTestSupport.h"

static SZFriendsIDCodec *SmallCodec(void) {
    SZFriendsWordList *list = [SZFriendsWordList listWithWords:@[ @"maple", @"river", @"harbor", @"otter", @"cedar" ]
                                                       version:1
                                                         error:NULL];
    return [[SZFriendsIDCodec alloc] initWithWordList:list];
}

// Returns the scripted values in turn and records every bound it was asked for.
static SZFriendsRandomUniform Scripted(NSArray<NSNumber *> *values, NSMutableArray<NSNumber *> *bounds) {
    __block NSUInteger next = 0;
    return ^uint32_t(uint32_t bound) {
        [bounds addObject:@(bound)];
        return (uint32_t)values[next++ % values.count].unsignedIntValue;
    };
}

static void TestNormalisation(void) {
    SZFriendsIDCodec *codec = SmallCodec();
    NSDictionary<NSString *, NSString *> *accepted = @{
        @"maple-river" : @"maple-river",
        @"Maple River" : @"maple-river",
        @"  MAPLE.river\n" : @"maple-river",
        @"maple_river" : @"maple-river",
        @"maple - river" : @"maple-river",
        @"maple--river" : @"maple-river",
        @"maple river otter" : @"maple-river-otter",
        @"maple—river" : @"maple-river",       // em dash from smart punctuation
        @"maple–river" : @"maple-river",       // en dash
        @"ｍａｐｌｅ　ｒｉｖｅｒ" : @"maple-river", // full-width + IME space
        @"maple。river" : @"maple-river",       // ideographic full stop
        @"maple－river" : @"maple-river",       // full-width hyphen
        @"\tmaple\triver\t" : @"maple-river",
    };
    [accepted enumerateKeysAndObjectsUsingBlock:^(NSString *input, NSString *expected, BOOL *stop) {
        (void)stop;
        NSString *got = [codec normalizedID:input];
        SZFExpect([got isEqualToString:expected], @"'%@' -> %@, got %@", input, expected, got);
    }];
    for (NSString *input in @[ @"", @"maple", @"maple-river-otter-cedar", @"maple-rivers", @"maple-riv", @"mapleriver",
                               @"maple/river", @"maple,river", @"maple-river!", @"-", @"   ", @"maple-r1ver",
                               @"mäple-river", @"MAPLE-İVER" ]) {
        SZFExpect([codec normalizedID:input] == nil, @"rejects '%@'", input);
    }
    NSString *huge = [@"" stringByPaddingToLength:10000 withString:@"maple " startingAtIndex:0];
    SZFExpect([codec normalizedID:huge] == nil, @"a pasted page is rejected without splitting it");

    // The real list: a drawn ID normalises to itself, in any case and with any separator.
    SZFriendsIDCodec *real = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSString *drawn = [real randomIDWithWordCount:2 generator:SZFriendsSystemRandomUniform()];
    SZFExpect([[real normalizedID:drawn] isEqualToString:drawn], @"%@ round trip", drawn);
    NSString *typed = [[drawn uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@" . "];
    SZFExpect([[real normalizedID:typed] isEqualToString:drawn], @"%@ typed as %@", drawn, typed);
}

static void TestDraws(void) {
    SZFriendsIDCodec *codec = SmallCodec();
    NSMutableArray *bounds = [NSMutableArray array];
    SZFExpect([[codec randomIDWithWordCount:2 generator:Scripted(@[ @0, @3 ], bounds)] isEqualToString:@"maple-otter"],
              @"two scripted words");
    SZFExpect([[codec randomIDWithWordCount:3 generator:Scripted(@[ @4, @1, @2 ], bounds)]
                  isEqualToString:@"cedar-river-harbor"], @"three scripted words");
    SZFExpect([bounds isEqualToArray:(@[ @5, @5, @5, @5, @5 ])], @"every draw is bounded by the list size: %@", bounds);
    SZFExpect(SZFRaises(NSInvalidArgumentException,
                        ^{ [codec randomIDWithWordCount:1 generator:Scripted(@[ @0 ], nil)]; }),
              @"one word raises");
    SZFExpect(SZFRaises(NSInvalidArgumentException,
                        ^{ [codec randomIDWithWordCount:4 generator:Scripted(@[ @0 ], nil)]; }),
              @"four words raise");
    SZFExpect(SZFRaises(NSInvalidArgumentException,
                        ^{ [codec randomIDWithWordCount:2 generator:Scripted(@[ @5 ], nil)]; }),
              @"a draw at the bound raises");

    // libsodium's draws over the real list: bound 2,048, and every word reachable in practice.
    SZFriendsIDCodec *real = [[SZFriendsIDCodec alloc] initWithWordList:[SZFriendsWordList bundledList]];
    NSMutableArray *realBounds = [NSMutableArray array];
    SZFriendsRandomUniform system = SZFriendsSystemRandomUniform();
    SZFriendsRandomUniform recording = ^uint32_t(uint32_t bound) {
        [realBounds addObject:@(bound)];
        return system(bound);
    };
    NSMutableSet *seen = [NSMutableSet set];
    for (int i = 0; i < 20000; i++) {
        for (NSString *word in [[real randomIDWithWordCount:2 generator:recording] componentsSeparatedByString:@"-"]) {
            [seen addObject:word];
        }
    }
    SZFExpect([[NSSet setWithArray:realBounds] isEqualToSet:[NSSet setWithObject:@2048]], @"bound is 2,048");
    // 40,000 uniform draws miss a given word with probability (1 - 1/2048)^40000, about 3e-9; all 2,048 appear.
    SZFExpect(seen.count == 2048, @"uniform draws reach every word: %lu", (unsigned long)seen.count);
}

static void TestWordCount(void) {
    SZFExpect(SZFriendsWordCountForNewID(2, 0) == 2, @"two words by default");
    SZFExpect(SZFriendsWordCountForNewID(2, 2) == 2, @"two collisions stay two words");
    SZFExpect(SZFriendsWordCountForNewID(2, 3) == 3, @"three collisions in a row mean three words");
    SZFExpect(SZFriendsWordCountForNewID(2, 9) == 3, @"and stay three");
    SZFExpect(SZFriendsWordCountForNewID(3, 0) == 3, @"the host list's new_id_words 3");
    SZFExpect(SZFriendsWordCountForNewID(0, 0) == 2 && SZFriendsWordCountForNewID(-1, 0) == 2, @"bad list value");
    SZFExpect(SZFriendsWordCountForNewID(7, 0) == 3, @"a future larger value still draws the most this app can");
}

static void TestStatus(void) {
    SZFriendsIDCodec *codec = SmallCodec();
    SZFriendsIDStatus *status = [SZFriendsIDStatus initialStatusWithCodec:codec listNewIDWords:2
                                                                generator:Scripted(@[ @0, @1 ], nil)];
    SZFExpect([status.friendsID isEqualToString:@"maple-river"] && status.state == SZFriendsIDStateUnreserved &&
                  status.previousID == nil && status.collisionsInARow == 0, @"first start: %@", status);
    SZFriendsIDStatus *three = [SZFriendsIDStatus initialStatusWithCodec:codec listNewIDWords:3
                                                               generator:Scripted(@[ @2 ], nil)];
    SZFExpect([three.friendsID isEqualToString:@"harbor-harbor-harbor"], @"list says three words: %@", three);

    // Our ID was free: Reserved.
    SZFriendsIDStatus *reserved = [status statusAfterReservationOf:@"maple-river"];
    SZFExpect(reserved.state == SZFriendsIDStateReserved && reserved.previousID == nil, @"reserved: %@", reserved);
    SZFExpect([reserved.friendsID isEqualToString:@"maple-river"], @"same ID");

    // Taken, a fresh draw reserved: Changed, telling the ID the person knew, until dismissed.
    SZFriendsIDStatus *collided = [status statusAfterCollision];
    SZFExpect(collided.collisionsInARow == 1 && collided.state == SZFriendsIDStateUnreserved, @"one collision");
    NSString *replacement = [collided replacementIDWithCodec:codec listNewIDWords:2
                                                   generator:Scripted(@[ @0, @1, @0, @2 ], nil)];
    SZFExpect([replacement isEqualToString:@"maple-harbor"], @"never redraws the refused ID: %@", replacement);
    SZFriendsIDStatus *changed = [collided statusAfterRenameFrom:@"maple-river" to:@"maple-harbor"];
    SZFExpect(changed.state == SZFriendsIDStateChanged && [changed.friendsID isEqualToString:@"maple-harbor"] &&
                  [changed.previousID isEqualToString:@"maple-river"] && changed.collisionsInARow == 0,
              @"changed: %@", changed);
    SZFExpect([changed statusAfterReservationOf:@"maple-harbor"].state == SZFriendsIDStateChanged,
              @"a later check-in confirming the new ID keeps the unread notice");
    SZFriendsIDStatus *dismissed = [changed statusAfterNoticeDismissed];
    SZFExpect(dismissed.state == SZFriendsIDStateReserved && dismissed.previousID == nil &&
                  [dismissed.friendsID isEqualToString:@"maple-harbor"], @"dismissed: %@", dismissed);
    SZFExpect([reserved statusAfterNoticeDismissed] == reserved, @"dismissing nothing changes nothing");

    // A second rename before the notice was read still names the ID the person knew.
    SZFriendsIDStatus *twice = [changed statusAfterRenameFrom:@"maple-harbor" to:@"otter-cedar"];
    SZFExpect([twice.previousID isEqualToString:@"maple-river"] && [twice.friendsID isEqualToString:@"otter-cedar"],
              @"twice: %@", twice);

    // The host already holds another ID for this key (a reinstall that kept it): adopt it without a notice.
    SZFriendsIDStatus *adopted = [status statusAfterReservationOf:@"otter-cedar"];
    SZFExpect(adopted.state == SZFriendsIDStateReserved && [adopted.friendsID isEqualToString:@"otter-cedar"] &&
                  adopted.previousID == nil, @"adopted: %@", adopted);

    // Three collisions in a row: three-word draws from then on, even after a reservation.
    SZFriendsIDStatus *crowded = [[[status statusAfterCollision] statusAfterCollision] statusAfterCollision];
    NSString *threeWords = [crowded replacementIDWithCodec:codec listNewIDWords:2 generator:Scripted(@[ @3 ], nil)];
    SZFExpect([threeWords componentsSeparatedByString:@"-"].count == 3, @"three words after three collisions");
    SZFriendsIDStatus *after = [crowded statusAfterRenameFrom:@"maple-river" to:threeWords];
    SZFExpect(after.collisionsInARow == 3, @"the count sticks at three: %@", after);
    SZFExpect([[after replacementIDWithCodec:codec listNewIDWords:2 generator:Scripted(@[ @4 ], nil)]
                  componentsSeparatedByString:@"-"].count == 3, @"still three words later");
    SZFriendsIDStatus *two = [[status statusAfterCollision] statusAfterCollision];
    SZFExpect([two statusAfterRenameFrom:@"maple-river" to:@"otter-cedar"].collisionsInARow == 0,
              @"two collisions then success starts the count again");
    SZFExpect([[status statusAfterCollision] statusAfterCollision].state == SZFriendsIDStateUnreserved,
              @"collisions alone (host unreachable after) leave the ID unreserved");

    // A store-loaded status: previousID exists only alongside Changed.
    SZFriendsIDStatus *stored = [[SZFriendsIDStatus alloc] initWithFriendsID:@"maple-river"
                                                                       state:SZFriendsIDStateReserved
                                                                  previousID:@"otter-cedar"
                                                            collisionsInARow:1];
    SZFExpect(stored.previousID == nil, @"no notice text without a notice");
    SZFExpect([stored isEqual:[stored copy]] && ![stored isEqual:reserved], @"equality");
}

int main(void) {
    @autoreleasepool {
        TestNormalisation();
        TestDraws();
        TestWordCount();
        TestStatus();
        return SZFFinish("SZFriendsIDTests");
    }
}
