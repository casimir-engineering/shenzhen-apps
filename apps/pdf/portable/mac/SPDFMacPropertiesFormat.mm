#import "SPDFMacPropertiesFormat.h"

#include <ctype.h>
#include <math.h>

// Reads exactly two digits at s[*pos] into *value. Returns 0 when fewer than
// two digits remain (a lone trailing digit is a partial field).
static BOOL spdf_read_two_digits(const char* s, size_t len, size_t* pos, int* value) {
    if (*pos + 2 > len) return NO;
    if (!isdigit((unsigned char)s[*pos]) || !isdigit((unsigned char)s[*pos + 1])) return NO;
    *value = (s[*pos] - '0') * 10 + (s[*pos + 1] - '0');
    *pos += 2;
    return YES;
}

NSDate* spdf_properties_parse_pdf_date(NSString* raw) {
    NSString* trimmed =
        [raw ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([trimmed hasPrefix:@"D:"]) trimmed = [trimmed substringFromIndex:2];
    if (trimmed.length < 4) return nil;

    const char* s = trimmed.UTF8String;
    size_t len = strlen(s);
    size_t pos = 0;

    size_t digitCount = 0;
    while (digitCount < len && isdigit((unsigned char)s[digitCount])) ++digitCount;
    // Fields are fixed-width pairs after the 4-digit year; an odd digit count
    // means a partial field, and 15+ digits is not a date.
    if (digitCount < 4 || digitCount > 14 || (digitCount % 2) != 0) return nil;

    int year = 0;
    for (pos = 0; pos < 4; ++pos) year = year * 10 + (s[pos] - '0');
    if (year <= 0) return nil;

    int month = 1, day = 1, hour = 0, minute = 0, second = 0;
    if (pos < digitCount && !spdf_read_two_digits(s, len, &pos, &month)) return nil;
    if (pos < digitCount && !spdf_read_two_digits(s, len, &pos, &day)) return nil;
    if (pos < digitCount && !spdf_read_two_digits(s, len, &pos, &hour)) return nil;
    if (pos < digitCount && !spdf_read_two_digits(s, len, &pos, &minute)) return nil;
    if (pos < digitCount && !spdf_read_two_digits(s, len, &pos, &second)) return nil;
    if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return nil;

    // Optional offset: Z, or +/-HH with optional 'mm (apostrophes optional /
    // unbalanced in the wild). Missing offset = local time. A started-but-
    // malformed offset (e.g. "+8") invalidates the whole date.
    NSTimeZone* timeZone = nil;
    if (pos < len && (s[pos] == 'Z' || s[pos] == 'z')) {
        timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        ++pos;
        if (pos < len && s[pos] == '0') {  // tolerate Z00'00'
            int zh = 0, zm = 0;
            if (!spdf_read_two_digits(s, len, &pos, &zh) || zh != 0) return nil;
            if (pos < len && s[pos] == '\'') ++pos;
            if (pos < len && isdigit((unsigned char)s[pos])) {
                if (!spdf_read_two_digits(s, len, &pos, &zm) || zm != 0) return nil;
            }
        }
    } else if (pos < len && (s[pos] == '+' || s[pos] == '-')) {
        int sign = s[pos] == '-' ? -1 : 1;
        ++pos;
        int offsetHour = 0, offsetMinute = 0;
        if (!spdf_read_two_digits(s, len, &pos, &offsetHour) || offsetHour > 23) return nil;
        if (pos < len && s[pos] == '\'') ++pos;
        if (pos < len && isdigit((unsigned char)s[pos])) {
            if (!spdf_read_two_digits(s, len, &pos, &offsetMinute) || offsetMinute > 59) return nil;
        }
        timeZone = [NSTimeZone timeZoneForSecondsFromGMT:sign * (offsetHour * 3600 + offsetMinute * 60)];
    }
    if (!timeZone) timeZone = NSTimeZone.localTimeZone;

    NSCalendar* calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone;
    NSDateComponents* components = [[NSDateComponents alloc] init];
    components.year = year;
    components.month = month;
    components.day = day;
    components.hour = hour;
    components.minute = minute;
    components.second = second;
    NSDate* date = [calendar dateFromComponents:components];
    if (!date) return nil;

    // NSCalendar normalizes impossible dates (Feb 30 -> Mar 1); require a
    // round-trip match so those are rejected instead of silently shifted.
    NSDateComponents* check =
        [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay | NSCalendarUnitHour |
                             NSCalendarUnitMinute | NSCalendarUnitSecond
                    fromDate:date];
    if (check.year != year || check.month != month || check.day != day || check.hour != hour ||
        check.minute != minute || check.second != second)
        return nil;
    return date;
}

static NSString* spdf_grouped_number(unsigned long long value) {
    NSNumberFormatter* formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    formatter.groupingSeparator = @",";
    formatter.usesGroupingSeparator = YES;
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [formatter stringFromNumber:@(value)] ?: [NSString stringWithFormat:@"%llu", value];
}

static NSString* spdf_one_decimal(double value) {
    NSString* text = [NSString stringWithFormat:@"%.1f", value];
    if ([text hasSuffix:@".0"]) text = [text substringToIndex:text.length - 2];
    return text;
}

NSString* spdf_properties_format_file_size(unsigned long long bytes) {
    if (bytes == 1) return @"1 byte";
    if (bytes < 1000) return [NSString stringWithFormat:@"%llu bytes", bytes];
    static NSString* const units[] = {@"KB", @"MB", @"GB", @"TB", @"PB"};
    double value = (double)bytes / 1000.0;
    size_t unit = 0;
    while (value >= 1000.0 && unit + 1 < sizeof(units) / sizeof(units[0])) {
        value /= 1000.0;
        ++unit;
    }
    return [NSString
        stringWithFormat:@"%@ %@ (%@ bytes)", spdf_one_decimal(value), units[unit], spdf_grouped_number(bytes)];
}

NSString* spdf_properties_format_page_size_pt(CGFloat widthPt, CGFloat heightPt) {
    if (!isfinite(widthPt) || !isfinite(heightPt) || widthPt <= 0 || heightPt <= 0) return @"";
    double widthMm = widthPt * 25.4 / 72.0;
    double heightMm = heightPt * 25.4 / 72.0;
    double widthIn = widthPt / 72.0;
    double heightIn = heightPt / 72.0;
    return [NSString stringWithFormat:@"%.0f × %.0f mm · %.2f × %.2f in · %.0f × %.0f pt", widthMm, heightMm, widthIn,
                                      heightIn, (double)widthPt, (double)heightPt];
}

static NSString* spdf_denied_list(NSArray<NSString*>* denied) {
    if (denied.count == 0) return @"";
    if (denied.count == 1) return denied[0];
    NSArray<NSString*>* head = [denied subarrayWithRange:NSMakeRange(0, denied.count - 1)];
    return [NSString stringWithFormat:@"%@ and %@", [head componentsJoinedByString:@", "], denied.lastObject];
}

NSString* spdf_properties_security_summary(NSString* encryptionDetail,
                                           BOOL canPrint,
                                           BOOL canCopy,
                                           BOOL canEdit,
                                           BOOL canAnnotate) {
    NSString* trimmedDetail =
        [encryptionDetail ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* base =
        trimmedDetail.length ? [NSString stringWithFormat:@"Encrypted — %@", trimmedDetail] : @"Not encrypted";

    NSMutableArray<NSString*>* denied = [NSMutableArray array];
    if (!canPrint) [denied addObject:@"printing"];
    if (!canCopy) [denied addObject:@"copying"];
    if (!canEdit) [denied addObject:@"editing"];
    if (!canAnnotate) [denied addObject:@"annotating"];
    if (denied.count == 0) return base;
    return [NSString stringWithFormat:@"%@ · %@ not allowed", base, spdf_denied_list(denied)];
}

void spdf_properties_count_text(NSString* text, NSUInteger* words, NSUInteger* chars) {
    if (text.length == 0) return;
    __block NSUInteger wordCount = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString* substring, NSRange substringRange, NSRange enclosingRange,
                                       BOOL* stop) {
                            (void)substring;
                            (void)substringRange;
                            (void)enclosingRange;
                            (void)stop;
                            ++wordCount;
                          }];
    NSUInteger nonWhitespace = 0;
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < text.length; ++i) {
        if (![whitespace characterIsMember:[text characterAtIndex:i]]) ++nonWhitespace;
    }
    if (words) *words += wordCount;
    if (chars) *chars += nonWhitespace;
}
