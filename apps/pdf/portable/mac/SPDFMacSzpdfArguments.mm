// szpdf's command line and its choice of reader process (SPDFMacSzpdf.h). Foundation only, no I/O beyond realpath.
// What each command takes comes from the command table (SPDFMacSzpdfHelp.mm), so help and parsing cannot disagree.
#import "SPDFMacSzpdf.h"
#import "SPDFMacSzpdfInternal.h"

#include <stdlib.h>
#include <string.h>

NSString* const SPDFMacSzpdfUsageCommandKey = @"command";

static NSError* Usage(NSString* problem, NSString* command) {
    NSMutableDictionary* info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = problem ?: @"";
    if (command) info[SPDFMacSzpdfUsageCommandKey] = command;
    return [NSError errorWithDomain:@"ShenzhenPDF.szpdf" code:2 userInfo:info];
}

BOOL SPDFMacIsSzpdfInvocation(const char* argv0) {
    if (!argv0) return NO;
    const char* slash = strrchr(argv0, '/');
    return strcmp(slash ? slash + 1 : argv0, "szpdf") == 0;
}

// Absolute, with the file's real path when it exists (the reader knows documents by their real paths: /private/tmp,
// not /tmp). A path that does not exist yet (a picture to write) gets its folder's real path.
static NSString* Absolute(NSString* path, NSString* directory) {
    NSString* absolute = path.isAbsolutePath ? path : [directory stringByAppendingPathComponent:path];
    char resolved[PATH_MAX];
    if (realpath(absolute.fileSystemRepresentation, resolved)) return @(resolved);
    NSString* folder = absolute.stringByDeletingLastPathComponent;
    if (realpath(folder.fileSystemRepresentation, resolved))
        return [@(resolved) stringByAppendingPathComponent:absolute.lastPathComponent];
    return absolute.stringByStandardizingPath;
}

static BOOL WholeNumber(NSString* text, long long low, long long high, long long* out) {
    NSScanner* scanner = [NSScanner scannerWithString:text ?: @""];
    long long value = 0;
    if (![scanner scanLongLong:&value] || !scanner.atEnd || value < low || value > high) return NO;
    *out = value;
    return YES;
}

static NSNumber* Decimal(NSString* text, double low, double high) {
    NSScanner* scanner = [NSScanner scannerWithString:text ?: @""];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.atEnd || value < low || value > high) return nil;
    return @(value);
}

static NSArray<NSNumber*>* Region(NSString* text) {
    NSArray* parts = [text componentsSeparatedByString:@","];
    if (parts.count != 4) return nil;
    NSMutableArray* numbers = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4; i++) {
        NSNumber* value = Decimal([parts[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], 0, 100000);
        if (!value || (i >= 2 && value.doubleValue <= 0)) return nil;
        [numbers addObject:value];
    }
    return numbers;
}

static NSArray* const kTwoWord = @[ @"comment", @"version" ];

NSDictionary* SPDFMacSzpdfParseArguments(NSArray<NSString*>* arguments, NSString* directory, NSError** error) {
    if ([arguments.firstObject isEqualToString:@"--version"] && arguments.count == 1) return @{@"command" : @"version-info"};
    BOOL help = NO;
    NSMutableArray<NSString*>* words = [NSMutableArray array];
    for (NSString* argument in arguments) {
        if ([argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]) help = YES;
        else if (![argument hasPrefix:@"--"]) [words addObject:argument];
    }
    // The command: one word, or two for comment and version ("comment add").
    NSString* name = words.firstObject;
    NSUInteger used = name ? 1 : 0;
    if (name && [kTwoWord containsObject:name] && words.count > 1 &&
        SPDFMacSzpdfCommandNamed([NSString stringWithFormat:@"%@ %@", name, words[1]])) {
        name = [NSString stringWithFormat:@"%@ %@", name, words[1]];
        used = 2;
    }
    NSDictionary* entry = name ? SPDFMacSzpdfCommandNamed(name) : nil;
    if ([name isEqualToString:@"help"]) {
        NSString* topic = words.count > 1 ? [[words subarrayWithRange:NSMakeRange(1, words.count - 1)]
                                                componentsJoinedByString:@" "]
                                          : nil;
        return topic ? @{@"command" : @"help", @"topic" : topic} : @{@"command" : @"help"};
    }
    if (help) return entry ? @{@"command" : @"help", @"topic" : name} : @{@"command" : @"help"};
    NSError* failure = nil;
    if (!name) failure = Usage(@"Name a command.", nil);
    else if (!entry)
        failure = Usage([kTwoWord containsObject:name]
                            ? [NSString stringWithFormat:@"%@ takes a second word: szpdf help lists them.", name]
                            : [NSString stringWithFormat:@"Unknown command %@.", name],
                        [kTwoWord containsObject:name] ? nil : nil);
    // Options, checked against the command's, and the words after the command.
    NSMutableDictionary* options = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* positional = [NSMutableArray array];
    NSArray *flags = entry[@"flags"] ?: @[], *valued = entry[@"valued"] ?: @[];
    NSUInteger skipped = 0;
    for (NSUInteger i = 0; i < arguments.count && !failure; i++) {
        NSString* argument = arguments[i];
        if ([argument isEqualToString:@"--"]) {
            [positional addObjectsFromArray:[arguments subarrayWithRange:NSMakeRange(i + 1, arguments.count - i - 1)]];
            break;
        }
        if ([argument isEqualToString:@"--json"]) continue;
        if ([flags containsObject:argument]) options[argument] = @YES;
        else if ([valued containsObject:argument] && i + 1 < arguments.count) options[argument] = arguments[++i];
        else if ([valued containsObject:argument])
            failure = Usage([NSString stringWithFormat:@"%@ needs a value.", argument], name);
        else if ([argument hasPrefix:@"--"])
            failure = Usage([NSString stringWithFormat:@"%@ does not apply to szpdf %@.", argument, name], name);
        else if (skipped < used) skipped++;
        else [positional addObject:argument];
    }
    if (failure) {
        if (error) *error = failure;
        return nil;
    }
    NSUInteger required = 0, allowed = 0;
    for (NSString* arg in entry[@"args"] ?: @[]) {
        allowed++;
        if (![arg hasSuffix:@"?"]) required++;
    }
    if (positional.count < required || positional.count > allowed) {
        NSString* problem = positional.count < required
                                ? [NSString stringWithFormat:@"szpdf %@ needs <%@>.", name,
                                                             [[entry[@"args"] subarrayWithRange:NSMakeRange(positional.count, required - positional.count)]
                                                                 componentsJoinedByString:@"> and <"]]
                                : [NSString stringWithFormat:@"Too many arguments for szpdf %@ (is a text with spaces "
                                                             @"missing its quotes?).", name];
        if (error) *error = Usage(problem, name);
        return nil;
    }
    NSMutableDictionary* command = [NSMutableDictionary dictionary];
    command[@"command"] = [name stringByReplacingOccurrencesOfString:@" " withString:@"-"];
    long long number = 0;
    NSString* (^check)(BOOL, NSString*) = ^NSString*(BOOL ok, NSString* problem) { return ok ? nil : problem; };
    NSString* problem = nil;
    NSArray* const pathFirst = @[ @"open", @"reload", @"headings", @"outline", @"find", @"export-page", @"export-pdf",
                                  @"comments", @"comment-add", @"comment-reply", @"comment-resolve", @"version-new",
                                  @"version-list", @"version-compare", @"check" ];
    NSString* verb = command[@"command"];
    if ([pathFirst containsObject:verb]) command[@"path"] = Absolute(positional[0], directory);
    if ([verb isEqualToString:@"outline"]) command[@"command"] = @"headings";
    if (options[@"--timeout"]) {
        problem = check(WholeNumber(options[@"--timeout"], 1, 86400, &number), @"--timeout takes whole seconds.");
        command[@"timeout"] = @(number);
    }
    if (options[@"--page"] && !problem) {
        problem = check(WholeNumber(options[@"--page"], 1, 1000000, &number), @"--page takes a page number from 1.");
        command[@"page"] = @(number);
    }
    if (options[@"--heading"] && !problem) {
        NSString* heading = [options[@"--heading"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        problem = check(heading.length > 0, @"--heading takes the heading's text.");
        command[@"heading"] = heading;
    }
    if (options[@"--scale"] && !problem) {
        command[@"scale"] = Decimal(options[@"--scale"], 0.1, 8) ?: @0;
        problem = check([command[@"scale"] doubleValue] > 0, @"--scale is a number from 0.1 to 8.");
    }
    if (options[@"--region"] && !problem) {
        command[@"region"] = Region(options[@"--region"]) ?: @[];
        problem = check([command[@"region"] count] == 4, @"--region is x,y,width,height in page points.");
    }
    if (options[@"--author"]) command[@"author"] = options[@"--author"];
    if (options[@"--front"] && options[@"--background"]) problem = @"Give --front or --background, not both.";
    command[@"front"] = @([options[@"--front"] boolValue]);
    command[@"wait"] = @([options[@"--wait"] boolValue]);
    if ([verb isEqualToString:@"open"]) {
        if (options[@"--page"] && options[@"--heading"]) problem = @"Give --page or --heading, not both.";
        command[@"reload"] = @([options[@"--reload"] boolValue]);
        command[@"timeout"] = command[@"timeout"] ?: @30;
    } else if ([verb isEqualToString:@"reload"]) {
        command[@"timeout"] = command[@"timeout"] ?: @30;
    } else if ([verb isEqualToString:@"close"]) {
        if (WholeNumber(positional[0], 1, INT32_MAX, &number)) command[@"windowId"] = @(number);
        else command[@"path"] = Absolute(positional[0], directory);
    } else if ([verb isEqualToString:@"screenshot"] || [verb isEqualToString:@"export-page"]) {
        BOOL page = [verb isEqualToString:@"export-page"];
        NSString* target = positional[0];
        if (page) {
            problem = problem ?: check(WholeNumber(positional[1], 1, 1000000, &number), @"The page is a number from 1.");
            command[@"page"] = @(number);
        }
        if (!page && WholeNumber(target, 1, INT32_MAX, &number)) command[@"windowId"] = @(number);
        else command[@"path"] = Absolute(target, directory);
        command[@"output"] = Absolute(positional[page ? 2 : 1], directory);
        if (![[command[@"output"] pathExtension].lowercaseString isEqualToString:@"png"])
            problem = problem ?: @"The picture's name must end in .png.";
        if (!page && command[@"path"] && !command[@"page"]) problem = problem ?: @"A document's picture needs --page N.";
        if ((command[@"region"] || command[@"scale"]) && !command[@"page"])
            problem = problem ?: @"--region and --scale apply to a page: add --page N.";
        command[@"command"] = @"screenshot";
    } else if ([verb isEqualToString:@"export-pdf"]) {
        command[@"output"] = Absolute(positional[1], directory);
        if (![[command[@"output"] pathExtension].lowercaseString isEqualToString:@"pdf"])
            problem = problem ?: @"The output's name must end in .pdf.";
    } else if ([verb isEqualToString:@"find"]) {
        command[@"text"] = positional[1];
        command[@"case"] = @([options[@"--case"] boolValue]);
        number = 50;
        if (options[@"--limit"]) problem = problem ?: check(WholeNumber(options[@"--limit"], 1, 100000, &number),
                                                            @"--limit takes a number from 1.");
        command[@"limit"] = @(number);
        if (![positional[1] length]) problem = problem ?: @"Give the text to find.";
    } else if ([verb isEqualToString:@"comments"]) {
        if (options[@"--version"]) {
            problem = problem ?: check(WholeNumber(options[@"--version"], 1, 100000, &number),
                                       @"--version takes a version number, as szpdf version list shows it.");
            command[@"version"] = @(number);
        }
        command[@"json"] = @([arguments containsObject:@"--json"]);
        command[@"waitNew"] = @([options[@"--wait-new"] boolValue]);
        if ((options[@"--since"] || options[@"--timeout"]) && !options[@"--wait-new"])
            problem = problem ?: @"--since and --timeout go with --wait-new.";
        if (options[@"--since"]) {
            command[@"since"] = options[@"--since"];
            problem = problem ?: check(SPDFMacSzpdfParseISODate(options[@"--since"]) != nil,
                                       @"--since takes an ISO 8601 time, such as 2026-11-03T05:40:28+08:00.");
        }
        if (options[@"--wait-new"] && command[@"version"]) problem = problem ?: @"--wait-new watches the current version.";
        command[@"timeout"] = command[@"timeout"] ?: @600;
    } else if ([verb isEqualToString:@"comment-add"]) {
        NSUInteger anchors = 0;
        for (NSString* key in @[ @"--line", @"--quote", @"--heading", @"--page" ]) anchors += options[key] != nil;
        if (anchors != 1) problem = problem ?: @"Give one of --line, --quote, --heading or --page.";
        if (options[@"--line"]) {
            problem = problem ?: check(WholeNumber(options[@"--line"], 1, 10000000, &number), @"--line takes a line number from 1.");
            command[@"line"] = @(number);
        }
        if (options[@"--quote"]) command[@"quote"] = options[@"--quote"];
        command[@"text"] = positional[1];
        if (![[positional[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length])
            problem = problem ?: @"The comment needs text.";
    } else if ([verb isEqualToString:@"comment-reply"]) {
        command[@"id"] = positional[1];
        command[@"text"] = positional[2];
        if (![[positional[2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length])
            problem = problem ?: @"The reply needs text.";
    } else if ([verb isEqualToString:@"comment-resolve"]) {
        command[@"id"] = positional[1];
        command[@"resolved"] = @(![options[@"--reopen"] boolValue]);
    } else if ([verb isEqualToString:@"version-new"]) {
        command[@"carry"] = options[@"--carry"] ?: @"open";
        if (![@[ @"open", @"all", @"none" ] containsObject:command[@"carry"]]) problem = problem ?: @"--carry is open, all or none.";
    } else if ([verb isEqualToString:@"version-compare"]) {
        long long older = 0, newer = 0;
        if (!WholeNumber(positional[1], 1, 100000, &older) || !WholeNumber(positional[2], 1, 100000, &newer) || older == newer)
            problem = problem ?: @"Name two different version numbers, as szpdf version list shows them.";
        command[@"older"] = @(older);
        command[@"newer"] = @(newer);
    } else if ([verb isEqualToString:@"features"]) {
        command[@"format"] = options[@"--format"] ?: @"all";
        if (![@[ @"md", @"pdf", @"all" ] containsObject:command[@"format"]]) problem = problem ?: @"--format is md, pdf or all.";
    } else if ([verb isEqualToString:@"schema"] && positional.count) {
        command[@"topic"] = positional[0];
    }
    if (problem) {
        if (error) *error = Usage(problem, name);
        return nil;
    }
    return command;
}

pid_t SPDFMacSzpdfChooseProcess(NSDictionary<NSNumber*, NSDictionary*>* states, NSString* path) {
    NSArray<NSNumber*>* pids = [states.allKeys sortedArrayUsingSelector:@selector(compare:)];
    pid_t showing = 0, active = 0, oldest = 0;
    for (NSNumber* pid in pids) {
        NSDictionary* state = states[pid];
        if ([state[@"quitting"] boolValue] || state[@"error"]) continue;
        if (!oldest) oldest = pid.intValue;
        if (!active && [state[@"active"] boolValue]) active = pid.intValue;
        for (NSDictionary* window in state[@"windows"])
            for (NSDictionary* document in window[@"documents"])
                if (!showing && [document[@"path"] isEqual:path]) showing = pid.intValue;
    }
    return showing ?: active ?: oldest;
}
