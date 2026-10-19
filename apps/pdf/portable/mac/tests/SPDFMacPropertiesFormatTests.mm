#import <Foundation/Foundation.h>

#import "../SPDFMacPropertiesFormat.h"

static int gFailureCount = 0;

// Expected instant built in an explicit zone so the test is host-timezone
// independent (except the deliberate local-time cases, which compute their
// expectation with the local zone too).
static NSDate* date_in_zone(NSInteger year, NSInteger month, NSInteger day, NSInteger hour, NSInteger minute,
                            NSInteger second, NSTimeZone* zone) {
    NSCalendar* calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = zone;
    NSDateComponents* components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    components.second = second;
    return [calendar dateFromComponents:components];
}

static void expect_date(NSString* label, NSString* raw, NSDate* expected) {
    NSDate* actual = spdf_properties_parse_pdf_date(raw);
    BOOL matches = (actual == nil && expected == nil) ||
                   (actual && expected && fabs([actual timeIntervalSinceDate:expected]) < 0.5);
    if (!matches) {
        fprintf(stderr, "FAIL %s: input \"%s\" expected %s, got %s\n", label.UTF8String, raw.UTF8String,
                expected ? expected.description.UTF8String : "nil", actual ? actual.description.UTF8String : "nil");
        ++gFailureCount;
    }
}

static void expect_string(NSString* label, NSString* actual, NSString* expected) {
    if (![actual isEqualToString:expected]) {
        fprintf(stderr, "FAIL %s: expected \"%s\", got \"%s\"\n", label.UTF8String, expected.UTF8String,
                actual.UTF8String);
        ++gFailureCount;
    }
}

static void expect_counts(NSString* label, NSString* text, NSUInteger expectedWords, NSUInteger expectedChars) {
    NSUInteger words = 0, chars = 0;
    spdf_properties_count_text(text, &words, &chars);
    if (words != expectedWords || chars != expectedChars) {
        fprintf(stderr, "FAIL %s: expected %lu words / %lu chars, got %lu / %lu\n", label.UTF8String,
                (unsigned long)expectedWords, (unsigned long)expectedChars, (unsigned long)words,
                (unsigned long)chars);
        ++gFailureCount;
    }
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSTimeZone* utc = [NSTimeZone timeZoneForSecondsFromGMT:0];
        NSTimeZone* plus8 = [NSTimeZone timeZoneForSecondsFromGMT:8 * 3600];
        NSTimeZone* minus0530 = [NSTimeZone timeZoneForSecondsFromGMT:-(5 * 3600 + 30 * 60)];
        NSTimeZone* local = NSTimeZone.localTimeZone;

        // Full spec form with positive offset.
        expect_date(@"full +08'00'", @"D:20240131235959+08'00'", date_in_zone(2024, 1, 31, 23, 59, 59, plus8));
        // Negative offset with minutes.
        expect_date(@"negative -05'30'", @"D:19990704120000-05'30'", date_in_zone(1999, 7, 4, 12, 0, 0, minus0530));
        // UTC marker, bare and with the Acrobat-style Z00'00' tail.
        expect_date(@"zulu", @"D:20200229120000Z", date_in_zone(2020, 2, 29, 12, 0, 0, utc));
        expect_date(@"zulu with zeros", @"D:20200229120000Z00'00'", date_in_zone(2020, 2, 29, 12, 0, 0, utc));
        // Apostrophe variants: missing trailing, missing both.
        expect_date(@"offset no trailing quote", @"D:20240101000000+05'30",
                    date_in_zone(2024, 1, 1, 0, 0, 0, [NSTimeZone timeZoneForSecondsFromGMT:5 * 3600 + 30 * 60]));
        expect_date(@"offset no quotes", @"D:20240101000000+0800", date_in_zone(2024, 1, 1, 0, 0, 0, plus8));
        // Hour-only offset.
        expect_date(@"offset hour only", @"D:20240101000000+08", date_in_zone(2024, 1, 1, 0, 0, 0, plus8));
        // No offset = local time.
        expect_date(@"no offset is local", @"D:20231115093000", date_in_zone(2023, 11, 15, 9, 30, 0, local));
        // Progressive truncation: seconds, minutes, hours, day, month absent.
        expect_date(@"no seconds", @"D:202311150930", date_in_zone(2023, 11, 15, 9, 30, 0, local));
        expect_date(@"date only", @"D:20231115", date_in_zone(2023, 11, 15, 0, 0, 0, local));
        expect_date(@"year month", @"D:202311", date_in_zone(2023, 11, 1, 0, 0, 0, local));
        expect_date(@"year only", @"D:2023", date_in_zone(2023, 1, 1, 0, 0, 0, local));
        // Missing D: prefix.
        expect_date(@"no prefix", @"20231115093000Z", date_in_zone(2023, 11, 15, 9, 30, 0, utc));
        // Surrounding whitespace.
        expect_date(@"whitespace", @"  D:20231115  ", date_in_zone(2023, 11, 15, 0, 0, 0, local));
        // Trailing junk after a valid block is ignored.
        expect_date(@"trailing junk", @"D:20231115 draft", date_in_zone(2023, 11, 15, 0, 0, 0, local));

        // Rejections.
        expect_date(@"empty", @"", nil);
        expect_date(@"garbage", @"yesterday", nil);
        expect_date(@"short year", @"D:202", nil);
        expect_date(@"partial field", @"D:202401012", nil);  // odd digit count
        expect_date(@"month 13", @"D:20241301", nil);
        expect_date(@"day 32", @"D:20240132", nil);
        expect_date(@"feb 30 rolls over", @"D:20240230", nil);
        expect_date(@"feb 29 non leap", @"D:20230229", nil);
        expect_date(@"hour 24", @"D:2024010124", nil);
        expect_date(@"minute 61", @"D:202401011261", nil);
        expect_date(@"malformed offset", @"D:20240101000000+8", nil);
        expect_date(@"offset hour 25", @"D:20240101000000+25'00'", nil);
        expect_date(@"too many digits", @"D:2024010100000012", nil);

        expect_string(@"size 0", spdf_properties_format_file_size(0), @"0 bytes");
        expect_string(@"size 1", spdf_properties_format_file_size(1), @"1 byte");
        expect_string(@"size 614", spdf_properties_format_file_size(614), @"614 bytes");
        expect_string(@"size KB", spdf_properties_format_file_size(2048), @"2 KB (2,048 bytes)");
        expect_string(@"size MB", spdf_properties_format_file_size(2437120), @"2.4 MB (2,437,120 bytes)");
        expect_string(@"size GB", spdf_properties_format_file_size(5300000000ull), @"5.3 GB (5,300,000,000 bytes)");

        expect_string(@"page size A4", spdf_properties_format_page_size_pt(595.276, 841.89),
                      @"210 × 297 mm · 8.27 × 11.69 in · 595 × 842 pt");
        expect_string(@"page size letter", spdf_properties_format_page_size_pt(612, 792),
                      @"216 × 279 mm · 8.50 × 11.00 in · 612 × 792 pt");
        expect_string(@"page size invalid", spdf_properties_format_page_size_pt(0, 792), @"");

        expect_string(@"security none", spdf_properties_security_summary(@"", YES, YES, YES, YES), @"Not encrypted");
        expect_string(@"security encrypted all allowed",
                      spdf_properties_security_summary(@"Standard V4 R4 128-bit AES", YES, YES, YES, YES),
                      @"Encrypted — Standard V4 R4 128-bit AES");
        expect_string(@"security one denied",
                      spdf_properties_security_summary(@"Standard V2 R3 128-bit RC4", YES, NO, YES, YES),
                      @"Encrypted — Standard V2 R3 128-bit RC4 · copying not allowed");
        expect_string(@"security two denied",
                      spdf_properties_security_summary(@"AES", NO, NO, YES, YES),
                      @"Encrypted — AES · printing and copying not allowed");
        expect_string(@"security three denied",
                      spdf_properties_security_summary(@"AES", NO, NO, NO, YES),
                      @"Encrypted — AES · printing, copying and editing not allowed");

        expect_counts(@"count simple", @"Hello world", 2, 10);
        expect_counts(@"count punctuation", @"one, two; three!", 3, 14);
        expect_counts(@"count empty", @"", 0, 0);
        expect_counts(@"count whitespace only", @"  \n\t ", 0, 0);
    }
    if (gFailureCount > 0) return 1;
    printf("SPDFMacPropertiesFormatTests passed\n");
    return 0;
}
