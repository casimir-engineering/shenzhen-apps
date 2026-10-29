// The launch probe's quit-and-relaunch round (PROBE_MODE=integrity): checks that the launch restored exactly what the
// previous round left, makes the edits a person makes, then quits at once with Cmd+Q -- with no wait for anything --
// so the next round can check that every change is there. Driven by mac/tests/launch/run-quit-performance.py.
//
//   PROBE_ROUND   this round's number (1-based)
//   PROBE_RECORD  folder shared by the rounds: expected-<n>.json is what round n left; this round writes
//                 restored-<n>.json (what it found, and the problems), session-<n>.yaml (the session as restored,
//                 saved before editing) and expected-<n>.json
//
// Every round: another tab, another page, a comment on it (the reader's own Add Comment, its text field answered).
// Some rounds also: rotate the page, rename a document on disk as Rename does, give a tab a display name, comment a
// read-only document (it moves to a writable copy in the app's storage, unasked), open an untitled pasted image.
// Comments and rotations are read back from the files with PDFKit, which shares no code with the reader.

#import <Cocoa/Cocoa.h>
#import <PDFKit/PDFKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <sys/stat.h>

static id Ivar_(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}
static void* IvarAddress(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? (uint8_t*)(__bridge void*)object + ivar_getOffset(ivar) : NULL;
}
static NSInteger IvarInteger(id object, const char* name) {
    NSInteger* value = (NSInteger*)IvarAddress(object, name);
    return value ? *value : -1;
}
static void Pump(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static void WaitLoaded(id reader) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:10];
    do Pump(0.02);
    while ((!*(void**)IvarAddress(reader, "_doc") || [Ivar_(reader, "_renderQueue") operationCount]) &&
           until.timeIntervalSinceNow > 0);
}
static void Call(id target, NSString* selector, id argument) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(selector), argument);
}

static NSString* gCommentText;
static NSString* AnswerPrompt(id, SEL, NSString*) { return gCommentText; }

// The test's own folder (documents, state, records) is an ordinary folder, wherever the worktree is: from /tmp every
// document would count as "in a temporary folder", go to a writable copy that is in a temporary folder too, and no
// edit could be kept. Every other temporary location is still one.
static IMP gTemporaryLocation;
static NSString* gWorkFolder;
static BOOL TemporaryOutsideTest(id reader, SEL selector, NSString* path) {
    NSString* resolved = path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (gWorkFolder.length && [resolved hasPrefix:gWorkFolder]) return NO;
    return ((BOOL (*)(id, SEL, NSString*))gTemporaryLocation)(reader, selector, path);
}

static NSDictionary* LiveState(id reader) {
    NSMutableArray* tabs = [NSMutableArray array];
    for (id tab in Ivar_(reader, "_tabs")) {
        id group = [tab valueForKey:@"group"];
        [tabs addObject:@{
            @"path" : [tab valueForKey:@"path"] ?: @"",
            @"displayName" : [tab valueForKey:@"displayName"] ?: @"",
            @"group" : [group valueForKey:@"identifier"] ?: @"",
            @"groupName" : [group valueForKey:@"name"] ?: @"",
            @"collapsed" : group ? [group valueForKey:@"collapsed"] : @NO,
        }];
    }
    return @{@"tabs" : tabs, @"selected" : @(IvarInteger(reader, "_selectedTabIndex")),
             @"page" : @(IvarInteger(reader, "_pageIndex"))};
}

// Comment texts and the first rotated page's rotation, read by PDFKit.
static NSDictionary* FileFacts(NSString* path) {
    PDFDocument* document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:path]];
    NSMutableArray* comments = [NSMutableArray array];
    NSMutableDictionary* rotations = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < document.pageCount; i++) {
        PDFPage* page = [document pageAtIndex:i];
        if (page.rotation) rotations[[NSString stringWithFormat:@"%lu", (unsigned long)i]] = @(page.rotation);
        for (PDFAnnotation* annotation in page.annotations)
            if ([annotation.contents hasPrefix:@"Round "]) [comments addObject:annotation.contents];
    }
    return @{@"exists" : @(document != nil), @"comments" : comments, @"rotations" : rotations};
}

static NSMutableArray* gProblems;
static void Problem(NSString* format, ...) NS_FORMAT_FUNCTION(1, 2);
static void Problem(NSString* format, ...) {
    va_list args;
    va_start(args, format);
    [gProblems addObject:[[NSString alloc] initWithFormat:format arguments:args]];
    va_end(args);
}

// What the previous round left, against what this launch restored.
static NSMutableDictionary* Verify(NSDictionary* expected, NSDictionary* live) {
    NSMutableDictionary* edits = [expected[@"edits"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (!expected) return edits;
    for (NSString* key in @[ @"selected", @"page" ])
        if (![expected[key] isEqual:live[key]]) Problem(@"%@ restored as %@, left as %@", key, live[key], expected[key]);
    NSArray* want = expected[@"tabs"], *got = live[@"tabs"];
    if (want.count != got.count) Problem(@"%lu tabs restored, %lu left", (unsigned long)got.count, (unsigned long)want.count);
    for (NSUInteger i = 0; i < MIN(want.count, got.count); i++)
        if (![want[i] isEqual:got[i]]) Problem(@"tab %lu restored as %@, left as %@", (unsigned long)i, got[i], want[i]);
    for (NSString* path in edits) {
        NSDictionary* facts = FileFacts(path), *edit = edits[path];
        if (![facts[@"exists"] boolValue]) { Problem(@"%@ is gone", path); continue; }
        for (NSString* comment in edit[@"comments"])
            if (![facts[@"comments"] containsObject:comment]) Problem(@"%@ lost comment \"%@\"", path.lastPathComponent, comment);
        if (![edit[@"rotations"] ?: @{} isEqual:facts[@"rotations"]])
            Problem(@"%@ rotations %@, expected %@", path.lastPathComponent, facts[@"rotations"], edit[@"rotations"]);
    }
    for (NSString* path in expected[@"pastedImages"])
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) Problem(@"pasted image %@ is gone", path);
    return edits;
}

static NSMutableDictionary* EditFor(NSMutableDictionary* edits, NSString* path) {
    NSMutableDictionary* edit = [edits[path] mutableCopy] ?: [@{@"comments" : @[], @"rotations" : @{}} mutableCopy];
    edits[path] = edit;
    return edit;
}

void SPDFProbeRunIntegrityRound(id reader) {
    long round = atol(getenv("PROBE_ROUND") ?: "1");
    NSString* record = [NSString stringWithUTF8String:getenv("PROBE_RECORD") ?: "."];
    NSString* state = [NSString stringWithUTF8String:getenv("SPDF_STATE_DIR")];
    gProblems = [NSMutableArray array];
    NSString* previous = [record stringByAppendingPathComponent:[NSString stringWithFormat:@"expected-%ld.json", round - 1]];
    NSDictionary* expected = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:previous] ?: NSData.data
                                                             options:0 error:nil];
    NSDictionary* restored = LiveState(reader);
    NSMutableDictionary* edits = Verify(expected, restored);
    NSMutableArray* pasted = [expected[@"pastedImages"] mutableCopy] ?: [NSMutableArray array];
    // The session as this launch restored it, saved now (its own catch-up save can run before the launch's layout
    // has settled the current page), before any edit.
    ((void (*)(id, SEL))objc_msgSend)(reader, NSSelectorFromString(@"savePersistentState"));
    [NSFileManager.defaultManager copyItemAtPath:[state stringByAppendingPathComponent:@"session.yaml"]
                                          toPath:[record stringByAppendingPathComponent:
                                                    [NSString stringWithFormat:@"session-%ld.yaml", round]] error:nil];
    NSData* json = [NSJSONSerialization dataWithJSONObject:@{@"state" : restored, @"problems" : gProblems}
                                                   options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[record stringByAppendingPathComponent:[NSString stringWithFormat:@"restored-%ld.json", round]]
           atomically:YES];

    Class cls = object_getClass(reader);
    gWorkFolder = [record.stringByDeletingLastPathComponent.stringByStandardizingPath.stringByResolvingSymlinksInPath
        stringByAppendingString:@"/"];
    gTemporaryLocation = method_setImplementation(
        class_getInstanceMethod(cls, NSSelectorFromString(@"pathIsInTemporaryLocation:")), (IMP)TemporaryOutsideTest);
    method_setImplementation(class_getInstanceMethod(cls, NSSelectorFromString(@"promptForCommentTextWithDefault:")),
                             (IMP)AnswerPrompt);
    NSMutableArray* tabs = Ivar_(reader, "_tabs");
    NSUInteger count = tabs.count;
    // A read-only document (round 3): the file is made read-only before it is commented.
    NSUInteger target = (NSUInteger)(round * 7 + 3) % count;
    if (round == 3) {
        while ([[tabs[target] valueForKey:@"path"] containsString:@"/Pasted Images/"]) target = (target + 1) % count;
        chmod([[tabs[target] valueForKey:@"path"] fileSystemRepresentation], 0444);
    }
    NSString* before = [tabs[target] valueForKey:@"path"];
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(reader, NSSelectorFromString(@"selectTabAtIndex:"), (NSInteger)target);
    WaitLoaded(reader);
    PDFDocument* document = [[PDFDocument alloc] initWithURL:[NSURL fileURLWithPath:before]];
    NSInteger page = document.pageCount ? round % (long)document.pageCount : 0;
    ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(reader, NSSelectorFromString(@"goToPage:preserveSinglePagePosition:"),
                                                       page, NO);
    WaitLoaded(reader);
    // The page turned must stay turned: the tab switch's own layout passes, which can land after it on a busy
    // machine, and the comment (on a read-only document, a reload from the writable copy) must not move the view.
    if (IvarInteger(reader, "_pageIndex") != page)
        Problem(@"turned to page %ld right after switching tabs, showing page %ld", (long)page,
                (long)IvarInteger(reader, "_pageIndex"));
    gCommentText = [NSString stringWithFormat:@"Round %ld", round];
    *(NSInteger*)IvarAddress(reader, "_contextPageIndex") = IvarInteger(reader, "_pageIndex");
    *(NSPoint*)IvarAddress(reader, "_contextPagePoint") = NSMakePoint(72, 72);
    Call(reader, @"addComment:", nil);
    if (IvarInteger(reader, "_pageIndex") != page)
        Problem(@"page %ld showed page %ld once commented", (long)page, (long)IvarInteger(reader, "_pageIndex"));
    NSString* after = [tabs[target] valueForKey:@"path"];
    if (round == 3 && [after isEqual:before]) Problem(@"the read-only document did not move to a writable copy");
    if (![after isEqual:before] && edits[before]) edits[after] = edits[before], [edits removeObjectForKey:before];
    NSMutableDictionary* edit = EditFor(edits, after);
    edit[@"comments"] = [edit[@"comments"] arrayByAddingObject:gCommentText];
    if (round % 4 == 1) {
        Call(reader, @"rotateClockwise:", nil);
        NSMutableDictionary* rotations = [edit[@"rotations"] mutableCopy];
        NSString* key = [NSString stringWithFormat:@"%ld", (long)IvarInteger(reader, "_pageIndex")];
        rotations[key] = @(([rotations[key] integerValue] + 90) % 360);
        if (![rotations[key] integerValue]) [rotations removeObjectForKey:key];
        edit[@"rotations"] = rotations;
    }
    if (round % 5 == 4)
        ((void (*)(id, SEL, id, id))objc_msgSend)(reader, NSSelectorFromString(@"showDisplayName:forTabsAtPath:"),
                                                  [NSString stringWithFormat:@"Shown %ld", round], after);
    if (round % 5 == 2) {
        // Rename, as the Rename sheet does once a name is entered: the file moves and its tabs follow.
        NSUInteger other = (target + 1) % count;
        NSString* source = [tabs[other] valueForKey:@"path"];
        if (![source containsString:@"/Pasted Images/"]) {
            NSString* destination = [source.stringByDeletingPathExtension
                stringByAppendingFormat:@" r%ld.%@", round, source.pathExtension];
            if ([NSFileManager.defaultManager moveItemAtPath:source toPath:destination error:nil]) {
                ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                    reader, NSSelectorFromString(@"adoptRenamedDocumentFrom:to:replacingReadOnly:"), source, destination, NO);
                if (edits[source]) edits[destination] = edits[source], [edits removeObjectForKey:source];
            }
        }
    }
    if (round == 5) {
        // An untitled document: a pasted image, kept in the app's storage until saved somewhere.
        NSString* folder = [state stringByAppendingPathComponent:@"Pasted Images"];
        [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* path = [folder stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"Pasted Image %@.png", NSUUID.UUID.UUIDString]];
        NSBitmapImageRep* image = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:48 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
                            isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        Call(reader, @"openPaths:", @[ path ]);
        WaitLoaded(reader);
        [pasted addObject:path];
    }
    NSMutableDictionary* left = [LiveState(reader) mutableCopy];
    left[@"edits"] = edits;
    left[@"pastedImages"] = pasted;
    left[@"problems"] = gProblems;
    [[NSJSONSerialization dataWithJSONObject:left options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[record stringByAppendingPathComponent:[NSString stringWithFormat:@"expected-%ld.json", round]]
         atomically:YES];
}
