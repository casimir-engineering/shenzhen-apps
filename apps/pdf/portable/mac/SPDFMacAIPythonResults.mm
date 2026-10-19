#import "SPDFMacAIPythonResults.h"

// Shown where the code, its output or a table was, once the chat is reopened after such a request: the one wording
// every request-only row uses (SPDFMacAIToolProvider.h § 4).
NSString* const SPDFMacAIPythonFriendsNotice =
    @"Not kept after this request, because it included your Friends chats.";

// The stored title for a request-only Python row, in place of the model-chosen file name a table card shows: a
// crafted CSV name could quote a friend, so the saved chat keeps this instead (D4).
NSString* const SPDFMacAIPythonStoredTableTitle = @"Table from Python";

// Said in the step when a request that read Friends chats withholds the charts the code drew (D2/D6): a saved picture
// cannot be reduced to a stub, so none is shown, and the person is told rather than left wondering.
static NSString* const kSPDFFriendsChartsWithheld =
    @"Charts aren’t shown for requests that include your Friends chats.";

const NSUInteger SPDFMacAIPythonResultBudget = 90000;

static const NSUInteger kSPDFMaxImages = 8;
static const NSUInteger kSPDFTableRows = 50;    // data rows the model reads per table
static const NSUInteger kSPDFTableColumns = 20;
static const NSUInteger kSPDFCardRows = 20;     // rows a table card shows the person
static const NSUInteger kSPDFCellCharacters = 200;
static const NSUInteger kSPDFShownOutput = 4000; // printed output the step shows the person

@implementation SPDFMacAIPythonPresentation
@end

NSString* SPDFMacAIPythonClip(NSString* text, NSUInteger limit) {
    if (text.length <= limit) return text;
    if (limit < 2) return @"…";
    NSUInteger cut = [text rangeOfComposedCharacterSequenceAtIndex:limit - 1].location;
    return [[text substringToIndex:cut] stringByAppendingString:@"…"];
}

NSString* SPDFMacAIPythonStatusLine(NSDictionary* result) {
    NSString* limit = result[@"limit"];
    NSDictionary* limits = [result[@"limits"] isKindOfClass:NSDictionary.class] ? result[@"limits"] : @{};
    if ([result[@"status"] isEqual:@"stopped"] || [limit isEqual:@"stopped"]) return @"Stopped";
    if ([limit isEqual:@"time"])
        return [NSString stringWithFormat:@"Stopped: it ran for more than %@ s", limits[@"wall_seconds"] ?: @30];
    if ([limit isEqual:@"cpu"])
        return [NSString stringWithFormat:@"Stopped: it computed for more than %@ s", limits[@"cpu_seconds"] ?: @20];
    if ([limit isEqual:@"memory"])
        return [NSString stringWithFormat:@"Stopped: it needed more than %@ MB of memory",
                                          limits[@"memory_mb"] ?: @512];
    if ([limit isEqual:@"output"]) return @"Stopped: it printed far too much";
    if ([limit isEqual:@"files"]) return @"Stopped: it wrote more than 10 MB of files";
    if ([result[@"status"] isEqual:@"completed"])
        return [NSString stringWithFormat:@"Finished in %.1f s", [result[@"seconds"] doubleValue]];
    return @"Ended with an error";
}

// What a limit means, for the model deciding what to try next.
static NSString* SPDFLimitNote(NSString* limit, NSDictionary* limits) {
    if ([limit isEqual:@"time"])
        return [NSString stringWithFormat:@"Stopped after %@ seconds of wall time. Do less work per run.",
                                          limits[@"wall_seconds"] ?: @30];
    if ([limit isEqual:@"cpu"])
        return [NSString stringWithFormat:@"Stopped after %@ seconds of CPU time. Do less work per run.",
                                          limits[@"cpu_seconds"] ?: @20];
    if ([limit isEqual:@"memory"])
        return [NSString stringWithFormat:@"Stopped for using more than %@ MB of memory. Use less data at once.",
                                          limits[@"memory_mb"] ?: @512];
    if ([limit isEqual:@"output"]) return @"Stopped for printing more than 1 MB. Print summaries, not whole data.";
    if ([limit isEqual:@"files"]) return @"Stopped for writing more than 10 MB of files, or too many files.";
    if ([limit isEqual:@"stopped"]) return @"The person or the request stopped the run.";
    return nil;
}

NSArray<NSArray<NSString*>*>* SPDFMacAIPythonParseTable(NSString* text, unichar separator, NSUInteger maxRows,
                                                        NSUInteger maxColumns, NSUInteger* totalRows) {
    NSMutableArray* rows = [NSMutableArray array];
    NSMutableArray* row = [NSMutableArray array];
    NSMutableString* cell = [NSMutableString string];
    BOOL quoted = NO, content = NO;
    NSUInteger total = 0;
    CFStringInlineBuffer buffer;
    CFIndex length = (CFIndex)text.length;
    CFStringInitInlineBuffer((__bridge CFStringRef)text, &buffer, CFRangeMake(0, length));
    void (^endCell)(void) = ^{
        if (rows.count < maxRows && row.count < maxColumns)
            [row addObject:[cell stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
        [cell setString:@""];
    };
    for (CFIndex i = 0; i <= length; i++) {
        unichar c = i < length ? CFStringGetCharacterFromInlineBuffer(&buffer, i) : '\n';
        BOOL keep = rows.count < maxRows && cell.length < kSPDFCellCharacters;
        if (quoted) {
            if (c == '"' && i + 1 < length && CFStringGetCharacterFromInlineBuffer(&buffer, i + 1) == '"') {
                if (keep) [cell appendString:@"\""];
                i++;
            } else if (c == '"') {
                quoted = NO;
            } else if (keep) {
                [cell appendFormat:@"%C", c];
            }
            continue;
        }
        if (c == '"' && !cell.length) { quoted = content = YES; continue; }
        if (c == '\r') continue;
        if (c == separator) { endCell(); content = YES; continue; }
        if (c == '\n') {
            if (!content && !cell.length) { [row removeAllObjects]; continue; } // a blank line is not a row
            endCell();
            total++;
            if (rows.count < maxRows) [rows addObject:[row copy]];
            [row removeAllObjects];
            content = NO;
            continue;
        }
        content = YES;
        if (keep) [cell appendFormat:@"%C", c];
    }
    if (totalRows) *totalRows = total;
    return rows;
}

static NSString* SPDFMarkdownCell(NSString* text) {
    NSString* cell = [text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    cell = [cell stringByReplacingOccurrencesOfString:@"|" withString:@"\\|"];
    cell = [[cell componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
        componentsJoinedByString:@" "];
    return SPDFMacAIPythonClip(cell, 80);
}

NSString* SPDFMacAIPythonMarkdownTable(NSArray<NSArray<NSString*>*>* rows, NSUInteger budget, NSUInteger* shownRows) {
    if (shownRows) *shownRows = 0;
    if (!rows.count) return @"";
    NSUInteger columns = 0;
    for (NSArray* row in rows) columns = MAX(columns, row.count);
    if (!columns) return @"";
    NSString* (^line)(NSArray*) = ^NSString*(NSArray* row) {
        NSMutableArray* cells = [NSMutableArray array];
        for (NSUInteger i = 0; i < columns; i++) [cells addObject:SPDFMarkdownCell(i < row.count ? row[i] : @"")];
        return [NSString stringWithFormat:@"| %@ |\n", [cells componentsJoinedByString:@" | "]];
    };
    NSMutableArray* rule = [NSMutableArray array];
    for (NSUInteger i = 0; i < columns; i++) [rule addObject:@"---"];
    NSMutableString* table = [NSMutableString stringWithString:line(rows[0])];
    [table appendFormat:@"| %@ |\n", [rule componentsJoinedByString:@" | "]];
    if (table.length > budget) return @"";
    for (NSUInteger i = 1; i < rows.count; i++) {
        NSString* next = line(rows[i]);
        if (table.length + next.length > budget) break;
        [table appendString:next];
        if (shownRows) ++*shownRows;
    }
    return table;
}

static BOOL SPDFIsPNG(NSData* data) {
    static const uint8_t signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    return data.length > 8 && memcmp(data.bytes, signature, 8) == 0;
}

static NSString* SPDFShowImage(NSData* data, NSString* name, id<SPDFMacAIActivityReporting> activity) {
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"spdf-python-%@.png", NSUUID.UUID.UUIDString]];
    if (![data writeToFile:path options:NSDataWritingWithoutOverwriting error:nil]) return nil;
    NSString* entry = [activity addImageAtPath:path caption:name options:SPDFMacAIActivityOptionsNone];
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return entry;
}

// NO for a table with no rows, which then comes back as a plain (empty) file.
static BOOL SPDFAddTable(NSMutableArray* tables, NSString* name, NSString* text, unichar separator,
                         id<SPDFMacAIActivityReporting> activity, BOOL requestOnly) {
    NSUInteger total = 0;
    NSArray* rows = SPDFMacAIPythonParseTable(text, separator, kSPDFTableRows + 1, kSPDFTableColumns, &total);
    if (!rows.count) return NO;
    NSUInteger dataRows = total ? total - 1 : 0;
    [tables addObject:@{@"name" : name, @"rows" : rows, @"row_count" : @(dataRows),
                        @"truncated" : @(dataRows + 1 > rows.count)}];
    NSUInteger shown = 0;
    NSArray* cardRows = [rows subarrayWithRange:NSMakeRange(0, MIN(rows.count, kSPDFCardRows + 1))];
    NSString* body = SPDFMacAIPythonMarkdownTable(cardRows, 7000, &shown);
    NSString* status = shown == dataRows ? [NSString stringWithFormat:@"%lu rows", (unsigned long)dataRows]
        : [NSString stringWithFormat:@"First %lu of %lu rows", (unsigned long)shown, (unsigned long)dataRows];
    NSMutableDictionary* card = [@{SPDFMacAIActivityTitleKey : name, SPDFMacAIActivityBodyKey : body,
        SPDFMacAIActivityCardKindKey : @"python.table", SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
        SPDFMacAIActivityStatusKey : status} mutableCopy];
    if (requestOnly) {
        card[SPDFMacAIActivityStoredNoticeKey] = SPDFMacAIPythonFriendsNotice;
        // The file name is the code's; on save it is replaced, so it cannot quote a friend (D4).
        card[SPDFMacAIActivityStoredTitleKey] = SPDFMacAIPythonStoredTableTitle;
    }
    [activity addCard:card options:requestOnly ? SPDFMacAIActivityRequestOnly : SPDFMacAIActivityOptionsNone
              handler:nil];
    return YES;
}

// Halves the largest text until the JSON fits, in the order the model can best do without: returned file text,
// table rows, then what went to stderr and stdout.
static void SPDFFitBudget(NSMutableDictionary* model) {
    for (int round = 0; round < 40; round++) {
        NSData* json = [NSJSONSerialization dataWithJSONObject:model options:0 error:nil];
        if (json.length <= SPDFMacAIPythonResultBudget) return;
        NSMutableArray* files = model[@"files"];
        NSUInteger longest = NSNotFound, length = 0;
        for (NSUInteger i = 0; i < files.count; i++)
            if ([files[i][@"text"] length] > length) { longest = i; length = [files[i][@"text"] length]; }
        if (longest != NSNotFound && length > 200) {
            NSMutableDictionary* file = [files[longest] mutableCopy];
            file[@"text"] = SPDFMacAIPythonClip(file[@"text"], length / 2);
            file[@"text_truncated"] = @YES;
            files[longest] = file;
            continue;
        }
        NSMutableArray* tables = model[@"tables"];
        NSUInteger widest = NSNotFound, rows = 0;
        for (NSUInteger i = 0; i < tables.count; i++)
            if ([tables[i][@"rows"] count] > rows) { widest = i; rows = [tables[i][@"rows"] count]; }
        if (widest != NSNotFound && rows > 2) {
            NSMutableDictionary* table = [tables[widest] mutableCopy];
            table[@"rows"] = [table[@"rows"] subarrayWithRange:NSMakeRange(0, rows / 2)];
            table[@"truncated"] = @YES;
            tables[widest] = table;
            continue;
        }
        NSString* key = [model[@"stderr"] length] > 2000 ? @"stderr" : @"stdout";
        model[key] = SPDFMacAIPythonClip(model[key], [model[key] length] / 2);
        model[[key stringByAppendingString:@"_truncated"]] = @YES;
    }
}

SPDFMacAIPythonPresentation* SPDFMacAIPythonPresent(NSDictionary* result, NSString* code,
                                                    id<SPDFMacAIActivityReporting> activity, BOOL requestOnly) {
    SPDFMacAIPythonPresentation* presentation = [SPDFMacAIPythonPresentation new];
    NSString* status = [result[@"status"] isKindOfClass:NSString.class] ? result[@"status"] : @"failed";
    BOOL completed = [status isEqual:@"completed"], stopped = [status isEqual:@"stopped"];
    presentation.state = completed ? SPDFMacAIActivityStateDone
        : stopped ? SPDFMacAIActivityStateStopped : SPDFMacAIActivityStateFailed;
    // Past tense once it has run, so a finished step folded into one line reads right (the web step does the same).
    presentation.title = completed ? @"Ran Python" : stopped ? @"Python run stopped" : @"Python run failed";
    presentation.status = SPDFMacAIPythonStatusLine(result);
    NSString* out = [result[@"stdout"] isKindOfClass:NSString.class] ? result[@"stdout"] : @"";
    NSString* err = [result[@"stderr"] isKindOfClass:NSString.class] ? result[@"stderr"] : @"";
    NSMutableDictionary* model = [@{@"status" : status, @"stdout" : out, @"stderr" : err} mutableCopy];
    for (NSString* key in @[ @"exit_code", @"seconds", @"stdout_truncated", @"stderr_truncated" ])
        if ([result[key] isKindOfClass:NSNumber.class]) model[key] = result[key];
    NSDictionary* limits = [result[@"limits"] isKindOfClass:NSDictionary.class] ? result[@"limits"] : @{};
    NSString* note = SPDFLimitNote(result[@"limit"], limits);
    if (note) model[@"limit"] = note;
    NSMutableArray* images = [NSMutableArray array], *tables = [NSMutableArray array], *files = [NSMutableArray array];
    NSUInteger shownImages = 0;
    for (NSDictionary* file in [result[@"files"] isKindOfClass:NSArray.class] ? result[@"files"] : @[]) {
        if (![file isKindOfClass:NSDictionary.class] || ![file[@"name"] isKindOfClass:NSString.class]) continue;
        NSString* name = file[@"name"], *extension = name.pathExtension.lowercaseString;
        NSData* data = [file[@"data"] isKindOfClass:NSString.class]
            ? [[NSData alloc] initWithBase64EncodedString:file[@"data"] options:0] : nil;
        NSString* text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (!data) {
            [files addObject:@{@"name" : name, @"size" : file[@"size"] ?: @0, @"returned" : @NO}];
        } else if ([extension isEqual:@"png"] && SPDFIsPNG(data)) {
            NSString* shown = nil;
            if (!requestOnly && activity && shownImages < kSPDFMaxImages) shown = SPDFShowImage(data, name, activity);
            if (shown) shownImages++;
            [images addObject:@{@"name" : name, @"shown_to_person" : @(shown != nil)}];
        } else if (text && ([extension isEqual:@"csv"] || [extension isEqual:@"tsv"]) &&
                   SPDFAddTable(tables, name, text, [extension isEqual:@"tsv"] ? '\t' : ',', activity, requestOnly)) {
            continue;
        } else if (text && [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]]
                               .location == NSNotFound) {
            [files addObject:@{@"name" : name, @"size" : @(data.length), @"text" : SPDFMacAIPythonClip(text, 20000)}];
        } else {
            [files addObject:@{@"name" : name, @"size" : @(data.length), @"returned" : @NO}];
        }
    }
    if (images.count) model[@"images"] = images;
    if (tables.count) model[@"tables"] = tables;
    if (files.count) model[@"files"] = files;
    if ([result[@"files_omitted"] unsignedIntegerValue]) model[@"files_not_listed"] = result[@"files_omitted"];
    if (shownImages)
        model[@"note"] = @"The PNG images marked shown_to_person are in the chat, where the person can save them.";
    else if (images.count && requestOnly)
        model[@"note"] = @"Images are not shown for requests that read Friends chats. Describe the result in words.";
    SPDFFitBudget(model);
    presentation.modelResult = model;
    // Three parts the chat shows each in its own way: the code in its code box, what it printed as plain text, and a
    // note in words. Kept apart, the output is never coloured as Python and the note never cut off at the box's edge.
    presentation.detail = SPDFMacAIPythonClip(code, 2500);
    presentation.output = SPDFMacAIPythonClip(out, kSPDFShownOutput);
    // A withheld chart leaves no image row, so the person would see nothing without this line (D2/D6).
    if (requestOnly && images.count && !shownImages) presentation.note = kSPDFFriendsChartsWithheld;
    return presentation;
}
