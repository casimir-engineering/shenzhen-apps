// szpdf's command line and its choice of reader process (SPDFMacSzpdf.h). Foundation only, no I/O beyond realpath.
#import "SPDFMacSzpdf.h"

#include <stdlib.h>
#include <string.h>

static NSString* const kUsage =
    @"usage: szpdf open <file> [--page N | --heading TEXT] [--front] [--wait] [--timeout SECONDS]\n"
    @"       szpdf state\n"
    @"       szpdf screenshot <windowId> <out.png>\n"
    @"       szpdf comments <file> [--json] [--version N]\n"
    @"       szpdf comment reply <file> <id> TEXT [--author NAME]\n"
    @"       szpdf comment resolve <file> <id> [--reopen] [--author NAME]\n"
    @"       szpdf version new <file> [--carry open|all|none]\n"
    @"       szpdf version list <file>\n"
    @"       szpdf version compare <file> <older> <newer> [--background | --front]";

static NSError* Usage(NSString* problem) {
    NSString* message = problem ? [NSString stringWithFormat:@"%@\n%@", problem, kUsage] : kUsage;
    return [NSError errorWithDomain:@"ShenzhenPDF.szpdf" code:2 userInfo:@{NSLocalizedDescriptionKey : message}];
}

BOOL SPDFMacIsSzpdfInvocation(const char* argv0) {
    if (!argv0) return NO;
    const char* slash = strrchr(argv0, '/');
    return strcmp(slash ? slash + 1 : argv0, "szpdf") == 0;
}

// Absolute, with the file's real path when it exists (the reader knows documents by their real paths: /private/tmp,
// not /tmp).
static NSString* Absolute(NSString* path, NSString* directory) {
    NSString* absolute = path.isAbsolutePath ? path : [directory stringByAppendingPathComponent:path];
    char resolved[PATH_MAX];
    if (realpath(absolute.fileSystemRepresentation, resolved)) return @(resolved);
    return absolute.stringByStandardizingPath;
}

static BOOL WholeNumber(NSString* text, long long low, long long high, long long* out) {
    NSScanner* scanner = [NSScanner scannerWithString:text ?: @""];
    long long value = 0;
    if (![scanner scanLongLong:&value] || !scanner.atEnd || value < low || value > high) return NO;
    *out = value;
    return YES;
}

NSDictionary* SPDFMacSzpdfParseArguments(NSArray<NSString*>* arguments, NSString* directory, NSError** error) {
    NSMutableArray<NSString*>* positional = [NSMutableArray array];
    NSMutableDictionary* options = [NSMutableDictionary dictionary];
    NSSet* flags = [NSSet setWithArray:@[ @"--front", @"--background", @"--wait", @"--json", @"--reopen" ]];
    NSSet* valued = [NSSet setWithArray:@[ @"--page", @"--heading", @"--timeout", @"--author", @"--carry", @"--version" ]];
    NSError* failure = nil;
    for (NSUInteger i = 0; i < arguments.count && !failure; i++) {
        NSString* argument = arguments[i];
        if ([argument isEqualToString:@"--"]) {
            [positional addObjectsFromArray:[arguments subarrayWithRange:NSMakeRange(i + 1, arguments.count - i - 1)]];
            break;
        }
        if ([flags containsObject:argument]) options[argument] = @YES;
        else if ([valued containsObject:argument] && i + 1 < arguments.count) options[argument] = arguments[++i];
        else if ([valued containsObject:argument]) failure = Usage([NSString stringWithFormat:@"%@ needs a value.", argument]);
        else if ([argument hasPrefix:@"--"] || [argument isEqualToString:@"-h"])
            failure = [argument isEqualToString:@"--help"] || [argument isEqualToString:@"-h"]
                          ? Usage(nil)
                          : Usage([NSString stringWithFormat:@"Unknown option %@.", argument]);
        else [positional addObject:argument];
    }
    NSString* verb = positional.firstObject;
    NSMutableDictionary* command = [NSMutableDictionary dictionary];
    NSSet* allowed = [NSSet set];
    if (failure) {
    } else if ([verb isEqualToString:@"open"] && positional.count == 2) {
        allowed = [NSSet setWithArray:@[ @"--page", @"--heading", @"--front", @"--background", @"--wait", @"--timeout" ]];
        command[@"command"] = @"open";
        command[@"path"] = Absolute(positional[1], directory);
        long long number = 0;
        if (options[@"--page"] && !WholeNumber(options[@"--page"], 1, 1000000, &number))
            failure = Usage(@"--page takes a page number from 1.");
        else if (options[@"--page"]) command[@"page"] = @(number);
        if (options[@"--page"] && options[@"--heading"]) failure = Usage(@"Give --page or --heading, not both.");
        if ([options[@"--heading"] length]) command[@"heading"] = options[@"--heading"];
        else if (options[@"--heading"]) failure = Usage(@"--heading takes the heading's text.");
        if (options[@"--front"] && options[@"--background"]) failure = Usage(@"Give --front or --background, not both.");
        command[@"front"] = @([options[@"--front"] boolValue]);
        command[@"wait"] = @([options[@"--wait"] boolValue]);
        if (options[@"--timeout"] && !WholeNumber(options[@"--timeout"], 1, 600, &number))
            failure = Usage(@"--timeout takes whole seconds, from 1 to 600.");
        command[@"timeout"] = @(options[@"--timeout"] ? number : 30);
    } else if ([verb isEqualToString:@"state"] && positional.count == 1) {
        command[@"command"] = @"state";
    } else if ([verb isEqualToString:@"screenshot"] && positional.count == 3) {
        long long number = 0;
        if (!WholeNumber(positional[1], 1, INT32_MAX, &number)) failure = Usage(@"The window id is a number from `szpdf state`.");
        NSString* output = Absolute(positional[2], directory);
        if (![output.pathExtension.lowercaseString isEqualToString:@"png"]) failure = Usage(@"The picture's name must end in .png.");
        command[@"command"] = @"screenshot";
        command[@"windowId"] = @(number);
        command[@"output"] = output;
    } else if ([verb isEqualToString:@"comments"] && positional.count == 2) {
        allowed = [NSSet setWithArray:@[ @"--json", @"--version" ]];
        command[@"command"] = @"comments";
        command[@"path"] = Absolute(positional[1], directory);
        command[@"json"] = @([options[@"--json"] boolValue]);
        long long number = 0;
        if (options[@"--version"] && !WholeNumber(options[@"--version"], 1, 100000, &number))
            failure = Usage(@"--version takes a version number, as `szpdf version list` shows it.");
        else if (options[@"--version"]) command[@"version"] = @(number);
    } else if ([verb isEqualToString:@"version"] && positional.count == 3 &&
               [@[ @"new", @"list" ] containsObject:positional[1]]) {
        allowed = [positional[1] isEqualToString:@"new"] ? [NSSet setWithObject:@"--carry"] : [NSSet set];
        command[@"command"] = [@"version-" stringByAppendingString:positional[1]];
        command[@"path"] = Absolute(positional[2], directory);
        command[@"carry"] = options[@"--carry"] ?: @"open";
        if (![@[ @"open", @"all", @"none" ] containsObject:command[@"carry"]])
            failure = Usage(@"--carry is open, all or none.");
    } else if ([verb isEqualToString:@"version"] && positional.count == 5 && [positional[1] isEqualToString:@"compare"]) {
        allowed = [NSSet setWithArray:@[ @"--background", @"--front" ]];
        command[@"command"] = @"version-compare";
        command[@"path"] = Absolute(positional[2], directory);
        long long older = 0, newer = 0;
        if (!WholeNumber(positional[3], 1, 100000, &older) || !WholeNumber(positional[4], 1, 100000, &newer) ||
            older == newer)
            failure = Usage(@"Name two different version numbers, as `szpdf version list` shows them.");
        if (options[@"--front"] && options[@"--background"]) failure = Usage(@"Give --front or --background, not both.");
        command[@"older"] = @(older);
        command[@"newer"] = @(newer);
        command[@"front"] = @([options[@"--front"] boolValue]);
    } else if ([verb isEqualToString:@"comment"] && positional.count == 5 && [positional[1] isEqualToString:@"reply"]) {
        allowed = [NSSet setWithObject:@"--author"];
        command[@"command"] = @"comment-reply";
        command[@"path"] = Absolute(positional[2], directory);
        command[@"id"] = positional[3];
        command[@"text"] = positional[4];
        if (![positional[4] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
            failure = Usage(@"The reply needs text.");
    } else if ([verb isEqualToString:@"comment"] && positional.count == 4 && [positional[1] isEqualToString:@"resolve"]) {
        allowed = [NSSet setWithArray:@[ @"--author", @"--reopen" ]];
        command[@"command"] = @"comment-resolve";
        command[@"path"] = Absolute(positional[2], directory);
        command[@"id"] = positional[3];
        command[@"resolved"] = @(![options[@"--reopen"] boolValue]);
    } else {
        failure = Usage(verb ? [NSString stringWithFormat:@"Unknown or incomplete command: %@.", verb] : nil);
    }
    for (NSString* option in failure ? @[] : options.allKeys)
        if (![allowed containsObject:option])
            failure = Usage([NSString stringWithFormat:@"%@ does not apply to %@.", option, verb]);
    if (!failure && options[@"--author"]) command[@"author"] = options[@"--author"];
    if (failure) {
        if (error) *error = failure;
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
