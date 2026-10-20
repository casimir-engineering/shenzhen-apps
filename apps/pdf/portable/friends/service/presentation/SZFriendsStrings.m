// Shenzhen Friends strings: catalog lookup and the formatting every view needs (times, sizes, durations, routes).
//
// All wording comes from the catalog (SZFriendsCatalog.m); this file only decides which entry applies and fills
// it. Dates are computed in the audience's time zone with a Gregorian calendar and spelled from catalog month and
// weekday names, never from NSDateFormatter, so output does not depend on the Mac's region settings and the
// golden fixtures reproduce on any machine.

#import "service/presentation/SZFriendsPresentationPrivate.h"

static NSMutableSet<NSString *> *MissingKeys(void) {
    static NSMutableSet<NSString *> *missing;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      missing = [NSMutableSet set];
    });
    return missing;
}

NSSet<NSString *> *SZFriendsMissingCatalogKeys(void) {
    NSMutableSet<NSString *> *missing = MissingKeys();
    @synchronized(missing) {
        return [missing copy];
    }
}

@implementation SZFriendsStrings {
    SZFriendsAudience *_audience;
    NSDictionary<NSString *, NSString *> *_catalog;
    NSCalendar *_calendar;
}

- (instancetype)initWithAudience:(SZFriendsAudience *)audience {
    if ((self = [super init])) {
        _audience = audience;
        // M1 ships English; a translation adds its own table here, chosen by audience.locale.
        _catalog = SZFriendsEnglishCatalog();
        _calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        _calendar.timeZone = audience.timeZone ?: [NSTimeZone systemTimeZone];
        _calendar.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    }
    return self;
}

- (SZFriendsAudience *)audience {
    return _audience;
}

- (BOOL)reachesOnline {
    return [_audience.helperCapabilities containsObject:@"online"];
}

#pragma mark - Catalog lookup

- (NSString *)text:(NSString *)key {
    return [self text:key values:nil];
}

- (NSString *)text:(NSString *)key values:(NSDictionary<NSString *, NSString *> *)values {
    NSString *template = _catalog[key];
    if (!template) {
        NSMutableSet<NSString *> *missing = MissingKeys();
        @synchronized(missing) {
            [missing addObject:key];
        }
        return key;
    }
    if ([template rangeOfString:@"{"].location == NSNotFound) return template;
    // {apps} is the catalog's own (apps.with_friends), so no caller has to pass it and no string names the apps itself.
    if (!values[@"apps"] && [template rangeOfString:@"{apps}"].location != NSNotFound) {
        NSMutableDictionary<NSString *, NSString *> *with = [values mutableCopy] ?: [NSMutableDictionary dictionary];
        with[@"apps"] = _catalog[@"apps.with_friends"];
        values = with;
    }
    if (values.count == 0) return template;
    NSMutableString *result = [NSMutableString stringWithCapacity:template.length + 32];
    NSScanner *scanner = [NSScanner scannerWithString:template];
    scanner.charactersToBeSkipped = nil;
    while (!scanner.isAtEnd) {
        NSString *literal = nil;
        if ([scanner scanUpToString:@"{" intoString:&literal]) [result appendString:literal];
        if (scanner.isAtEnd) break;
        scanner.scanLocation += 1;
        NSString *name = nil;
        [scanner scanUpToString:@"}" intoString:&name];
        if (scanner.isAtEnd) { // an unclosed brace is literal text
            [result appendFormat:@"{%@", name ?: @""];
            break;
        }
        scanner.scanLocation += 1;
        NSString *value = name ? values[name] : nil;
        if (value) {
            [result appendString:value];
        } else {
            NSMutableSet<NSString *> *missing = MissingKeys();
            @synchronized(missing) {
                [missing addObject:[NSString stringWithFormat:@"%@{%@}", key, name]];
            }
            [result appendFormat:@"{%@}", name];
        }
    }
    return result;
}

- (NSString *)text:(NSString *)key count:(NSInteger)count values:(NSDictionary<NSString *, NSString *> *)values {
    NSMutableDictionary<NSString *, NSString *> *filled = [values mutableCopy] ?: [NSMutableDictionary dictionary];
    filled[@"count"] = [NSString stringWithFormat:@"%ld", (long)count];
    // English plural rule; a language without plural forms keeps only ".other" and this picks it.
    NSString *one = [key stringByAppendingString:@".one"];
    if (count == 1 && _catalog[one]) return [self text:one values:filled];
    return [self text:[key stringByAppendingString:@".other"] values:filled];
}

- (NSDictionary<NSString *, NSString *> *)staticStrings {
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      keys = @[
          @"button_label", @"tab_friends", @"tab_nearby", @"search_placeholder", @"people_nearby", @"back", @"copy",
          @"copied", @"copy_your_id", @"edit_name", @"conversation_search_placeholder", @"attach_keys", @"attach_note",
          @"drop_hint", @"drop_folders_refused", @"drop_not_a_file", @"drop_send_one", @"drop_send_many",
          @"drop_send_file", @"drop_send_file_and_more", @"animals_title", @"crop_title", @"crop_use", @"cancel",
          @"loading", @"load_earlier", @"link_open", @"link_open_email", @"link_elsewhere", @"queued_note",
          @"show_all", @"save", @"name_empty", @"name_saved", @"beta", @"button_tooltip", @"beta_note"
      ];
    });
    // Only {apps} is the helper's to fill; the placeholders views and hosts fill (PROTOCOL.md § Static strings) stay
    // as they are.
    NSDictionary<NSString *, NSString *> *values = @{
        @"apps" : [self text:@"apps.with_friends"], @"count" : @"{count}", @"name" : @"{name}", @"host" : @"{host}",
        @"shown" : @"{shown}", @"first" : @"{first}"
    };
    NSMutableDictionary<NSString *, NSString *> *strings = [NSMutableDictionary dictionaryWithCapacity:keys.count];
    for (NSString *key in keys) strings[key] = [self text:[@"static." stringByAppendingString:key] values:values];
    // A host's own surfaces say when a queued message goes as the conversation does: online too, once it can be.
    if (self.reachesOnline) strings[@"queued_note"] = [self text:@"static.queued_note.online" values:values];
    return strings;
}

#pragma mark - Dates

// Whole calendar days from `date` to `now` in the audience's zone: 0 today, 1 yesterday, negative in the future.
- (NSInteger)daysFrom:(NSDate *)date to:(NSDate *)now {
    NSDate *from = [_calendar startOfDayForDate:date], *to = [_calendar startOfDayForDate:now];
    return [_calendar components:NSCalendarUnitDay fromDate:from toDate:to options:0].day;
}

- (BOOL)date:(NSDate *)date isSameDayAs:(NSDate *)other {
    return [_calendar isDate:date inSameDayAsDate:other];
}

- (NSString *)clockLabelForDate:(NSDate *)date {
    NSDateComponents *parts = [_calendar components:NSCalendarUnitHour | NSCalendarUnitMinute fromDate:date];
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)parts.hour, (long)parts.minute];
}

- (NSString *)weekdayForDate:(NSDate *)date {
    NSInteger weekday = [_calendar component:NSCalendarUnitWeekday fromDate:date]; // 1 = Sunday
    return [self text:[NSString stringWithFormat:@"weekday.%ld", (long)weekday]];
}

// "3 Oct", or "3 Oct 2025" outside the current year; `longMonth` spells "October" for speech.
- (NSString *)calendarDate:(NSDate *)date now:(NSDate *)now longMonth:(BOOL)longMonth {
    NSDateComponents *parts = [_calendar components:NSCalendarUnitDay | NSCalendarUnitMonth | NSCalendarUnitYear
                                           fromDate:date];
    NSInteger thisYear = [_calendar component:NSCalendarUnitYear fromDate:now];
    NSString *month = [self text:[NSString stringWithFormat:longMonth ? @"month.long.%ld" : @"month.short.%ld",
                                                            (long)parts.month]];
    NSDictionary *values = @{
        @"day" : [NSString stringWithFormat:@"%ld", (long)parts.day],
        @"month" : month,
        @"year" : [NSString stringWithFormat:@"%ld", (long)parts.year]
    };
    return [self text:parts.year == thisYear ? @"date.day_month" : @"date.day_month_year" values:values];
}

// The day word shared by the variants below: nil when the date needs its calendar date.
- (NSString *)relativeDay:(NSDate *)date now:(NSDate *)now capitalized:(BOOL)capitalized {
    NSInteger days = [self daysFrom:date to:now];
    if (days == 0) return [self text:capitalized ? @"time.today" : @"time.today_lower"];
    if (days == 1) return [self text:capitalized ? @"time.yesterday" : @"time.yesterday_lower"];
    if (days >= 2 && days <= 6) return [self weekdayForDate:date];
    return nil;
}

- (NSString *)timeLabelForDate:(NSDate *)date now:(NSDate *)now {
    if ([self daysFrom:date to:now] == 0) return [self clockLabelForDate:date];
    return [self relativeDay:date now:now capitalized:YES] ?: [self calendarDate:date now:now longMonth:NO];
}

- (NSString *)timeAccessibilityLabelForDate:(NSDate *)date now:(NSDate *)now {
    if ([self daysFrom:date to:now] == 0) return [self clockLabelForDate:date];
    return [self relativeDay:date now:now capitalized:NO] ?: [self calendarDate:date now:now longMonth:YES];
}

- (NSString *)dayLabelForDate:(NSDate *)date now:(NSDate *)now {
    return [self relativeDay:date now:now capitalized:YES] ?: [self calendarDate:date now:now longMonth:NO];
}

- (NSString *)dayAccessibilityLabelForDate:(NSDate *)date now:(NSDate *)now {
    return [self relativeDay:date now:now capitalized:YES] ?: [self calendarDate:date now:now longMonth:YES];
}

- (NSString *)momentPhraseForDate:(NSDate *)date now:(NSDate *)now {
    NSString *day = [self relativeDay:date now:now capitalized:NO] ?: [self calendarDate:date now:now longMonth:NO];
    return [self text:@"time.moment" values:@{@"day" : day, @"time" : [self clockLabelForDate:date]}];
}

- (NSString *)momentAccessibilityPhraseForDate:(NSDate *)date now:(NSDate *)now {
    NSString *day = [self relativeDay:date now:now capitalized:NO] ?: [self calendarDate:date now:now longMonth:YES];
    return [self text:@"time.moment" values:@{@"day" : day, @"time" : [self clockLabelForDate:date]}];
}

- (NSString *)dayPhraseForDate:(NSDate *)date now:(NSDate *)now {
    NSInteger days = [self daysFrom:date to:now];
    if (days == 0 || days == 1) return [self relativeDay:date now:now capitalized:NO];
    NSString *day = [self relativeDay:date now:now capitalized:NO] ?: [self calendarDate:date now:now longMonth:NO];
    return [self text:@"time.on_day" values:@{@"day" : day}];
}

- (NSString *)dayItemIDForDate:(NSDate *)date {
    NSDateComponents *parts = [_calendar components:NSCalendarUnitDay | NSCalendarUnitMonth | NSCalendarUnitYear
                                           fromDate:date];
    return [NSString stringWithFormat:@"d_%04ld%02ld%02ld", (long)parts.year, (long)parts.month, (long)parts.day];
}

#pragma mark - Durations, countdowns and estimates

// Buckets an estimate so it reads like a person would say it: the nearest 5 seconds under a minute ("about"
// means nearest, not an upper bound), whole minutes under an hour, then hours and minutes.
static void Bucket(double seconds, long *outSeconds, long *outMinutes, long *outHours) {
    *outSeconds = *outMinutes = *outHours = 0;
    if (!(seconds > 0)) seconds = 0;
    long fives = lround(seconds / 5.0) * 5;
    if (fives < 5) fives = 5;
    if (fives < 60) {
        *outSeconds = fives;
        return;
    }
    long minutes = lround(seconds / 60.0);
    if (minutes < 1) minutes = 1;
    if (minutes < 60) {
        *outMinutes = minutes;
        return;
    }
    *outHours = minutes / 60;
    *outMinutes = minutes % 60;
}

- (NSString *)durationLabelForSeconds:(double)seconds {
    long s, m, h;
    Bucket(seconds, &s, &m, &h);
    NSString *(^n)(long) = ^(long value) {
      return [NSString stringWithFormat:@"%ld", value];
    };
    if (s) return [self text:@"duration.seconds" values:@{@"n" : n(s)}];
    if (!h) return [self text:@"duration.minutes" values:@{@"n" : n(m)}];
    if (!m) return [self text:@"duration.hours" values:@{@"h" : n(h)}];
    return [self text:@"duration.hours_minutes" values:@{@"h" : n(h), @"m" : n(m)}];
}

- (NSString *)durationAccessibilityLabelForSeconds:(double)seconds {
    long s, m, h;
    Bucket(seconds, &s, &m, &h);
    NSString *spoken;
    if (s) spoken = [self text:@"unit.second" count:s values:nil];
    else if (!h) spoken = [self text:@"unit.minute" count:m values:nil];
    else if (!m) spoken = [self text:@"unit.hour" count:h values:nil];
    else
        spoken = [self text:@"unit.pair"
                     values:@{
                         @"first" : [self text:@"unit.hour" count:h values:nil],
                         @"second" : [self text:@"unit.minute" count:m values:nil]
                     }];
    return [self text:@"duration.about" values:@{@"duration" : spoken}];
}

- (NSString *)countdownLabelForRemaining:(NSTimeInterval)remaining {
    long total = remaining > 0 ? (long)ceil(remaining) : 0;
    return [NSString stringWithFormat:@"%ld:%02ld", total / 60, total % 60];
}

- (NSString *)countdownAccessibilityLabelForRemaining:(NSTimeInterval)remaining {
    long total = remaining > 0 ? (long)ceil(remaining) : 0;
    long minutes = total / 60, seconds = total % 60;
    NSString *duration;
    if (minutes && seconds)
        duration = [self text:@"unit.pair"
                       values:@{
                           @"first" : [self text:@"unit.minute" count:minutes values:nil],
                           @"second" : [self text:@"unit.second" count:seconds values:nil]
                       }];
    else if (minutes)
        duration = [self text:@"unit.minute" count:minutes values:nil];
    else
        duration = [self text:@"unit.second" count:seconds values:nil];
    return [self text:@"countdown.left" values:@{@"duration" : duration}];
}

// Only routes slow enough that the person may want to wait for a better one get an estimate (brief § Interface).
static NSString *EstimateKey(SZFriendsRouteMethod route) {
    if (route == SZFriendsRouteMethodBluetooth) return @"estimate.bluetooth";
    if (route == SZFriendsRouteMethodRelay) return @"estimate.relay";
    return nil;
}

// The relay holds each session to 5 Mbit/s (ADR 0010: coturn's max-bps, 625,000 bytes a second), and a transfer
// through it measured 3.7 to 4.2 Mbit/s of payload (m2-decision-brief.md § Stack). So an estimate there never assumes
// more than the cap, and before a rate is measured it assumes 4 Mbit/s: the owner caps the relay, and the person
// deciding whether to accept now or wait nearby needs the time that cap gives.
static const double SZFriendsRelayCapBytesPerSecond = 625000;
static const double SZFriendsRelayPayloadBytesPerSecond = 500000;

- (double)estimateBytesPerSecond:(double)measured route:(SZFriendsRouteMethod)route {
    if (!(measured > 0)) measured = 0;
    if (route != SZFriendsRouteMethodRelay) return measured;
    return measured > 0 ? MIN(measured, SZFriendsRelayCapBytesPerSecond) : SZFriendsRelayPayloadBytesPerSecond;
}

- (NSString *)transferEstimateForRemainingBytes:(uint64_t)bytes
                                 bytesPerSecond:(double)bytesPerSecond
                                          route:(SZFriendsRouteMethod)route {
    NSString *key = EstimateKey(route);
    if (!key) return nil;
    NSString *prefix = [self text:key];
    bytesPerSecond = [self estimateBytesPerSecond:bytesPerSecond route:route];
    if (!(bytesPerSecond > 0)) return prefix; // no rate measured yet: say the route, promise no time
    return [self text:@"estimate.with_time"
               values:@{@"route" : prefix, @"duration" : [self durationLabelForSeconds:bytes / bytesPerSecond]}];
}

- (NSString *)transferEstimateAccessibilityForRemainingBytes:(uint64_t)bytes
                                              bytesPerSecond:(double)bytesPerSecond
                                                       route:(SZFriendsRouteMethod)route {
    NSString *key = EstimateKey(route);
    if (!key) return nil;
    NSString *prefix = [self spokenFragment:[self text:key]];
    bytesPerSecond = [self estimateBytesPerSecond:bytesPerSecond route:route];
    if (!(bytesPerSecond > 0)) return prefix;
    return [self text:@"estimate.with_time"
               values:@{
                   @"route" : prefix,
                   @"duration" : [self durationAccessibilityLabelForSeconds:bytes / bytesPerSecond]
               }];
}

#pragma mark - Sizes, badges, routes

// Decimal units, as Finder shows them: one decimal below 100 ("2.4 MB", "18.6 MB"), none above ("120 MB").
- (NSString *)sizeLabelForBytes:(uint64_t)bytes {
    if (bytes < 1000) return [self text:@"size.bytes" count:(NSInteger)bytes values:nil];
    long kilobytes = lround(bytes / 1000.0);
    if (kilobytes < 1000) return [self text:@"size.kb" values:@{@"n" : [NSString stringWithFormat:@"%ld", kilobytes]}];
    static NSString *const units[] = {@"size.mb", @"size.gb", @"size.tb"};
    double value = bytes / 1e6;
    int unit = 0;
    while (unit < 2 && lround(value) >= 1000) {
        value /= 1000.0;
        unit++;
    }
    NSString *number;
    if (value < 99.95) {
        number = [NSString stringWithFormat:@"%.1f", value];
        if ([number hasSuffix:@".0"]) number = [number substringToIndex:number.length - 2];
    } else {
        number = [NSString stringWithFormat:@"%ld", lround(value)];
    }
    return [self text:units[unit] values:@{@"n" : number}];
}

- (NSString *)badgeLabelForCount:(NSInteger)count {
    if (count <= 0) return @"";
    if (count > 99) return [self text:@"badge.many"];
    return [NSString stringWithFormat:@"%ld", (long)count];
}

- (NSString *)routeLabelForKind:(SZFriendsRouteKind)kind method:(SZFriendsRouteMethod)method {
    switch (kind) {
    case SZFriendsRouteKindLocal:
        if (method == SZFriendsRouteMethodLAN) return [self text:@"route.lan"];
        if (method == SZFriendsRouteMethodPeerToPeerWiFi) return [self text:@"route.p2p_wifi"];
        if (method == SZFriendsRouteMethodBluetooth) return [self text:@"route.bluetooth"];
        return [self text:@"route.local"];
    case SZFriendsRouteKindOnline:
        if (method == SZFriendsRouteMethodRelay) return [self text:@"route.relay"];
        return [self text:method == SZFriendsRouteMethodInternet ? @"route.internet" : @"route.online"];
    case SZFriendsRouteKindOffline:
        return [self text:@"route.offline"];
    case SZFriendsRouteKindNone:
        return @"";
    }
    return @"";
}

#pragma mark - Small wording helpers

- (NSString *)spokenFragment:(NSString *)phrase {
    if (phrase.length < 2 || ![self.audience.locale.lowercaseString hasPrefix:@"en"]) return phrase;
    unichar first = [phrase characterAtIndex:0], second = [phrase characterAtIndex:1];
    NSCharacterSet *upper = [NSCharacterSet uppercaseLetterCharacterSet];
    // "ID ..." or "PDF ..." keep their capitals; only a capitalised first word is lowered.
    if (![upper characterIsMember:first] || [upper characterIsMember:second]) return phrase;
    return [[[phrase substringToIndex:1] lowercaseString] stringByAppendingString:[phrase substringFromIndex:1]];
}

- (NSString *)firstNameForName:(NSString *)name friendsID:(NSString *)friendsID {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        NSRange space = [trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet];
        return space.location == NSNotFound ? trimmed : [trimmed substringToIndex:space.location];
    }
    return friendsID.length ? [self displayID:friendsID] : [self text:@"person.unnamed"];
}

- (NSString *)displayID:(NSString *)friendsID {
    return [friendsID ?: @"" stringByReplacingOccurrencesOfString:@"-" withString:@"\u2011"];
}

- (NSString *)joinedList:(NSArray<NSString *> *)items {
    if (items.count == 0) return @"";
    if (items.count == 1) return items[0];
    NSArray<NSString *> *head = [items subarrayWithRange:NSMakeRange(0, items.count - 1)];
    return [self text:@"list.join"
               values:@{
                   @"head" : [head componentsJoinedByString:[self text:@"list.separator"]],
                   @"last" : items.lastObject
               }];
}

- (NSString *)kindLabelForFileName:(NSString *)fileName extension:(NSString *)extension {
    NSString *ext = (extension.length ? extension : fileName.pathExtension).lowercaseString;
    if (ext.length == 0) return [self text:@"kind.file"];
    NSString *key = [@"kind." stringByAppendingString:ext];
    if (SZFriendsEnglishCatalog()[key]) return [self text:key];
    return ext.uppercaseString;
}

- (NSString *)groupedComparisonCode:(NSString *)digits {
    if (digits.length != 6) return digits;
    return [NSString stringWithFormat:@"%@ %@", [digits substringToIndex:3], [digits substringFromIndex:3]];
}

- (NSString *)spokenComparisonCode:(NSString *)digits {
    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (NSUInteger start = 0; start < digits.length; start += 3) {
        NSString *group = [digits substringWithRange:NSMakeRange(start, MIN((NSUInteger)3, digits.length - start))];
        NSMutableArray<NSString *> *characters = [NSMutableArray array];
        for (NSUInteger i = 0; i < group.length; i++)
            [characters addObject:[group substringWithRange:NSMakeRange(i, 1)]];
        [groups addObject:[characters componentsJoinedByString:@" "]];
    }
    return [self text:@"code.spoken" values:@{@"code" : [groups componentsJoinedByString:@", "]}];
}

#pragma mark - Replies (worded in SZFriendsStrings+Messages.m)

- (NSString *)messageForErrorCode:(NSString *)code details:(NSDictionary<NSString *, id> *)details {
    return [self errorMessageForCode:code details:details];
}

- (NSString *)addByIDSentMessageForID:(NSString *)friendsID {
    return [self addByIDMessageForID:friendsID];
}

- (NSString *)addByIDSentMessageForID:(NSString *)friendsID online:(BOOL)online {
    if (!online) return [self addByIDMessageForID:friendsID];
    return [self text:@"add_by_id.sent.online" values:@{@"id" : [self displayID:friendsID]}];
}

@end
