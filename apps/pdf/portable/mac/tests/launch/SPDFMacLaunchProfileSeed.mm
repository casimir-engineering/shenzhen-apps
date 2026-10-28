// A synthetic profile the size of a heavy real one, written by the reader itself (PROBE_MODE=profile): about a hundred
// PDFs restored as tabs in named groups, a few hundred more read and closed before, Collection on and holding all of
// them, so session.yaml, documents.yaml, bookmarks.yaml, activity.yaml and the Collection manifest come out the
// sizes they reach in daily use. Deterministic from its parameters; no real document is read.
//
//   PROBE_PROFILE_DOCS     folder the PDFs are written to (created)
//   PROBE_PROFILE_TABS     restored tabs (default 100), in groups of 12
//   PROBE_PROFILE_HISTORY  documents read and closed before (default 200)
//   PROBE_PROFILE_SELECT   the tab selected at the end (default 57), shown at page 3

#import <Cocoa/Cocoa.h>
#import <objc/message.h>
#import <objc/runtime.h>

bool SPDFLaunchPerformanceWriteDrawingSet(const char* path, long pages, long curves);

static long EnvLong(const char* name, long fallback) { return getenv(name) ? atol(getenv(name)) : fallback; }
static void Pump(NSTimeInterval seconds) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}
static id Ivar_(id object, const char* name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}
static void Send(id target, NSString* selector) { ((void (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(selector)); }
static void SendInteger(id target, NSString* selector, NSInteger value) {
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(target, NSSelectorFromString(selector), value);
}
static void SendObject(id target, NSString* selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(target, NSSelectorFromString(selector), value);
}

// A text document: pages of set paragraphs, with a heading per page, like a datasheet or a report.
static bool WriteTextDocument(NSString* path, long pages, unsigned seed) {
    CGRect a4 = CGRectMake(0, 0, 595.28, 841.89);
    CGContextRef ctx = CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], &a4, NULL);
    if (!ctx) return false;
    NSArray* words = @[ @"voltage", @"supply", @"connector", @"tolerance", @"housing", @"thermal", @"assembly",
                        @"bracket", @"revision", @"signal", @"ground", @"clearance", @"module", @"output" ];
    NSDictionary* body = @{NSFontAttributeName : [NSFont systemFontOfSize:9.5]};
    NSDictionary* heading = @{NSFontAttributeName : [NSFont boldSystemFontOfSize:15]};
    for (long p = 0; p < pages; p++) {
        CGPDFContextBeginPage(ctx, NULL);
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
        [[NSString stringWithFormat:@"Section %ld", p + 1] drawAtPoint:NSMakePoint(56, 780) withAttributes:heading];
        NSMutableString* text = [NSMutableString string];
        for (int w = 0; w < 520; w++) {
            seed = seed * 1103515245u + 12345u;
            [text appendString:words[(seed >> 8) % words.count]];
            [text appendString:(seed >> 20) % 11 == 0 ? @". " : @" "];
        }
        [text drawInRect:NSMakeRect(56, 60, 483, 700) withAttributes:body];
        NSGraphicsContext.currentContext = nil;
        CGPDFContextEndPage(ctx);
    }
    CGPDFContextClose(ctx);
    CGContextRelease(ctx);
    return true;
}

static NSArray<NSString*>* WriteDocuments(NSString* folder, NSString* prefix, long count) {
    NSMutableArray* paths = [NSMutableArray array];
    for (long i = 0; i < count; i++) {
        NSString* path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %03ld.pdf", prefix, i + 1]];
        long pages = 1 + (i * 37 + 11) % 48;
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            bool ok = i % 3 == 0 ? SPDFLaunchPerformanceWriteDrawingSet(path.fileSystemRepresentation, MIN(pages, 12L), 3000)
                                 : WriteTextDocument(path, pages, (unsigned)(i * 7919 + prefix.length));
            if (!ok) {
                fprintf(stderr, "profile: could not write %s\n", path.UTF8String);
                _exit(2);
            }
        }
        [paths addObject:path];
    }
    return paths;
}

static BOOL Loaded(id reader) {
    NSOperationQueue* render = Ivar_(reader, "_renderQueue");
    Ivar doc = class_getInstanceVariable(object_getClass(reader), "_doc");
    return render.operationCount == 0 && *(void**)((uint8_t*)(__bridge void*)reader + ivar_getOffset(doc)) != NULL;
}
static void WaitLoaded(id reader) {
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:10];
    do Pump(0.02); while (!Loaded(reader) && until.timeIntervalSinceNow > 0);
}

void SPDFProbeSeedProfile(id reader) {
    NSString* folder = [NSString stringWithUTF8String:getenv("PROBE_PROFILE_DOCS") ?: ""];
    if (!folder.length) {
        fprintf(stderr, "profile: PROBE_PROFILE_DOCS must name a folder\n");
        _exit(2);
    }
    long tabCount = EnvLong("PROBE_PROFILE_TABS", 100), historyCount = EnvLong("PROBE_PROFILE_HISTORY", 200);
    long selected = MIN(EnvLong("PROBE_PROFILE_SELECT", 57), tabCount - 1);
    NSString* restored = [folder stringByAppendingPathComponent:@"Projects"];
    NSString* earlier = [folder stringByAppendingPathComponent:@"Archive"];
    [NSFileManager.defaultManager createDirectoryAtPath:restored withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:earlier withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray* tabPaths = WriteDocuments(restored, @"Drawing", tabCount);
    NSArray* historyPaths = WriteDocuments(earlier, @"Report", historyCount);

    Class store = NSClassFromString(@"SPDFMacCollectionStore");
    id collection = ((id (*)(id, SEL))objc_msgSend)(store, NSSelectorFromString(@"defaultStore"));
    ((BOOL(*)(id, SEL, id, NSError**))objc_msgSend)(collection, NSSelectorFromString(@"updateSettings:error:"),
                                                     @{@"choice" : @"enabled"}, nil);
    // Read before: each opened, shown and closed, as a day of work leaves them in documents.yaml and Collection.
    for (NSString* path in historyPaths) {
        SendObject(reader, @"openPaths:", @[ path ]);
        WaitLoaded(reader);
        SendObject(reader, @"closeDocument:", nil);
    }
    NSMutableArray* tabs = Ivar_(reader, "_tabs");
    for (NSString* path in tabPaths) {
        SendObject(reader, @"openPaths:", @[ path ]);
        WaitLoaded(reader);
    }
    // Groups of twelve with names and colours, the last two collapsed; the rest of the tabs are ungrouped.
    Class groupClass = NSClassFromString(@"SPDFTabGroup");
    NSArray* colors = @[ @"Blue", @"Green", @"Orange", @"Purple", @"Red", @"Yellow", @"Pink", @"Cyan" ];
    NSMutableArray* groups = [NSMutableArray array];
    for (NSUInteger g = 0; g < 8; g++) {
        id group = ((id (*)(id, SEL, id))objc_msgSend)(groupClass, NSSelectorFromString(@"groupWithColor:"), colors[g]);
        [group setValue:[NSString stringWithFormat:@"Project %c", (char)('A' + g)] forKey:@"name"];
        if (g >= 6) [group setValue:@YES forKey:@"collapsed"];
        [groups addObject:group];
    }
    for (NSUInteger i = 0; i < tabs.count; i++)
        if (i / 12 < groups.count) [tabs[i] setValue:groups[i / 12] forKey:@"group"];
    Send(reader, @"updateTabStrip");
    SendInteger(reader, @"selectTabAtIndex:", selected);
    WaitLoaded(reader);
    ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(reader, NSSelectorFromString(@"goToPage:preserveSinglePagePosition:"),
                                                       2, NO);
    WaitLoaded(reader);
    // Collection captures every opened document on its own worker: wait until it has them all.
    NSDate* until = [NSDate dateWithTimeIntervalSinceNow:300];
    NSUInteger want = (NSUInteger)(tabCount + historyCount), have = 0;
    while ((have = [((id (*)(id, SEL))objc_msgSend)(collection, NSSelectorFromString(@"documents")) count]) < want &&
           until.timeIntervalSinceNow > 0)
        Pump(0.2);
    Send(reader, @"savePersistentState");
    Class activity = NSClassFromString(@"SPDFMacDocumentActivityStore");
    Send(((id (*)(id, SEL))objc_msgSend)(activity, NSSelectorFromString(@"sharedStore")), @"flushNow");
    Pump(0.5);
    printf("PROFILE tabs=%lu collection=%lu selected=%ld\n", (unsigned long)tabs.count, (unsigned long)have, selected);
}
