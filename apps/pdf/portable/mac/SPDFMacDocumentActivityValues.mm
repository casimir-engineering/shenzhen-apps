// The pure half of SPDFMacDocumentActivity.h: merging entries, the one-time backfill, what the assistant reads, and
// the 2-second clock. No AppKit, no store, no disk except the creation date of a History copy during backfill.
#import "SPDFMacDocumentActivity.h"
#include <math.h>

static const NSTimeInterval kReferenceDateOffset = 978307200; // NSDate's reference date in Unix seconds

static double Number(id value) {
    return [value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) && [value doubleValue] > 0
        ? [value doubleValue] : 0;
}
static void KeepLatest(NSMutableDictionary* into, NSString* key, double value) {
    if (value > Number(into[key])) into[key] = @(round(value));
}

NSDictionary* SPDFDocumentActivityMerge(NSDictionary* a, NSDictionary* b) {
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    NSMutableDictionary* estimate = [NSMutableDictionary dictionary];
    for (NSDictionary* entry in @[ a ?: @{}, b ?: @{} ]) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        KeepLatest(result, @"opened", Number(entry[@"opened"]));
        KeepLatest(result, @"viewed", Number(entry[@"viewed"]));
        NSDictionary* guess = [entry[@"estimate"] isKindOfClass:NSDictionary.class] ? entry[@"estimate"] : nil;
        // The later "not viewed after" is the weaker claim, so two sources agree on it.
        for (NSString* key in @[ @"opened", @"viewed", @"notViewedSince" ]) KeepLatest(estimate, key, Number(guess[key]));
    }
    if (estimate.count) result[@"estimate"] = estimate;
    return result;
}

NSDictionary* SPDFDocumentActivityCombine(NSArray<NSDictionary*>* entries) {
    NSDictionary* result = @{};
    for (NSDictionary* entry in entries) result = SPDFDocumentActivityMerge(result, entry);
    return result;
}

static NSString* Standard(id path) {
    return [path isKindOfClass:NSString.class] && [path length] ? [path stringByStandardizingPath] : nil;
}

NSDictionary<NSString*, NSDictionary*>* SPDFDocumentActivityBackfill(NSDictionary* session, NSArray* collection,
    NSArray* recents, NSTimeInterval (^lastUsed)(NSString* path), NSTimeInterval before) {
    double limit = before > 0 ? before : DBL_MAX;
    void (^keep)(NSMutableDictionary*, NSString*, double) = ^(NSMutableDictionary* into, NSString* key, double value) {
        if (value < limit) KeepLatest(into, key, value);
    };
    NSMutableDictionary<NSString*, NSMutableDictionary*>* guesses = [NSMutableDictionary dictionary];
    NSMutableDictionary* (^guess)(NSString*) = ^NSMutableDictionary*(NSString* path) {
        if (!guesses[path]) guesses[path] = [NSMutableDictionary dictionary];
        return guesses[path];
    };
    NSArray* windows = [session isKindOfClass:NSDictionary.class] && [session[@"windows"] isKindOfClass:NSArray.class]
        ? session[@"windows"] : @[];
    // Tab activation times ("lastViewedAt", reference-date seconds) were recorded from some release on. The earliest
    // one still in the session is no earlier than that, so a tab without one was not selected after it.
    double firstActivation = 0;
    for (NSDictionary* window in windows)
        for (NSDictionary* tab in [window isKindOfClass:NSDictionary.class] ? window[@"tabs"] : nil) {
            double activated = [tab isKindOfClass:NSDictionary.class] ? Number(tab[@"lastViewedAt"]) : 0;
            if (activated + kReferenceDateOffset >= limit) continue;
            if (activated && (!firstActivation || activated < firstActivation)) firstActivation = activated;
        }
    NSMutableSet* inSession = [NSMutableSet set];
    for (NSDictionary* window in windows) {
        if (![window isKindOfClass:NSDictionary.class] || ![window[@"tabs"] isKindOfClass:NSArray.class]) continue;
        NSInteger selected = [window[@"selectedTab"] respondsToSelector:@selector(integerValue)]
            ? [window[@"selectedTab"] integerValue] : -1;
        double focused = Number(window[@"focusedAt"]);
        NSArray* tabs = window[@"tabs"];
        for (NSUInteger index = 0; index < tabs.count; index++) {
            NSDictionary* tab = tabs[index];
            NSString* path = [tab isKindOfClass:NSDictionary.class] ? Standard(tab[@"path"]) : nil;
            if (!path) continue;
            [inSession addObject:path];
            NSMutableDictionary* entry = guess(path);
            double activated = Number(tab[@"lastViewedAt"]);
            if (activated + kReferenceDateOffset >= limit) activated = 0;
            // The selected tab was in front whenever its window last became key.
            double seen = MAX(activated, (NSInteger)index == selected && focused + kReferenceDateOffset < limit ? focused : 0);
            if (activated) keep(entry, @"opened", activated + kReferenceDateOffset);
            if (seen) keep(entry, @"viewed", seen + kReferenceDateOffset);
            else if (firstActivation) keep(entry, @"notViewedSince", firstActivation + kReferenceDateOffset);
        }
    }
    NSMutableOrderedSet* lookups = [NSMutableOrderedSet orderedSet];
    for (NSDictionary* row in [collection isKindOfClass:NSArray.class] ? collection : @[]) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        // Added to Collection when first opened; lastOpenedAt and "Opened" captures are later opens.
        double opened = MAX(Number(row[@"lastOpenedAt"]), Number(row[@"capturedAt"]));
        for (NSDictionary* version in [row[@"versions"] isKindOfClass:NSArray.class] ? row[@"versions"] : @[])
            if ([version isKindOfClass:NSDictionary.class] && [version[@"reason"] isEqual:@"Opened"])
                opened = MAX(opened, Number(version[@"capturedAt"]));
        NSMutableArray* paths = [NSMutableArray array];
        if (Standard(row[@"path"])) [paths addObject:Standard(row[@"path"])];
        for (id alias in [row[@"aliases"] isKindOfClass:NSArray.class] ? row[@"aliases"] : @[])
            if (Standard(alias) && ![paths containsObject:Standard(alias)]) [paths addObject:Standard(alias)];
        for (NSString* path in paths) if (opened) keep(guess(path), @"opened", opened);
        if (Standard(row[@"path"])) [lookups addObject:Standard(row[@"path"])];
        // A History copy is made when its revision is opened.
        for (id copy in [row[@"editablePaths"] isKindOfClass:NSArray.class] ? row[@"editablePaths"] : @[]) {
            NSString* path = Standard(copy);
            if (!path) continue;
            NSDate* made = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileCreationDate;
            keep(guess(path), @"opened", MAX(opened, made.timeIntervalSince1970));
        }
    }
    for (id path in [recents isKindOfClass:NSArray.class] ? recents : @[]) if (Standard(path)) [lookups addObject:Standard(path)];
    for (NSString* path in lookups) {
        if ([inSession containsObject:path] || !lastUsed) continue;
        double used = lastUsed(path);
        if (used) keep(guess(path), @"opened", used);
    }
    // Outside the session, an open is the only sign of a view: an opened document is shown.
    NSMutableDictionary* result = [NSMutableDictionary dictionary];
    for (NSString* path in guesses) {
        NSMutableDictionary* entry = guesses[path];
        if (![inSession containsObject:path] && entry[@"opened"]) KeepLatest(entry, @"viewed", Number(entry[@"opened"]));
        if (entry[@"viewed"]) [entry removeObjectForKey:@"notViewedSince"];
        if (entry.count) result[path] = @{@"estimate" : entry};
    }
    return result;
}

NSString* SPDFDocumentActivityISO(NSTimeInterval unixTime, NSTimeZone* zone) {
    NSISO8601DateFormatter* formatter = [NSISO8601DateFormatter new];
    formatter.timeZone = zone;
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:unixTime]];
}

NSTimeInterval SPDFDocumentActivityParseTime(NSString* text, NSTimeZone* zone) {
    if (![text isKindOfClass:NSString.class] || !text.length) return NAN;
    NSISO8601DateFormatter* formatter = [NSISO8601DateFormatter new];
    formatter.timeZone = zone;
    for (NSNumber* options in @[ @(NSISO8601DateFormatWithInternetDateTime),
                                 @(NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds),
                                 @(NSISO8601DateFormatWithFullDate | NSISO8601DateFormatWithFullTime |
                                   NSISO8601DateFormatWithDashSeparatorInDate |
                                   NSISO8601DateFormatWithColonSeparatorInTime) ]) {
        formatter.formatOptions = options.unsignedIntegerValue;
        NSDate* date = [formatter dateFromString:text];
        if (date) return date.timeIntervalSince1970;
    }
    NSDateFormatter* day = [NSDateFormatter new];
    day.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    day.timeZone = zone;
    day.dateFormat = @"yyyy-MM-dd";
    NSDate* date = text.length == 10 ? [day dateFromString:text] : nil;
    return date ? date.timeIntervalSince1970 : NAN;
}

NSDictionary* SPDFDocumentActivityFields(NSDictionary* entry, NSTimeZone* zone) {
    NSDictionary* guess = [entry[@"estimate"] isKindOfClass:NSDictionary.class] ? entry[@"estimate"] : @{};
    NSMutableDictionary* fields = [NSMutableDictionary dictionary];
    for (NSString* key in @[ @"opened", @"viewed" ]) {
        double real = Number(entry[key]), estimated = Number(guess[key]);
        NSString* name = [@"last_" stringByAppendingString:key];
        fields[name] = real || estimated ? SPDFDocumentActivityISO(real ?: estimated, zone) : (id)NSNull.null;
        if (!real && estimated) fields[[name stringByAppendingString:@"_estimated"]] = @YES;
    }
    if (!Number(entry[@"viewed"]) && !Number(guess[@"viewed"]) && Number(guess[@"notViewedSince"]))
        fields[@"not_viewed_since"] = SPDFDocumentActivityISO(Number(guess[@"notViewedSince"]), zone);
    return fields;
}

NSInteger SPDFDocumentActivityNotViewedSince(NSDictionary* entry, NSTimeInterval cutoff, NSTimeInterval recordedSince) {
    double real = Number(entry[@"viewed"]);
    if (recordedSince > 0 && recordedSince <= cutoff) return real >= cutoff ? 0 : 1;
    if (real >= cutoff) return 0;
    NSDictionary* guess = [entry[@"estimate"] isKindOfClass:NSDictionary.class] ? entry[@"estimate"] : @{};
    double viewed = MAX(real, Number(guess[@"viewed"]));
    if (viewed) return viewed < cutoff ? 1 : 0;
    double notSince = Number(guess[@"notViewedSince"]);
    return notSince && notSince <= cutoff ? 1 : -1;
}

@implementation SPDFMacDocumentViewClock {
    NSTimeInterval _threshold, _heartbeat, _idleLimit, _since, _qualifiedAt;
    BOOL _qualified, _away;
}
- (instancetype)initWithThreshold:(NSTimeInterval)threshold heartbeat:(NSTimeInterval)heartbeat
                        idleLimit:(NSTimeInterval)idleLimit {
    if ((self = [super init])) { _threshold = threshold; _heartbeat = heartbeat; _idleLimit = idleLimit; }
    return self;
}
static NSDictionary* Stamp(NSString* path, NSTimeInterval at) { return @{@"path" : path, @"at" : @(at)}; }
- (NSArray<NSDictionary*>*)showPath:(NSString*)path at:(NSTimeInterval)now idle:(NSTimeInterval)idle {
    if (path == _path || [path isEqual:_path]) return @[];
    NSMutableArray* stamps = [NSMutableArray array];
    // A qualified view that ends is stamped then, or when the person last touched the Mac if they had left.
    if (_path && _qualified && !_away) [stamps addObject:Stamp(_path, idle < _idleLimit ? now : MAX(_qualifiedAt, now - idle))];
    _path = [path copy];
    _since = now; _qualified = NO; _away = NO;
    _deadline = path ? now + _threshold : 0;
    return stamps;
}
- (NSArray<NSDictionary*>*)tickAt:(NSTimeInterval)now idle:(NSTimeInterval)idle {
    if (!_path) { _deadline = 0; return @[]; }
    if (!_qualified) {
        // An unattended relaunch (an update at night) puts a tab in front with nobody there: wait for the person.
        if (now + 0.05 < _since + _threshold) { _deadline = _since + _threshold; return @[]; }
        _deadline = now + _heartbeat;
        if (idle >= _idleLimit) return @[];
        _qualified = YES; _qualifiedAt = now;
        return @[ Stamp(_path, now) ];
    }
    _deadline = now + _heartbeat;
    if (idle < _idleLimit) { _away = NO; return @[ Stamp(_path, now) ]; }
    if (_away) return @[];
    _away = YES;
    return @[ Stamp(_path, MAX(_qualifiedAt, now - idle)) ];
}
@end
