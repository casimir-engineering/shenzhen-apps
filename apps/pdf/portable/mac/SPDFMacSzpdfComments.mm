// szpdf's version and comment commands (SPDFMacSzpdf.h), which work on the files whether or not the app runs, and ask
// a running reader to redraw or to watch.
#import "SPDFMacAgentComments.h"
#import "SPDFMacCommentActions.h"
#import "SPDFMacDocumentVersions.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacStateDirectory.h"
#import "SPDFMacSzpdf.h"
#import "SPDFMacSzpdfHeadingMatch.h"
#import "SPDFMacSzpdfInternal.h"

id spdf_state_object_from_yaml_data(NSData* data);  // SPDFMacLaunchPrerenderPrivate.h

static int Finish(NSDictionary* answer) { return SPDFMacSzpdfFinish(answer); }
static NSDictionary* Readers(void) { return SPDFMacSzpdfReaders(); }
static NSDictionary* Send(pid_t pid, NSDictionary* request, NSTimeInterval timeout) {
    return SPDFMacSzpdfSend(pid, request, timeout);
}
static pid_t Reader(NSString* path, BOOL front, NSTimeInterval timeout, NSDictionary** failure) {
    return SPDFMacSzpdfReader(path, front, timeout, failure);
}
static NSDictionary* Failure(NSString* code, NSString* message) { return SPDFMacSzpdfFailure(code, message, nil); }
static NSDictionary* FromError(NSError* error, NSString* fallback) {
    return Failure(error.userInfo[SPDFMacAgentCommentsErrorCodeKey] ?: @"failed", error.localizedDescription ?: fallback);
}

#pragma mark - Versions

static SPDFDocumentVersionCarry CarryNamed(NSString* name) {
    return [name isEqual:@"all"] ? SPDFDocumentVersionCarryAll
           : [name isEqual:@"none"] ? SPDFDocumentVersionCarryNone : SPDFDocumentVersionCarryOpen;
}

// The file holding version `number` of the document `path` belongs to, or nil.
static NSString* VersionPath(NSString* path, NSInteger number) {
    for (SPDFDocumentVersion* version in SPDFDocumentVersionsList(path))
        if (version.number == number) return version.path;
    return nil;
}

// version new and list go through the reader when one runs (it updates the tabs showing the document), else straight to
// the files; compare computes the changed blocks here and opens the comparison window, starting the app if needed.
int SPDFMacSzpdfVersions(NSDictionary* command) {
    NSString* path = command[@"path"];
    NSString* verb = command[@"command"];
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!exists || !SPDFDocumentVersionsSupportsPath(path))
        return Finish(exists ? Failure(@"unsupported", @"Versions are kept for Markdown documents and PDFs.")
                             : Failure(@"not-found", [NSString stringWithFormat:@"No document at %@.", path]));
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    NSString* action = [verb substringFromIndex:8];
    NSMutableDictionary* request = [@{@"command" : @"version", @"action" : action, @"path" : current} mutableCopy];
    if ([action isEqual:@"compare"]) {
        NSString *older = VersionPath(current, [command[@"older"] integerValue]),
                 *newer = VersionPath(current, [command[@"newer"] integerValue]);
        if (!older || !newer)
            return Finish(Failure(@"version-not-found", [NSString stringWithFormat:@"There is no v%@ and v%@ to compare; "
                                                                                   @"see szpdf version list.",
                                                                                   command[@"older"], command[@"newer"]]));
        if ([command[@"older"] integerValue] > [command[@"newer"] integerValue]) {
            NSString* swap = older;
            older = newer;
            newer = swap;
        }
        NSDictionary* failure = nil;
        NSArray* blocks = SPDFMacSzpdfVersionBlocks(older, newer, &failure);
        if (!blocks) return Finish(failure);
        pid_t target = Reader(current, [command[@"front"] boolValue], 30, &failure);
        NSMutableDictionary* answer = [@{@"opened" : @NO} mutableCopy];
        if (target) {
            [request addEntriesFromDictionary:@{@"older" : command[@"older"], @"newer" : command[@"newer"],
                                                @"front" : command[@"front"], @"wait" : command[@"wait"]}];
            answer = [Send(target, request, 70) mutableCopy];
        } else {
            answer[@"windowError"] = failure[@"error"][@"message"] ?: @"ShenzhenPDF did not answer.";
        }
        answer[@"blocks"] = blocks;
        answer[@"olderPath"] = older;
        answer[@"newerPath"] = newer;
        if (!answer[@"changes"]) answer[@"changes"] = @(blocks.count);
        return Finish(answer);
    }
    pid_t target = SPDFMacSzpdfChooseProcess(Readers(), current);
    if (target) {
        if ([action isEqual:@"new"]) request[@"carry"] = command[@"carry"];
        NSMutableDictionary* answer = [Send(target, request, 30) mutableCopy];
        answer[@"via"] = @"app";
        return Finish(answer);
    }
    if ([action isEqual:@"list"])
        return Finish(@{@"path" : current, @"via" : @"files",
                        @"versions" : [SPDFDocumentVersionsList(current) valueForKey:@"dictionaryRepresentation"]});
    NSError* error = nil;
    SPDFDocumentVersion* version = SPDFDocumentVersionsCreate(current, CarryNamed(command[@"carry"]), &error);
    if (!version) return Finish(Failure(@"failed", error.localizedDescription ?: @"The version could not be made."));
    return Finish(@{@"path" : current, @"via" : @"files", @"version" : version.dictionaryRepresentation});
}

#pragma mark - Comments

static void PrintCommentsText(NSDictionary* listing) {
    NSArray* comments = listing[@"comments"];
    if (!comments.count) printf("No comments on %s.\n", [listing[@"path"] lastPathComponent].UTF8String);
    for (NSDictionary* comment in comments) {
        NSString* where = comment[@"page"] ? [NSString stringWithFormat:@"page %@", comment[@"page"]]
                          : [comment[@"line"] isKindOfClass:NSNumber.class]
                              ? [NSString stringWithFormat:@"line %@", comment[@"line"]]
                              : @"unplaced";
        printf("%s  %s  %s  %s\n", [comment[@"id"] UTF8String], where.UTF8String, [comment[@"status"] UTF8String],
               [comment[@"author"] UTF8String]);
        if ([comment[@"quote"] length]) printf("  > %s\n", [comment[@"quote"] UTF8String]);
        if ([comment[@"text"] length]) printf("  %s\n", [comment[@"text"] UTF8String]);
        for (NSDictionary* reply in comment[@"replies"])
            printf("    - %s: %s\n", [reply[@"author"] UTF8String], [reply[@"text"] UTF8String]);
    }
}

// The name ShenzhenPDF signs comments with: the one its Settings (and the pencil on a comment) set, else the Mac's.
static NSString* AppAuthor(void) {
    NSString* file = [SPDFMacStateDirectoryPath() stringByAppendingPathComponent:@"settings.yaml"];
    NSData* data = [NSData dataWithContentsOfFile:file];
    id settings = data ? spdf_state_object_from_yaml_data(data) : nil;
    id stored = [settings isKindOfClass:NSDictionary.class] ? settings[@"commentAuthor"] : nil;
    NSString* name = [stored isKindOfClass:NSString.class]
                         ? [stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                         : nil;
    return name.length ? name : SPDFDefaultCommentAuthor();
}

static NSUInteger RefreshReaders(NSString* path) {
    NSUInteger refreshed = 0;
    NSDictionary* readers = Readers();
    for (NSNumber* pid in readers)
        refreshed += [Send(pid.intValue, @{@"command" : @"comments-changed", @"path" : path}, 5)[@"refreshed"]
                         unsignedIntegerValue];
    return refreshed;
}

static int WaitForComments(NSDictionary* command) {
    NSString* path = command[@"path"];
    NSTimeInterval timeout = [command[@"timeout"] doubleValue];
    NSMutableDictionary* request = [@{@"command" : @"watch-comments", @"path" : path, @"timeout" : command[@"timeout"]} mutableCopy];
    if (command[@"since"]) request[@"since"] = command[@"since"];
    NSDictionary* readers = Readers();
    pid_t target = SPDFMacSzpdfChooseProcess(readers, path);
    // The app watches the files when it runs; else this process does, the same way (file system events).
    if (target) return Finish(Send(target, request, timeout + 15));
    __block NSDictionary* answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    SPDFMacSzpdfWatchComments(path, command[@"since"] ? SPDFMacSzpdfParseISODate(command[@"since"]) : nil, timeout,
                              dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(NSDictionary* result) {
                                answer = result;
                                dispatch_semaphore_signal(done);
                              });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return Finish(answer);
}

static int AddComment(NSDictionary* command) {
    NSString* path = command[@"path"];
    NSString* author = command[@"author"] ?: NSProcessInfo.processInfo.environment[@"SZPDF_AUTHOR"] ?: AppAuthor();
    NSError* error = nil;
    NSDictionary* result = nil;
    if ([path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        if (command[@"line"]) return Finish(Failure(@"unsupported", @"A PDF has no source lines: use --page, --quote or --heading."));
        NSMutableDictionary* where = [NSMutableDictionary dictionary];
        if (command[@"quote"]) where[@"quote"] = command[@"quote"];
        else if (command[@"page"]) where[@"page"] = command[@"page"];
        else {
            NSDictionary* failure = nil;
            SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument documentAtPath:path failure:&failure];
            if (!document) return Finish(failure);
            NSDictionary* match = SPDFMacSzpdfMatchHeading(document.headings, command[@"heading"]);
            if (!match[@"index"]) return Finish(match);
            where[@"page"] = document.headings[[match[@"index"] unsignedIntegerValue]][@"page"];
        }
        result = SPDFMacAgentAddPDFComment(path, where, command[@"text"], author, &error);
    } else {
        if (command[@"page"]) return Finish(Failure(@"unsupported", @"--page is for PDFs; use --line, --quote or --heading."));
        NSDictionary* failure = nil;
        SPDFMacSzpdfDocument* document = [SPDFMacSzpdfDocument documentAtPath:path failure:&failure];
        if (!document) return Finish(failure);
        SPDFMarkdownComment* comment = [document commentAt:command failure:&failure];
        if (!comment) return Finish(failure);
        comment.author = author;
        comment.text = command[@"text"];
        comment.date = NSDate.date;
        result = SPDFMacAgentAddMarkdownComment(path, comment, &error);
    }
    if (!result) return Finish(FromError(error, @"The comment could not be added."));
    return Finish(@{@"path" : path, @"comment" : result, @"readersRefreshed" : @(RefreshReaders(path))});
}

int SPDFMacSzpdfComments(NSDictionary* command) {
    NSError* error = nil;
    NSString* path = command[@"path"];
    NSString* author = command[@"author"] ?: NSProcessInfo.processInfo.environment[@"SZPDF_AUTHOR"] ?: @"Agent";
    NSDictionary* result = nil;
    if ([command[@"command"] isEqual:@"comment-add"]) return AddComment(command);
    if ([command[@"command"] isEqual:@"comments"]) {
        if ([command[@"waitNew"] boolValue]) return WaitForComments(command);
        if (command[@"version"]) {
            NSString* versionPath = VersionPath(path, [command[@"version"] integerValue]);
            if (!versionPath)
                return Finish(Failure(@"version-not-found", [NSString stringWithFormat:@"There is no v%@ of this document; "
                                                                                       @"see szpdf version list.",
                                                                                       command[@"version"]]));
            path = versionPath;
        }
        result = SPDFMacAgentListComments(path, &error);
        if (result && command[@"version"]) {
            NSMutableDictionary* stamped = [result mutableCopy];
            stamped[@"version"] = command[@"version"];
            result = stamped;
        }
        if (result && ![command[@"json"] boolValue]) {
            PrintCommentsText(result);
            return 0;
        }
        return Finish(result ?: FromError(error, @"The comments could not be read."));
    }
    if ([command[@"command"] isEqual:@"comment-reply"])
        result = SPDFMacAgentReplyToComment(path, command[@"id"], command[@"text"], author, &error);
    else result = SPDFMacAgentResolveComment(path, command[@"id"], [command[@"resolved"] boolValue], author, &error);
    if (!result) return Finish(FromError(error, @"The comment could not be changed."));
    // Readers showing the document redraw its comments now rather than when next looked at.
    return Finish(@{@"path" : path, @"comment" : result, @"readersRefreshed" : @(RefreshReaders(path))});
}
