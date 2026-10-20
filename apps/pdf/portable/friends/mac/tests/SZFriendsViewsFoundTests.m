// Shenzhen Friends views tests: how a nearby person was found (PROTOCOL.md found, capability nearby.found). Nearby rows
// and a nearby friend's list row draw one route icon per method and the helper's label before the subtitle; a row
// without `found` (not nearby, or an older helper) draws neither. The snapshots are written here as the spec gives them.

#import "SZFriendsViewsTestSupport.h"

static NSDictionary *SZFFound(NSArray *methods, NSString *label) {
    return @{@"methods" : methods, @"label" : label};
}

// Nearby with Kenji over the local network, Lena over Bluetooth and Mei over both.
NSDictionary *SZFTestFoundNearby(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"nearby-visible-bluetooth-off") mutableCopy];
    NSMutableArray *people = [NSMutableArray array];
    NSArray *found = @[
        SZFFound(@[ @"lan" ], @"Local network"), SZFFound(@[ @"bluetooth" ], @"Bluetooth"),
        SZFFound(@[ @"lan", @"bluetooth" ], @"Local network and Bluetooth")
    ];
    [data[@"people"] enumerateObjectsUsingBlock:^(NSDictionary *source, NSUInteger index, BOOL *stop) {
        (void)stop;
        NSMutableDictionary *person = [source mutableCopy];
        person[@"found"] = index < found.count ? found[index] : [NSNull null];
        [people addObject:person];
    }];
    data[@"people"] = people;
    return data;
}

// The list with Mei seen nearby over both, and everyone else not nearby (found null).
NSDictionary *SZFTestFoundList(void) {
    NSMutableDictionary *data = [SZFTestSnapshot(@"list") mutableCopy];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *source in data[@"rows"]) {
        NSMutableDictionary *row = [source mutableCopy];
        row[@"found"] = [row[@"conversation_id"] isEqual:@"c_mei"]
                            ? SZFFound(@[ @"lan", @"bluetooth" ], @"Local network and Bluetooth")
                            : (id)[NSNull null];
        [rows addObject:row];
    }
    data[@"rows"] = rows;
    return data;
}

// How many pixels of the route colour lie in `rect` of `view`'s rendering.
static NSUInteger SZFRoutePixels(NSView *view, NSRect rect, uint32_t route) {
    NSBitmapImageRep *rep = SZFTestBitmap(view);
    CGFloat scale = rep.pixelsWide / NSWidth(view.bounds);
    NSUInteger count = 0;
    for (CGFloat y = NSMinY(rect); y < NSMaxY(rect); y += 0.5)
        for (CGFloat x = NSMinX(rect); x < NSMaxX(rect); x += 0.5)
            if (SZFTestSameColor(SZFTestBitmapPixel(rep, (NSInteger)(x * scale), (NSInteger)(y * scale)), route, 40))
                count++;
    return count;
}

void SZFTestFoundRows(void) {
    SZFriendsContext *context = SZFTestContext([SZFTestHost new], SZFTestReadyLink(NULL));
    SZFriendsListPage *page = [[SZFriendsListPage alloc] initWithContext:context];
    NSWindow *window = SZFTestHostWindow(page, NSMakeSize(400, 640), NSAppearanceNameAqua);
    [page showNearby:YES];
    [page applyNearbySnapshot:SZFTestFoundNearby()];
    [window.contentView layoutSubtreeIfNeeded];
    NSArray<SZFriendsRowView *> *rows = page.nearbyPane.personRows;
    SZFExpect(rows.count >= 3, @"three people nearby: %lu", (unsigned long)rows.count);
    if (rows.count < 3) return;
    SZFExpect([rows[0].foundMethods isEqual:@[ @"lan" ]] && [rows[0].foundLabel isEqualToString:@"Local network"],
              @"Kenji: %@ %@", rows[0].foundMethods, rows[0].foundLabel);
    SZFExpect([rows[1].foundMethods isEqual:@[ @"bluetooth" ]] && [rows[1].foundLabel isEqualToString:@"Bluetooth"],
              @"Lena: %@ %@", rows[1].foundMethods, rows[1].foundLabel);
    SZFExpect([rows[2].foundMethods isEqual:(@[ @"lan", @"bluetooth" ])] &&
                  [rows[2].foundLabel isEqualToString:@"Local network and Bluetooth"],
              @"Mei: %@ %@", rows[2].foundMethods, rows[2].foundLabel);
    // The icons sit at the start of the second line, in the local route colour: one for Kenji, two for Mei.
    uint32_t route = SZFTestResolved(SZFriendsRouteColor(context.appearance, @"local"), NSAppearanceNameAqua);
    for (NSUInteger i = 0; i < 3; i++) {
        SZFriendsRowView *row = rows[i];
        CGFloat textX = 8 + 34 + 10, midY = NSMidY(row.bounds);
        NSUInteger first = SZFRoutePixels(row, NSMakeRect(textX, midY + 3, 11, 13), route);
        NSUInteger second = SZFRoutePixels(row, NSMakeRect(textX + 14, midY + 3, 11, 13), route);
        SZFExpect(first > 4, @"row %lu draws its first icon (%lu pixels)", (unsigned long)i, (unsigned long)first);
        SZFExpect(i == 2 ? second > 4 : second == 0, @"row %lu: a second icon only for both methods (%lu pixels)",
                  (unsigned long)i, (unsigned long)second);
    }

    // An unknown method draws no icon but keeps the label; no label, nothing at all.
    NSMutableDictionary *person = [SZFTestFoundNearby()[@"people"][0] mutableCopy];
    person[@"found"] = SZFFound(@[ @"carrier_pigeon", @"lan" ], @"Local network");
    [rows[0] configureWithNearbyPerson:person];
    SZFExpect([rows[0].foundMethods isEqual:@[ @"lan" ]], @"unknown methods dropped: %@", rows[0].foundMethods);
    person[@"found"] = SZFFound(@[ @"lan" ], @"");
    [rows[0] configureWithNearbyPerson:person];
    SZFExpect(rows[0].foundMethods.count == 0 && !rows[0].foundLabel.length, @"no label, no icons");
    [person removeObjectForKey:@"found"];
    [rows[0] configureWithNearbyPerson:person];
    SZFExpect(rows[0].foundMethods.count == 0 && !rows[0].foundLabel, @"an older helper: nothing");

    // The list: only Mei, seen nearby, says how.
    [page showNearby:NO];
    [page applySnapshot:SZFTestFoundList()];
    [window.contentView layoutSubtreeIfNeeded];
    for (SZFriendsRowView *row in page.rows) {
        BOOL mei = [row.conversationID isEqualToString:@"c_mei"];
        SZFExpect(mei ? [row.foundLabel isEqualToString:@"Local network and Bluetooth"] && row.foundMethods.count == 2
                      : row.foundLabel == nil && row.foundMethods.count == 0,
                  @"%@: %@", row.conversationID, row.foundLabel);
    }
    SZFExpect([[SZFriendsClientTransport capabilitiesForHost:[SZFTestHost new]] containsObject:@"nearby.found"],
              @"the views ask to be told how people were found");
}
