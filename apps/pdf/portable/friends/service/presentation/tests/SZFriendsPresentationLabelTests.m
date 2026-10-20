// Label edge cases: times around midnight and across years in Hong Kong's clock, sizes at unit boundaries,
// estimates, countdowns, badges, routes, spoken fragments, names and every reply error message.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"

// A function rather than a macro: Objective-C array literals carry commas the preprocessor would split on.
static void ExpectText(NSString *got, NSString *expected) {
    SZPExpect([got isEqualToString:expected], @"gave \"%@\", expected \"%@\"", got, expected);
}

static SZFriendsStrings *Strings(NSString *timeZone, NSString *locale) {
    SZFriendsAudience *audience = SZPAudience();
    if (timeZone) audience.timeZone = [NSTimeZone timeZoneWithName:timeZone];
    if (locale) audience.locale = locale;
    return [[SZFriendsStrings alloc] initWithAudience:audience];
}

static NSDate *UTC(NSString *iso) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    return [formatter dateFromString:iso];
}

static void TestTimes(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    NSDate *now = SZPNow(); // Monday 12 October 2026, 14:47:48 in Hong Kong
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-12 00:05") now:now], @"00:05");
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-11 23:59") now:now], @"Yesterday");
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-10 09:00") now:now], @"Saturday");
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-06 09:00") now:now], @"Tuesday");
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-05 09:00") now:now], @"5 Oct"); // seven days: a date
    ExpectText([s timeLabelForDate:SZPHongKong(@"2025-12-31 23:00") now:now], @"31 Dec 2025");
    ExpectText([s timeLabelForDate:SZPHongKong(@"2026-10-13 09:00") now:now], @"13 Oct"); // a skewed clock ahead
    // 16:30 UTC on the 11th is 00:30 on the 12th in Hong Kong: today there, yesterday in UTC.
    ExpectText([s timeLabelForDate:UTC(@"2026-10-11T16:30:00Z") now:now], @"00:30");
    ExpectText([Strings(@"UTC", nil) timeLabelForDate:UTC(@"2026-10-11T16:30:00Z") now:now], @"Yesterday");
    ExpectText([s dayItemIDForDate:UTC(@"2026-10-11T16:30:00Z")], @"d_20261012");

    ExpectText([s timeAccessibilityLabelForDate:SZPHongKong(@"2026-10-12 14:40") now:now], @"14:40");
    ExpectText([s timeAccessibilityLabelForDate:SZPHongKong(@"2026-10-11 09:00") now:now], @"yesterday");
    ExpectText([s timeAccessibilityLabelForDate:SZPHongKong(@"2026-10-03 09:00") now:now], @"3 October");
    ExpectText([s timeAccessibilityLabelForDate:SZPHongKong(@"2025-12-31 09:00") now:now], @"31 December 2025");
    ExpectText([s dayLabelForDate:SZPHongKong(@"2026-10-12 01:00") now:now], @"Today");
    ExpectText([s dayAccessibilityLabelForDate:SZPHongKong(@"2026-09-30 01:00") now:now], @"30 September");
    ExpectText([s momentPhraseForDate:SZPHongKong(@"2026-10-12 14:40") now:now], @"today at 14:40");
    ExpectText([s momentPhraseForDate:SZPHongKong(@"2026-10-11 09:05") now:now], @"yesterday at 09:05");
    ExpectText([s momentPhraseForDate:SZPHongKong(@"2026-10-10 10:00") now:now], @"Saturday at 10:00");
    ExpectText([s momentPhraseForDate:SZPHongKong(@"2026-10-02 08:00") now:now], @"2 Oct at 08:00");
    ExpectText([s momentAccessibilityPhraseForDate:SZPHongKong(@"2026-10-02 16:20") now:now], @"2 October at 16:20");
    ExpectText([s dayPhraseForDate:SZPHongKong(@"2026-10-12 08:00") now:now], @"today");
    ExpectText([s dayPhraseForDate:SZPHongKong(@"2026-10-10 08:00") now:now], @"on Saturday");
    ExpectText([s dayPhraseForDate:SZPHongKong(@"2026-10-03 08:00") now:now], @"on 3 Oct");
}

static void TestSizesAndDurations(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    NSArray *sizes = @[
        @[ @0, @"0 bytes" ], @[ @1, @"1 byte" ], @[ @999, @"999 bytes" ], @[ @1000, @"1 KB" ], @[ @1499, @"1 KB" ],
        @[ @999499, @"999 KB" ], @[ @999500, @"1 MB" ], @[ @2000000, @"2 MB" ], @[ @2431029, @"2.4 MB" ],
        @[ @18604277, @"18.6 MB" ], @[ @99940000, @"99.9 MB" ], @[ @99960000, @"100 MB" ], @[ @120000000, @"120 MB" ],
        @[ @999600000, @"1 GB" ], @[ @1210000000, @"1.2 GB" ], @[ @5000000000000, @"5 TB" ],
        @[ @5000000000000000, @"5000 TB" ]
    ];
    for (NSArray *pair in sizes) ExpectText([s sizeLabelForBytes:[pair[0] unsignedLongLongValue]], pair[1]);

    NSArray *durations = @[
        @[ @0, @"about 5 s", @"about 5 seconds" ], @[ @20.2, @"about 20 s", @"about 20 seconds" ],
        @[ @57, @"about 55 s", @"about 55 seconds" ], @[ @58, @"about 1 min", @"about 1 minute" ],
        @[ @361.7, @"about 6 min", @"about 6 minutes" ], @[ @3599, @"about 1 h", @"about 1 hour" ],
        @[ @4800, @"about 1 h 20 min", @"about 1 hour 20 minutes" ], @[ @7200, @"about 2 h", @"about 2 hours" ]
    ];
    for (NSArray *row in durations) {
        ExpectText([s durationLabelForSeconds:[row[0] doubleValue]], row[1]);
        ExpectText([s durationAccessibilityLabelForSeconds:[row[0] doubleValue]], row[2]);
    }
    ExpectText([s countdownLabelForRemaining:252], @"4:12");
    ExpectText([s countdownAccessibilityLabelForRemaining:252], @"4 minutes 12 seconds left");
    ExpectText([s countdownLabelForRemaining:251.2], @"4:12"); // rounds up: never shows 0:00 while still visible
    ExpectText([s countdownAccessibilityLabelForRemaining:60], @"1 minute left");
    ExpectText([s countdownAccessibilityLabelForRemaining:61], @"1 minute 1 second left");
    ExpectText([s countdownLabelForRemaining:1], @"0:01");
    ExpectText([s countdownAccessibilityLabelForRemaining:1], @"1 second left");
    ExpectText([s countdownLabelForRemaining:-5], @"0:00");

    SZPExpect([s transferEstimateForRemainingBytes:42318806 bytesPerSecond:117000 route:SZFriendsRouteMethodLAN] == nil,
              @"no estimate on a fast route");
    SZPExpect([s transferEstimateForRemainingBytes:1 bytesPerSecond:1 route:SZFriendsRouteMethodPeerToPeerWiFi] == nil,
              @"no estimate over direct Wi-Fi");
    ExpectText([s transferEstimateForRemainingBytes:42318806 bytesPerSecond:117000 route:SZFriendsRouteMethodBluetooth],
               @"Over Bluetooth, about 6 min");
    ExpectText([s transferEstimateForRemainingBytes:42318806 bytesPerSecond:0 route:SZFriendsRouteMethodBluetooth],
               @"Over Bluetooth");
    ExpectText([s transferEstimateForRemainingBytes:18000000 bytesPerSecond:100000 route:SZFriendsRouteMethodRelay],
               @"Through the Friends relay, about 3 min");
    ExpectText([s transferEstimateAccessibilityForRemainingBytes:18000000 bytesPerSecond:100000
                                                           route:SZFriendsRouteMethodRelay],
               @"through the Friends relay, about 3 minutes");
}

static void TestSmallWords(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    ExpectText([s badgeLabelForCount:0], @"");
    ExpectText([s badgeLabelForCount:1], @"1");
    ExpectText([s badgeLabelForCount:99], @"99");
    ExpectText([s badgeLabelForCount:100], @"99+");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindLocal method:SZFriendsRouteMethodLAN],
               @"Nearby, on your network");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindLocal method:SZFriendsRouteMethodPeerToPeerWiFi],
               @"Nearby, over direct Wi-Fi");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindLocal method:SZFriendsRouteMethodBluetooth],
               @"Nearby, over Bluetooth");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindLocal method:SZFriendsRouteMethodNone], @"Nearby");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindOnline method:SZFriendsRouteMethodInternet], @"Online, direct");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindOnline method:SZFriendsRouteMethodNone], @"Online");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindOnline method:SZFriendsRouteMethodRelay],
               @"Online, through the Friends relay");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindOffline method:SZFriendsRouteMethodNone],
               @"Not nearby right now");
    ExpectText([s routeLabelForKind:SZFriendsRouteKindNone method:SZFriendsRouteMethodNone], @"");

    ExpectText([s spokenFragment:@"Nearby, over direct Wi-Fi"], @"nearby, over direct Wi-Fi");
    ExpectText([s spokenFragment:@"ID cottage-violet"], @"ID cottage-violet");
    ExpectText([s spokenFragment:@"PDF"], @"PDF");
    ExpectText([Strings(nil, @"zh-Hans") spokenFragment:@"Nearby"], @"Nearby"); // no case outside English
    ExpectText([s firstNameForName:@"Mei Lin" friendsID:@"jasmine-street"], @"Mei");
    ExpectText([s firstNameForName:@"  Tomás  Rivera " friendsID:nil], @"Tomás");
    ExpectText([s firstNameForName:@"李美" friendsID:nil], @"李美");
    ExpectText([s firstNameForName:@"   " friendsID:@"tulip-canyon"], @"tulip\u2011canyon"); // never split
    ExpectText([s displayID:@"tulip-canyon"], @"tulip\u2011canyon");
    ExpectText([s displayID:@"cedar-amber-falcon"], @"cedar\u2011amber\u2011falcon");
    ExpectText([s displayID:nil], @"");
    ExpectText([s firstNameForName:nil friendsID:nil], @"Someone");
    ExpectText([s joinedList:@[]], @"");
    ExpectText([s joinedList:@[ @"A" ]], @"A");
    ExpectText([s joinedList:@[ @"A", @"B" ]], @"A and B");
    ExpectText([s joinedList:@[ @"A", @"B", @"C" ]], @"A, B and C");
    ExpectText([s kindLabelForFileName:@"a.pdf" extension:nil], @"PDF");
    ExpectText([s kindLabelForFileName:@"notes.MD" extension:nil], @"Markdown");
    ExpectText([s kindLabelForFileName:@"x.weird" extension:nil], @"WEIRD");
    ExpectText([s kindLabelForFileName:@"noextension" extension:nil], @"File");
    ExpectText([s groupedComparisonCode:@"418270"], @"418 270");
    ExpectText([s spokenComparisonCode:@"418270"], @"Comparison code 4 1 8, 2 7 0");
    ExpectText([s groupedComparisonCode:@"12345"], @"12345");

    NSDictionary *strings = s.staticStrings;
    SZPExpect(strings.count == 37, @"37 static strings, got %lu", (unsigned long)strings.count);
    // The views fill only the four drag strings and the link warning, and hosts the queued note, each with exactly
    // the placeholders PROTOCOL.md § Static strings names; {apps} reaches nobody unfilled.
    NSDictionary<NSString *, NSArray<NSString *> *> *filled = @{
        @"drop_send_many" : @[ @"{count}" ],
        @"drop_send_file" : @[ @"{name}" ],
        @"drop_send_file_and_more" : @[ @"{name}", @"{count}" ],
        @"link_elsewhere" : @[ @"{host}", @"{shown}" ],
        @"queued_note" : @[ @"{first}" ],
        @"name_saved" : @[ @"{name}" ],
    };
    // Integration review, wave 6b: GTK refused links and special files while dragging but had no words to show.
    ExpectText(strings[@"drop_not_a_file"], @"Links and special files can’t be sent. Drop the original file instead.");
    ExpectText(strings[@"link_open"], @"Open in Browser");
    // Friends is a beta: the dropdown's tag, the button's tooltip and the first-run line say so in every app.
    ExpectText(strings[@"beta"], @"Beta");
    ExpectText(strings[@"button_tooltip"], @"Friends (Beta)");
    ExpectText(strings[@"beta_note"], @"Friends is in beta, so things may still change.");
    ExpectText(strings[@"link_open_email"], @"New Email");
    ExpectText(strings[@"link_elsewhere"], @"Goes to {host}, not {shown}");
    // Either app open on each Mac sends it, so the note names the apps that run Friends, not the reading app.
    SZFriendsAudience *files = SZPAudience();
    files.appName = @"Shenzhen Files";
    NSDictionary *seenInFiles = [[SZFriendsStrings alloc] initWithAudience:files].staticStrings;
    ExpectText(seenInFiles[@"queued_note"],
               @"Messages and files send when {first} is nearby with ShenzhenPDF, Shenzhen Files or Shenzhen 3D open.");
    for (NSString *key in strings) {
        NSString *rest = strings[key];
        for (NSString *placeholder in filled[key]) {
            SZPExpect([rest containsString:placeholder], @"static %@ lacks %@", key, placeholder);
            rest = [rest stringByReplacingOccurrencesOfString:placeholder withString:@""];
        }
        SZPExpect(![rest containsString:@"{"], @"static %@ has a placeholder the views do not fill", key);
    }
}

static void TestErrorMessages(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    NSArray<NSString *> *silent = @[ @"bad_frame", @"frame_too_large", @"hello_required", @"protocol_unsupported",
                                     @"unknown_intent", @"too_many_subscriptions", @"not_ready", @"connection_lost" ];
    NSArray<NSString *> *spoken = @[
        @"not_found", @"not_allowed", @"rate_limited", @"identity_unavailable", @"name_invalid", @"id_invalid",
        @"id_is_yours", @"already_friends", @"blocked", @"not_friends", @"file_missing", @"folder_not_supported",
        @"too_many_files", @"source_changed", @"disk_full", @"picture_invalid", @"scope_invalid", @"stale", @"internal"
    ];
    for (NSString *code in silent) SZPExpect([s messageForErrorCode:code details:@{}] == nil, @"%@ is silent", code);
    NSDictionary *details = @{@"path" : @"/Users/raph/Desktop/Report.pdf", @"name" : @"Mei Lin", @"max" : @100,
                              @"retry_after_seconds" : @30, @"needed_bytes" : @5000000};
    for (NSString *code in spoken) {
        for (NSDictionary *d in @[ @{}, details ]) {
            NSString *message = [s messageForErrorCode:code details:d];
            SZPExpect(message.length > 0 && ![message containsString:@"{"], @"%@ message: %@", code, message);
        }
    }
    ExpectText([s messageForErrorCode:@"folder_not_supported" details:details], @"Folders can’t be sent yet.");
    ExpectText([s messageForErrorCode:@"rate_limited" details:details], @"Too many at once. Try again in 30 seconds.");
    ExpectText([s messageForErrorCode:@"too_many_files" details:details],
               @"You can send up to 100 files at once. Nothing was sent.");
    ExpectText([s messageForErrorCode:@"file_missing" details:details],
               @"Report.pdf can’t be found or opened. Nothing was sent.");
    ExpectText([s messageForErrorCode:@"disk_full" details:details],
               @"There isn’t enough space on this computer to send Report.pdf. Free up some space, then try again.");
    ExpectText([s messageForErrorCode:@"already_friends" details:details], @"Mei Lin is already your friend.");
    ExpectText([s messageForErrorCode:@"invalid_field" details:@{@"field" : @"text"}],
               @"This message is too long. Split it into shorter messages.");
    SZPExpect([s messageForErrorCode:@"invalid_field" details:@{@"field" : @"subscription"}] == nil,
              @"a view’s own bad field gets no text");
    ExpectText([s messageForErrorCode:@"a_code_from_the_future" details:@{}],
               @"Something went wrong in Friends. Try again.");
}

static void TestCatalogLookup(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    ExpectText([s text:@"test.no_such_key"], @"test.no_such_key"); // shown as itself, and recorded
    SZPExpect([SZFriendsMissingCatalogKeys() containsObject:@"test.no_such_key"], @"missing key recorded");
    ExpectText([s text:@"id.label" values:@{@"id" : @"a-b"}], @"ID a-b");
    ExpectText([s text:@"size.bytes" count:1 values:nil], @"1 byte");
    ExpectText([s text:@"size.bytes" count:2 values:nil], @"2 bytes");
}

// A friend may have any app that runs Friends open, Shenzhen 3D among them, so a string that says which apps names
// them through {apps}, never by hand: a list written into one string falls behind when another app starts hosting.
static void TestAppsWithFriends(void) {
    SZFriendsStrings *s = Strings(nil, nil);
    NSString *apps = [s text:@"apps.with_friends"];
    ExpectText(apps, @"ShenzhenPDF, Shenzhen Files or Shenzhen 3D");
    NSDictionary<NSString *, NSString *> *catalog = SZFriendsEnglishCatalog();
    for (NSString *key in catalog) {
        if ([key isEqual:@"apps.with_friends"]) continue;
        for (NSString *name in @[ @"ShenzhenPDF", @"Shenzhen Files", @"Shenzhen 3D" ]) {
            SZPExpect(![catalog[key] containsString:name], @"%@ names %@ itself instead of saying {apps}", key, name);
        }
    }
    // Filled without the caller passing it, wherever a string says it.
    ExpectText([s text:@"join.waiting.message" values:@{@"id" : @"cottage-violet"}],
               @"On a computer that uses cottage-violet, open Friends in ShenzhenPDF, Shenzhen Files or Shenzhen 3D "
               @"and choose Approve. Then type the code it shows.");
    ExpectText([s text:@"join.not_reached"], @"Your other computer didn’t answer. Open ShenzhenPDF, Shenzhen Files or "
                                             @"Shenzhen 3D there, and type the code again.");
    ExpectText([s text:@"error.link_offline"], @"The computer this file comes from isn’t online right now. It can send "
                                               @"the file while ShenzhenPDF, Shenzhen Files or Shenzhen 3D is open "
                                               @"there.");
    ExpectText([s text:@"link.made" values:@{@"date" : @"19 October"}],
               @"Download link copied. It works until 19 October, whenever this computer is on with ShenzhenPDF, "
               @"Shenzhen Files or Shenzhen 3D open.");
}

void SZPRunLabelTests(void) {
    TestTimes();
    TestSizesAndDurations();
    TestSmallWords();
    TestErrorMessages();
    TestCatalogLookup();
    TestAppsWithFriends();
}
