#import <AppKit/AppKit.h>

#import "SPDFUpdater.h"
#import "SPDFUpdaterDownloadBounds.h"

static int gFailureCount = 0;

static const char* order_name(NSComparisonResult r) {
    switch (r) {
        case NSOrderedAscending: return "Ascending";
        case NSOrderedSame: return "Same";
        case NSOrderedDescending: return "Descending";
    }
    return "?";
}

static void expect(NSString* label, NSComparisonResult actual, NSComparisonResult expected) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %s, got %s\n", label.UTF8String, order_name(expected),
                order_name(actual));
        ++gFailureCount;
    }
}

static void expectString(NSString* label, NSString* actual, NSString* expected) {
    if (![actual isEqualToString:expected]) {
        fprintf(stderr, "FAIL %s:\n  expected: %s\n  got:      %s\n", label.UTF8String,
                expected.UTF8String, actual.UTF8String);
        ++gFailureCount;
    }
}

static void expectDelay(NSString* label, NSTimeInterval actual, NSTimeInterval expected) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %.1f, got %.1f\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

static void expectLL(NSString* label, long long actual, long long expected) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %lld, got %lld\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

static void expectBool(NSString* label, BOOL actual, BOOL expected) {
    if (actual != expected) {
        fprintf(stderr, "FAIL %s: expected %d, got %d\n", label.UTF8String, expected, actual);
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // 1. 26.6.25 > 26.6.4 (non-padded day; lexical would be wrong)
        expect(@"non-padded day", spdf_compare_versions(@"26.6.25", @"26.6.4"), NSOrderedDescending);

        // 2. 26.6.11 > 26.6.4 (multi-digit day)
        expect(@"multi-digit day", spdf_compare_versions(@"26.6.11", @"26.6.4"), NSOrderedDescending);

        // 3. 26.6.19-3 > 26.6.19-1 (build tiebreaker)
        expect(@"build tiebreaker", spdf_compare_versions(@"26.6.19-3", @"26.6.19-1"), NSOrderedDescending);

        // 4. 26.6.25-1 == 26.6.25-1 (no update)
        expect(@"equality", spdf_compare_versions(@"26.6.25-1", @"26.6.25-1"), NSOrderedSame);

        // 5. malformed input -> ordered-same / no update
        expect(@"malformed", spdf_compare_versions(@"not-a-version", @"26.6.25-1"), NSOrderedSame);

        // 6. downgrade feed: tag < highestVersionSeen -> no update, even when tag > running.
        //    running = 26.6.4, highestVersionSeen = 26.6.25, feed tag = 26.6.19.
        NSString* running = @"26.6.4-1";
        NSString* highestSeen = @"26.6.25-1";
        NSString* feedTag = @"26.6.19-3";
        BOOL isNewerThanRunning = (spdf_compare_versions(feedTag, running) == NSOrderedDescending);
        BOOL isDowngradeVsHighWater = (spdf_compare_versions(feedTag, highestSeen) == NSOrderedAscending);
        BOOL updateOffered = isNewerThanRunning && !isDowngradeVsHighWater;
        if (!(isNewerThanRunning && isDowngradeVsHighWater && !updateOffered)) {
            fprintf(stderr, "FAIL downgrade feed: newer=%d downgrade=%d offered=%d\n", isNewerThanRunning,
                    isDowngradeVsHighWater, updateOffered);
            ++gFailureCount;
        }

        // 7. Alert notes: bullets become "• " lines, breaks preserved, details
        //    below the first horizontal rule dropped.
        NSString* notes = spdf_format_release_notes_for_alert(
            @"- First **bold** highlight\n- Second `code` highlight\n\n---\n\n### Details\n- hidden detail\n");
        expectString(@"bullet formatting", notes, @"• First bold highlight\n• Second code highlight");

        // 8. Hard-wrapped continuation lines rejoin their bullet; blank runs collapse.
        notes = spdf_format_release_notes_for_alert(@"- A very long line\n  that was hard-wrapped\n\n\n- Next\n***\n- gone");
        expectString(@"continuation join", notes, @"• A very long line that was hard-wrapped\n• Next");

        // 9. Headers/quotes stripped; bidi override removed; newline kept.
        notes = spdf_format_release_notes_for_alert(@"## Heads up\n> quoted\nplain \u202Etricky");
        expectString(@"markdown + bidi strip", notes, @"Heads up\nquoted\nplain tricky");

        // 10. Over-cap bodies cut on a line boundary with an ellipsis line.
        NSMutableString* longBody = [NSMutableString string];
        for (int i = 0; i < 40; i++) [longBody appendFormat:@"- highlight number %d padded out\n", i];
        notes = spdf_format_release_notes_for_alert(longBody);
        if (notes.length > 502 || ![notes hasSuffix:@"\n…"] || [notes rangeOfString:@"…"].location != notes.length - 1) {
            fprintf(stderr, "FAIL line-boundary cap: len=%lu tail=%s\n", (unsigned long)notes.length,
                    [notes substringFromIndex:notes.length - MIN(notes.length, (NSUInteger)20)].UTF8String);
            ++gFailureCount;
        }

        // 11. nil / empty input.
        expectString(@"nil body", spdf_format_release_notes_for_alert(nil), @"");

        // --- spdf_daily_check_delay: pure fire/delay decision consumed under
        //     update.lock by every trigger (launch, hourly timer, day-change,
        //     wake). 0 = due now, >0 = seconds until the gate opens, -1 = never.
        NSTimeInterval now = 1800000000.0;  // arbitrary epoch instant

        // 12. Fresh install: no lastUpdateCheck stamp yet -> due immediately.
        expectDelay(@"fresh install due now", spdf_daily_check_delay(YES, NO, 0, now), 0);

        // 13. Checked recently (2h ago) -> gated for the remaining 22h.
        expectDelay(@"checked recently gated", spdf_daily_check_delay(YES, YES, now - 7200, now),
                    86400 - 7200);

        // 14. Long sleep past the gate (last check 30h ago) -> the wake catch-up
        //     trigger must fire the check immediately.
        expectDelay(@"long sleep past gate", spdf_daily_check_delay(YES, YES, now - 30 * 3600, now), 0);

        // 15. Day changed while asleep but only 40min since the last check: the
        //     rolling 24h gate stays closed (calendar-day triggers don't defeat it).
        expectDelay(@"day change inside window", spdf_daily_check_delay(YES, YES, now - 2400, now),
                    86400 - 2400);

        // 16. autoUpdate disabled -> never fires, even when long overdue.
        expectDelay(@"autoUpdate disabled", spdf_daily_check_delay(NO, YES, now - 30 * 3600, now), -1);

        // 17-21. The extracted bundle must match the complete release tag,
        // including the same-day build suffix. Missing/malformed values fail closed.
        expectBool(@"exact bundle tag", spdf_release_tag_matches_bundle_version(@"26.8.27-2", @"26.8.27", @"2"), YES);
        expectBool(@"same-day wrong build", spdf_release_tag_matches_bundle_version(@"26.8.27-2", @"26.8.27", @"1"), NO);
        expectBool(@"wrong date", spdf_release_tag_matches_bundle_version(@"26.8.27-2", @"26.8.26", @"2"), NO);
        expectBool(@"missing build", spdf_release_tag_matches_bundle_version(@"26.8.27-2", @"26.8.27", @""), NO);
        expectBool(@"malformed bundle tag", spdf_release_tag_matches_bundle_version(@"26.8.27-2", @"26.8.x", @"2"), NO);

        // 22-26. Relaunch health requires the complete date and build.
        expectBool(@"health exact tag", spdf_release_tag_matches_running_version(@"26.8.27-2", @"26.8.27-2"), YES);
        expectBool(@"health wrong build", spdf_release_tag_matches_running_version(@"26.8.27-2", @"26.8.27-1"), NO);
        expectBool(@"health missing build", spdf_release_tag_matches_running_version(@"26.8.27-2", @"26.8.27"), NO);
        expectBool(@"health wrong date", spdf_release_tag_matches_running_version(@"26.8.27-2", @"26.8.26-2"), NO);
        expectBool(@"health malformed", spdf_release_tag_matches_running_version(@"26.8.27-2", @"broken"), NO);

        // 27. The preview harness and production prompt share this exact alert
        // constructor, including release-note formatting and button order. The
        // notes render in an attributed accessory label so emphasis survives.
        NSAlert* alert = spdf_make_update_available_alert(@"26.8.27-2", @"26.7.17-1", @"- **Fast** update\n---\nHidden");
        expectString(@"alert title", alert.messageText, @"A new version of Shenzhen PDF is available");
        expectBool(@"alert sentence kept", [alert.informativeText containsString:@"Would you like to install"], YES);
        // The complete body stays in informativeText (keeps NSAlert's roomy
        // legacy layout and is the fallback when the attributed seam is gone).
        expectBool(@"alert formatted notes", [alert.informativeText containsString:@"• Fast update"], YES);
        expectBool(@"alert hides post-rule details", [alert.informativeText containsString:@"Hidden"], NO);
        @try {
            NSAttributedString* attributedBody = [alert valueForKey:@"attributedInformativeText"];
            NSRange fast = [attributedBody.string rangeOfString:@"Fast"];
            NSFont* fastFont = fast.location == NSNotFound
                                   ? nil
                                   : [attributedBody attribute:NSFontAttributeName atIndex:fast.location
                                                effectiveRange:NULL];
            expectBool(@"alert attributed bold notes",
                       fastFont && ([NSFontManager.sharedFontManager traitsOfFont:fastFont] & NSBoldFontMask) != 0,
                       YES);
        } @catch (NSException* exception) {
            // The seam is optional: without it the plain informativeText above
            // is the entire contract.
        }
        // No accessory view: it would flip NSAlert into the narrow stacked
        // style; long informative text keeps the wide horizontal layout.
        expectBool(@"alert has no accessory", alert.accessoryView == nil, YES);
        expectString(@"alert primary action", alert.buttons.firstObject.title, @"Install and Relaunch");

        // 28. Attributed notes: **spans** become bold runs, markers never leak,
        // sanitation matches the plain formatter, unbalanced markers stay plain.
        NSAttributedString* attributed =
            spdf_attributed_release_notes_for_alert(@"- **Markdown support**: GitHub-grade formatting\n- Plain line",
                                                    12.0);
        expectString(@"attributed text", attributed.string,
                     @"• Markdown support: GitHub-grade formatting\n• Plain line");
        NSRange boldSpan = [attributed.string rangeOfString:@"Markdown support"];
        NSFont* boldFont = [attributed attribute:NSFontAttributeName atIndex:boldSpan.location effectiveRange:NULL];
        NSFont* plainFont = [attributed attribute:NSFontAttributeName
                                          atIndex:[attributed.string rangeOfString:@"GitHub"].location
                                   effectiveRange:NULL];
        expectBool(@"attributed bold run",
                   ([NSFontManager.sharedFontManager traitsOfFont:boldFont] & NSBoldFontMask) != 0, YES);
        expectBool(@"attributed plain run",
                   ([NSFontManager.sharedFontManager traitsOfFont:plainFont] & NSBoldFontMask) == 0, YES);
        expectString(@"attributed unbalanced marker",
                     spdf_attributed_release_notes_for_alert(@"tail **unclosed", 12.0).string, @"tail unclosed");
        expectString(@"attributed empty body", spdf_attributed_release_notes_for_alert(nil, 12.0).string, @"");

        // 29. Download ceiling: an absent asset.size falls back to the 64MB hard
        // max, a declared size gets exactly one byte of slack, and a size at or
        // above the max is capped there.
        const long long kMax = kSPDFMaxDownloadBytes;
        expectLL(@"ceiling without declared size", spdf_download_ceiling(0), kMax);
        expectLL(@"ceiling with negative size", spdf_download_ceiling(-1), kMax);
        expectLL(@"ceiling with declared size", spdf_download_ceiling(33LL * 1024 * 1024),
                 33LL * 1024 * 1024 + 1);
        expectLL(@"ceiling capped at max", spdf_download_ceiling(kMax * 4), kMax);

        // 30. A hostile or corrupt asset.size must not overflow the bound. The
        // pre-clamp form (size + 1) was undefined behaviour at LLONG_MAX and
        // could yield a negative ceiling that cancels every download.
        expectLL(@"ceiling at LLONG_MAX", spdf_download_ceiling(LLONG_MAX), kMax);
        expectBool(@"ceiling stays positive", spdf_download_ceiling(LLONG_MAX) > 0, YES);
        expectBool(@"LLONG_MAX still admits a real download",
                   spdf_download_must_cancel(33LL * 1024 * 1024, -1, LLONG_MAX), NO);

        // 31. Cancel decision: exactly the declared size passes, the first byte
        // beyond it trips, the written-bytes bound still applies to a chunked
        // response (declared length -1), and an up-front oversized declaration
        // is rejected before the bytes arrive.
        expectBool(@"exact declared size passes", spdf_download_must_cancel(1000, 1000, 1000), NO);
        expectBool(@"one byte over trips", spdf_download_must_cancel(1002, 1000, 1000), YES);
        expectBool(@"chunked response stays bounded", spdf_download_must_cancel(kMax + 1, -1, 0), YES);
        expectBool(@"chunked response under the max passes",
                   spdf_download_must_cancel(kMax - 1, -1, 0), NO);
        expectBool(@"oversized declared length rejected",
                   spdf_download_must_cancel(0, kMax + 1, 0), YES);

        // 32. Free-space precheck: unknown inputs must never block an update,
        // ~3x headroom is required when both are known, and LLONG_MAX must not
        // overflow the multiply into a spurious pass.
        expectBool(@"absent size does not block", spdf_has_free_space_for_asset(1024, 0), YES);
        expectBool(@"unreadable volume does not block",
                   spdf_has_free_space_for_asset(0, 33LL * 1024 * 1024), YES);
        expectBool(@"ample space passes", spdf_has_free_space_for_asset(1024LL * 1024 * 1024,
                                                                        33LL * 1024 * 1024), YES);
        expectBool(@"tight space fails", spdf_has_free_space_for_asset(40LL * 1024 * 1024,
                                                                       33LL * 1024 * 1024), NO);
        expectBool(@"LLONG_MAX size does not overflow the headroom multiply",
                   spdf_has_free_space_for_asset(1024, LLONG_MAX), NO);
    }
    if (gFailureCount > 0) {
        fprintf(stderr, "SPDFUpdaterTests: %d failure(s)\n", gFailureCount);
        return 1;
    }
    printf("SPDFUpdaterTests passed (32 cases)\n");
    return 0;
}
