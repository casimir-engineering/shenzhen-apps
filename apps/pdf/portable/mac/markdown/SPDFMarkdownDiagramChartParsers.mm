#import "SPDFMarkdownDiagramInternal.h"

// mermaid `pie` and `gantt` parsers.

SPDFMarkdownDiagramPie* SPDFMarkdownDiagramParsePie(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count) return nil;
    NSString* header = lines.firstObject;
    NSString* lowered = header.lowercaseString;
    if (![lowered isEqualToString:@"pie"] && ![lowered hasPrefix:@"pie "]) return nil;
    SPDFMarkdownDiagramPie* pie = [SPDFMarkdownDiagramPie new];
    NSString* headerRest = header.length > 3 ? SPDFMarkdownDiagramTrim([header substringFromIndex:3]) : @"";
    if ([headerRest.lowercaseString hasPrefix:@"showdata"])
        headerRest = SPDFMarkdownDiagramTrim([headerRest substringFromIndex:@"showdata".length]);
    if ([headerRest.lowercaseString hasPrefix:@"title"])
        pie.title = SPDFMarkdownDiagramCleanLabel([headerRest substringFromIndex:@"title".length]);
    for (NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSString* lineLowered = line.lowercaseString;
        if ([lineLowered hasPrefix:@"title"]) {
            pie.title = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:@"title".length]);
            continue;
        }
        if ([lineLowered isEqualToString:@"showdata"]) continue;
        // `"label" : value` (the quotes are mermaid-required; accept unquoted).
        NSRange colon = [line rangeOfString:@":" options:NSBackwardsSearch];
        if (colon.location == NSNotFound) return nil;
        NSString* label = SPDFMarkdownDiagramCleanLabel([line substringToIndex:colon.location]);
        NSString* valueText = SPDFMarkdownDiagramTrim([line substringFromIndex:NSMaxRange(colon)]);
        if (!label.length || !valueText.length) return nil;
        NSScanner* scanner = [NSScanner scannerWithString:valueText];
        double value = 0;
        if (![scanner scanDouble:&value] || !scanner.isAtEnd || value < 0 || !isfinite(value)) return nil;
        SPDFMarkdownDiagramPieSlice* slice = [SPDFMarkdownDiagramPieSlice new];
        slice.label = label;
        slice.value = value;
        [pie.slices addObject:slice];
        if (pie.slices.count > SPDFMarkdownDiagramMaximumNodes) return nil;
    }
    double total = 0;
    for (SPDFMarkdownDiagramPieSlice* slice in pie.slices) total += slice.value;
    return pie.slices.count && total > 0 ? pie : nil;
}

// --- gantt ------------------------------------------------------------------

static NSDate* SPDFGanttParseDate(NSString* text) {
    // The common `YYYY-MM-DD` shape only (documented); dateFormat lines are
    // accepted but any other format fails the diagram.
    static NSDateFormatter* formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      formatter = [NSDateFormatter new];
      formatter.dateFormat = @"yyyy-MM-dd";
      formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
      formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter dateFromString:text];
}

static NSInteger SPDFGanttDayForDate(NSDate* date, NSDate* epoch) {
    return (NSInteger)llround([date timeIntervalSinceDate:epoch] / 86400.0);
}

// `Nd` / `Nw` / `Nh` durations, in whole days (hours round up to >= 1 day).
static BOOL SPDFGanttParseDuration(NSString* text, NSInteger* outDays) {
    if (text.length < 2) return NO;
    unichar unit = [text characterAtIndex:text.length - 1];
    NSString* amountText = [text substringToIndex:text.length - 1];
    NSScanner* scanner = [NSScanner scannerWithString:amountText];
    double amount = 0;
    if (![scanner scanDouble:&amount] || !scanner.isAtEnd || amount <= 0) return NO;
    if (unit == 'd') *outDays = (NSInteger)ceil(amount);
    else if (unit == 'w') *outDays = (NSInteger)ceil(amount * 7);
    else if (unit == 'h') *outDays = MAX((NSInteger)1, (NSInteger)ceil(amount / 24.0));
    else return NO;
    return YES;
}

SPDFMarkdownDiagramGantt* SPDFMarkdownDiagramParseGantt(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count || ![lines.firstObject.lowercaseString isEqualToString:@"gantt"]) return nil;
    SPDFMarkdownDiagramGantt* gantt = [SPDFMarkdownDiagramGantt new];
    SPDFMarkdownDiagramGanttSection* section = nil;
    NSMutableDictionary<NSString*, SPDFMarkdownDiagramGanttTask*>* byIdentifier = [NSMutableDictionary dictionary];
    NSDate* epoch = nil;
    NSInteger cursorEndDay = 0;  // where a start-less task begins (mermaid chains)
    for (NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSString* lowered = line.lowercaseString;
        if ([lowered hasPrefix:@"title "]) {
            gantt.title = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:@"title ".length]);
            continue;
        }
        if ([lowered hasPrefix:@"dateformat"]) {
            NSString* format = SPDFMarkdownDiagramTrim([line substringFromIndex:@"dateformat".length]);
            if (format.length && ![format isEqualToString:@"YYYY-MM-DD"]) return nil;
            continue;
        }
        if ([lowered hasPrefix:@"axisformat"] || [lowered hasPrefix:@"excludes"] ||
            [lowered hasPrefix:@"todaymarker"] || [lowered hasPrefix:@"tickinterval"] ||
            [lowered hasPrefix:@"weekday "])
            continue;  // presentation directives the native axis replaces
        if ([lowered hasPrefix:@"section "]) {
            section = [SPDFMarkdownDiagramGanttSection new];
            section.name = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:@"section ".length]);
            [gantt.sections addObject:section];
            continue;
        }
        // Task line: `name : [crit,][active,][done,][id,] start, duration|end`.
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) return nil;
        SPDFMarkdownDiagramGanttTask* task = [SPDFMarkdownDiagramGanttTask new];
        task.name = SPDFMarkdownDiagramCleanLabel([line substringToIndex:colon.location]);
        if (!task.name.length) return nil;
        NSMutableArray<NSString*>* fields = [NSMutableArray array];
        for (NSString* field in [[line substringFromIndex:NSMaxRange(colon)] componentsSeparatedByString:@","]) {
            NSString* trimmed = SPDFMarkdownDiagramTrim(field);
            if (trimmed.length) [fields addObject:trimmed];
        }
        while (fields.count) {
            NSString* flag = fields.firstObject.lowercaseString;
            if ([flag isEqualToString:@"crit"]) task.critical = YES;
            else if ([flag isEqualToString:@"active"]) task.active = YES;
            else if ([flag isEqualToString:@"done"]) task.done = YES;
            else if ([flag isEqualToString:@"milestone"]) { /* rendered as a 1-day bar */ }
            else break;
            [fields removeObjectAtIndex:0];
        }
        // Optional id: a bare token that is neither a date, an `after` clause,
        // nor a duration, sitting before at least one more field.
        if (fields.count >= 2 && !SPDFGanttParseDate(fields.firstObject) &&
            ![fields.firstObject.lowercaseString hasPrefix:@"after "]) {
            NSInteger days = 0;
            if (!SPDFGanttParseDuration(fields.firstObject, &days)) {
                task.taskIdentifier = fields.firstObject;
                [fields removeObjectAtIndex:0];
            }
        }
        if (!fields.count) return nil;
        // Start: a date, or `after otherId`, or nothing (chained after the
        // previously parsed task).
        NSInteger startDay = cursorEndDay;
        NSString* startField = fields.firstObject;
        NSDate* startDate = SPDFGanttParseDate(startField);
        if (startDate) {
            if (!epoch) epoch = startDate;
            startDay = SPDFGanttDayForDate(startDate, epoch);
            [fields removeObjectAtIndex:0];
        } else if ([startField.lowercaseString hasPrefix:@"after "]) {
            NSString* reference = SPDFMarkdownDiagramTrim([startField substringFromIndex:@"after ".length]);
            reference = [reference componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                            .firstObject;
            SPDFMarkdownDiagramGanttTask* referenced = byIdentifier[reference ?: @""];
            if (!referenced) return nil;
            startDay = referenced.endDay;
            [fields removeObjectAtIndex:0];
        }
        if (fields.count != 1) return nil;
        // End: a duration or an absolute end date.
        NSInteger durationDays = 0;
        NSDate* endDate = SPDFGanttParseDate(fields.firstObject);
        if (endDate) {
            if (!epoch) return nil;
            task.endDay = SPDFGanttDayForDate(endDate, epoch);
        } else if (SPDFGanttParseDuration(fields.firstObject, &durationDays)) {
            task.endDay = startDay + durationDays;
        } else {
            return nil;
        }
        task.startDay = startDay;
        if (task.endDay <= task.startDay) task.endDay = task.startDay + 1;
        if (!epoch) return nil;  // at least one absolute date must anchor the axis
        if (!section) {
            section = [SPDFMarkdownDiagramGanttSection new];
            section.name = @"";
            [gantt.sections addObject:section];
        }
        [section.tasks addObject:task];
        if (task.taskIdentifier.length) byIdentifier[task.taskIdentifier] = task;
        cursorEndDay = task.endDay;
        if (gantt.taskCount > SPDFMarkdownDiagramMaximumNodes) return nil;
        // Keep the axis bounded: a pathological span would explode the chart.
        if (task.endDay - task.startDay > 3660) return nil;
    }
    gantt.epoch = epoch;
    return gantt.taskCount ? gantt : nil;
}
