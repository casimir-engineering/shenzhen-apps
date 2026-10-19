#import "SPDFMacCollectionReaderNavigation.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacCollectionRestoreTab.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacCollectionWindow.h"
#import <objc/runtime.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
@implementation SPDFDocumentTab
@end
#pragma clang diagnostic pop
@interface CollectionEvidenceSurface : NSView
@end
@implementation CollectionEvidenceSurface
- (void)drawRect:(NSRect)dirty { [NSColor.windowBackgroundColor setFill]; NSRectFill(dirty); }
@end
static NSString* locatedID;
void SPDFMacLocateCollectionOriginal(SPDFMacCollectionStore* store, NSString* identifier,
    NSWindow* parent, void (^open)(NSString*), void (^linked)(NSString*)) {
    (void)store; (void)parent; (void)open; (void)linked; locatedID = identifier;
}
@interface HiddenReaderWindow : NSWindow
@property NSUInteger presentations;
@end
@implementation HiddenReaderWindow
- (void)makeKeyAndOrderFront:(id)sender { (void)sender; self.presentations++; }
@end
@interface NavigationProbe : ShenzhenMacDelegate
@property NSString* opened;
@property BOOL archived;
@property NSUInteger histories;
@property NSUInteger opens;
@property NSDictionary* result;
- (void)seed;
- (NSButton*)indicator;
- (BOOL)writeToolbarEvidence:(NSString*)path;
@end
@implementation NavigationProbe
- (void)seed {
    _tabs = [NSMutableArray arrayWithObject:[SPDFDocumentTab new]]; _selectedTabIndex = 0;
    _window = [[HiddenReaderWindow alloc] initWithContentRect:NSMakeRect(0,0,300,200)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    _window.releasedWhenClosed = NO;
    _findRegexCheckbox = [NSButton checkboxWithTitle:@"Regex" target:nil action:nil];
    _toolbarSpacer=[NSView new]; _toolbarSpacer.translatesAutoresizingMaskIntoConstraints=NO;
    [_toolbarSpacer.widthAnchor constraintEqualToConstant:450].active=YES;
    [_toolbarSpacer.heightAnchor constraintEqualToConstant:28].active=YES;
    _toolbar = (id)[NSStackView stackViewWithViews:@[_findRegexCheckbox,_toolbarSpacer]];
}
- (SPDFDocumentTab*)selectedTab { return _tabs.firstObject; }
- (void)collectionOpenPath:(NSString*)path archived:(BOOL)archived { self.opened = path; self.archived = archived; self.opens++; [self selectedTab].path = path; }
- (void)showCollectionRecovery:(id)sender { (void)sender; locatedID=[SPDFMacCollectionStore.defaultStore documentForPath:self.opened][@"id"]; }
- (void)showCollectionHistory:(id)sender { (void)sender; self.histories++; }
- (void)collectionNavigateResult:(NSDictionary*)result path:(NSString*)path attempts:(NSInteger)attempts {
    (void)path; (void)attempts; self.result = result;
}
- (BOOL)writeToolbarEvidence:(NSString*)path {
    [_window setContentSize:NSMakeSize(570,68)];
    _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    _window.contentView = [[CollectionEvidenceSurface alloc] initWithFrame:NSMakeRect(0,0,570,68)];
    NSView* container = _window.contentView;
    _toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:_toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [_toolbar.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [_toolbar.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]]];
    [container layoutSubtreeIfNeeded];
    NSBitmapImageRep* bitmap = [container bitmapImageRepForCachingDisplayInRect:container.bounds];
    [container cacheDisplayInRect:container.bounds toBitmapImageRep:bitmap];
    return !_window.visible && [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:path atomically:YES];
}
- (NSButton*)indicator {
    for (NSView* row in _toolbarSpacer.subviews)
        for (NSView* view in row.subviews)
            if ([view.identifier isEqual:@"CollectionVersionIndicator"]) return (NSButton*)view;
    return nil;
}
@end
@interface RecoveryProbe : NavigationProbe
@property NSUInteger loads;
- (void)restoreChecksPath:(NSString*)path;
@end
@implementation RecoveryProbe
- (void)restoreChecksPath:(NSString*)path { [self selectedTab].path=path; [self selectedTab].missingFile=YES; }
- (void)loadSelectedTab { self.loads++; _path=[self selectedTab].path; }
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab { (void)tab; }
- (void)showEmptyDocumentViewWithMessage:(NSString*)message { (void)message; }
- (void)updateTabStrip {}
- (void)savePersistentState {}
- (NSInteger)indexOfTabForPath:(NSString*)path { return [[self selectedTab].path isEqual:path] ? 0 : -1; }
- (void)openPath:(NSString*)path { [self selectedTab].path=path; }
@end
static int failures, storeInitializations;
static IMP oldInit;
static id CountInit(id self, SEL selector, NSURL* URL) {
    ++storeInitializations;
    return ((id (*)(id,SEL,NSURL*))oldInit)(self,selector,URL);
}
static void Expect(BOOL value, const char* label) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",label); ++failures; }
}
static BOOL Await(BOOL (^ready)(void)) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:5];
    while (!ready() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ready();
}
int main(void) {
    @autoreleasepool {
        NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("SPDF_STATE_DIR",root.UTF8String,1);
        Method init = class_getInstanceMethod(SPDFMacCollectionStore.class,@selector(initWithRootURL:));
        oldInit = method_setImplementation(init,(IMP)CountInit);
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        SPDFDocumentTab* unrelated = [SPDFDocumentTab new]; unrelated.path = @"/old.md";
        unrelated.collectionHistoryDocumentID = @"other";
        SPDFDocumentTab* missing = [SPDFDocumentTab new]; missing.path = @"/old.md";
        missing.collectionHistoryDocumentID = @"recover"; missing.missingFile = YES;
        missing.pageIndex = 8; missing.zoom = 1.4; missing.scrollOrigin = NSMakePoint(23,456); missing.hasScrollOrigin = YES;
        SPDFDocumentTab* preview = [SPDFDocumentTab new]; preview.path = @"/found.md";
        NSArray* tabs = @[unrelated,missing,preview];
        Expect(SPDFCollectionMissingTab(@[unrelated],@"recover",@"/old.md") == nil,
            "unrelated occupant at old path is never retargeted");
        unrelated.missingFile = YES;
        Expect(SPDFCollectionMissingTab(@[unrelated],@"recover",@"/old.md") == nil,
            "missing placeholder for different history is never retargeted");
        Expect(SPDFCollectionMissingTab(tabs,@"recover",@"/old.md") == missing,
            "recovery requires both missing placeholder and matching history identity");
        Expect(SPDFCollectionExistingRestoredTab(tabs,@"/found.md") == preview,
            "Locator Preview existing destination wins instead of duplicate retarget");
        SPDFCollectionRestoreReadingPosition(missing,preview);
        Expect(preview.pageIndex == 8 && preview.zoom == 1.4 && preview.hasScrollOrigin &&
            NSEqualPoints(preview.scrollOrigin,missing.scrollOrigin) && [unrelated.path isEqual:@"/old.md"],
            "deduplicated recovery transfers reading position and leaves unrelated tab alone");
        NavigationProbe* reader = [NavigationProbe new]; [reader seed];
        for (NSUInteger i=0;i<10;i++) { [reader collectionUpdateVersionIndicator]; [reader collectionRememberGroups]; }
        Expect(storeInitializations == 0,"ordinary toolbar never constructs Collection store");
        Expect(!reader.indicator,"ordinary toolbar creates no Collection pill");
        SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSString* path = [root stringByAppendingPathComponent:@"Fixture.md"];
        [@"# Old\nold content" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* first = [store capturePath:path reason:@"Opened" error:nil];
        [@"# New\nnew content" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSDictionary* doc = [store capturePath:path reason:@"Saved" continuingDocumentID:first[@"id"] error:nil];
        NSDictionary* old = [doc[@"versions"] firstObject];
        Expect([doc[@"versions"] count] == 2,"fixture captures two real saved versions");
        [reader collectionNavigateDocument:doc version:old page:3 query:@"old" history:YES];
        Expect(Await(^BOOL { return reader.histories == 1; }),"history navigation completes");
        Expect([reader.opened isEqual:path] && !reader.archived,"History chooses available original even when older version supplied");
        reader.opened = nil;
        [reader collectionNavigateDocument:doc version:old page:3 query:@"old" history:NO];
        Expect(Await(^BOOL { return reader.result != nil; }),"search navigation completes");
        Expect(reader.archived && [[store archiveInfoForPath:reader.opened][@"version"][@"id"] isEqual:old[@"id"]],
            "search opens exact indexed version");
        Expect([reader.result[@"page"] integerValue] == 2 && [reader.result[@"query"] isEqual:@"old"],
            "search preserves query and converts one-based page");
        Expect(reader.histories == 1,"search does not open History");
        reader.result = nil; reader.opened = nil;
        [reader collectionNavigateDocument:doc version:[doc[@"versions"] lastObject] page:2 query:@"new" history:NO];
        Expect(Await(^BOOL { return reader.result != nil; }) && [reader.opened isEqual:path] && !reader.archived,
            "latest Collection result opens editable original rather than collected copy");
        // Submit both intentions before dispatching either main-queue completion.
        // Every completion (including the superseded request) gets a chance to run.
        NSUInteger priorOpens = reader.opens;
        reader.result = nil;
        [reader collectionNavigateDocument:doc version:old page:1 query:@"superseded" history:NO];
        [reader collectionNavigateDocument:doc version:[doc[@"versions"] lastObject] page:4 query:@"last intent" history:NO];
        Expect(Await(^BOOL { return [reader.result[@"query"] isEqual:@"last intent"]; }),
            "last rapid navigation intent completes");
        NSDate* settle = [NSDate dateWithTimeIntervalSinceNow:.2];
        while (settle.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:settle];
        Expect(reader.opens == priorOpens + 1 && [reader.result[@"query"] isEqual:@"last intent"] &&
            [reader.result[@"page"] integerValue] == 3,
            "superseded navigation never opens even when requests overlap");
        [@"# Unrelated replacement" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        reader.opened = nil;
        [reader collectionNavigateDocument:doc version:old page:0 query:@"" history:YES];
        Expect(Await(^BOOL { return reader.histories == 2; }),"replaced-source History completes");
        Expect(reader.archived && [[store archiveInfoForPath:reader.opened][@"version"][@"id"] isEqual:doc[@"latestVersionID"]],
            "unrelated document at original path is never treated as the original");
        [NSFileManager.defaultManager removeItemAtPath:path error:nil]; reader.opened = nil;
        [reader collectionNavigateDocument:doc version:old page:0 query:@"" history:YES];
        Expect(Await(^BOOL { return reader.histories == 3; }),"missing-source History navigation completes");
        Expect([[store archiveInfoForPath:reader.opened][@"version"][@"id"] isEqual:doc[@"latestVersionID"]],
            "missing-source History chooses latest saved version");
        NSMutableDictionary* dated = [old mutableCopy]; dated[@"capturedAt"] = @1780358400;
        [reader collectionSetVersionInfo:@{@"document":doc,@"version":dated} forTab:reader.selectedTab];
        Expect([reader.indicator.title containsString:@"Older version"] && [reader.indicator.title containsString:@"2026.06.02"],
            "older-version pill shows date");
        Expect([reader.indicator.title containsString:@"Original missing"],"lost source is stated on pill");
        NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_TOOLBAR_EVIDENCE"];
        if (evidence.length) Expect([reader writeToolbarEvidence:evidence],"toolbar evidence renders without showing window");
        Expect([[reader.indicator valueForKey:@"missing"] boolValue],"missing source pill has red status styling");
        NSButton* locate=nil;
        for (NSView* sibling in reader.indicator.superview.subviews)
            if ([sibling.identifier isEqual:@"CollectionLocateDocument"]) locate=(NSButton*)sibling;
        Expect(locate && !locate.hidden && locate.enabled,"missing source has an explicit enabled Locate button");
        [locate performClick:nil];
        Expect([locatedID isEqual:doc[@"id"]],"Locate button routes to recovery");
        [reader.indicator performClick:nil];
        Expect([locatedID isEqual:doc[@"id"]],"lost-source pill routes to Locate prompt");
        NSDictionary* latest = [doc[@"versions"] lastObject];
        [reader collectionSetVersionInfo:@{@"document":doc,@"version":latest} forTab:reader.selectedTab];
        Expect(![reader.indicator.title containsString:@"Older version"],"current saved copy starts latest");
        NSMutableDictionary* changed = [doc mutableCopy];
        changed[@"latestVersionID"] = @"future";
        [reader collectionRefreshVersionInfoForDocument:changed];
        Expect([reader.indicator.title containsString:@"Older version"],"new capture refreshes previously latest pill");
        NSString* recovered = [root stringByAppendingPathComponent:@"Recovered.md"];
        NSURL* latestURL = [store materializeVersionID:latest[@"id"] documentID:doc[@"id"] error:nil];
        [NSFileManager.defaultManager copyItemAtPath:latestURL.path toPath:recovered error:nil];
        Expect([store linkDocumentID:doc[@"id"] toPath:recovered allowMismatch:NO error:nil],"fixture relinks exact hash");
        [reader collectionRefreshVersionInfoForDocument:[store documentForPath:recovered]];
        Expect(![reader.indicator.title containsString:@"Original missing"] &&
            ![reader.indicator.title containsString:@"Older version"],"relink refresh clears stale missing and latest metadata");
        [reader collectionSetVersionInfo:nil forTab:reader.selectedTab];
        Expect(reader.indicator.hidden,"switching to ordinary document hides pill");
        [NSFileManager.defaultManager removeItemAtPath:recovered error:nil];
        RecoveryProbe* recovery=[RecoveryProbe new]; [recovery seed]; [recovery restoreChecksPath:recovered];
        SPDFDocumentTab* restoredTab=recovery.selectedTab;
        SPDFTabGroup* project=[SPDFTabGroup groupWithColor:@"Green"]; project.name=@"Project";
        restoredTab.group=project; restoredTab.pageIndex=8; restoredTab.zoom=1.6;
        restoredTab.scrollOrigin=NSMakePoint(0,540); restoredTab.hasScrollOrigin=YES;
        Expect([recovery collectionRestoreMissingTab:restoredTab path:recovered],"missing source schedules saved document recovery");
        Expect([recovery collectionRestoreMissingTab:restoredTab path:recovered],"revisiting a pending recovery does not fall through to an empty placeholder");
        Expect(Await(^BOOL { return recovery.loads==1; }),"missing source recovery loads the Collection document");
        Expect(restoredTab==recovery.selectedTab && restoredTab.group==project && restoredTab.pageIndex==8 &&
            restoredTab.zoom==1.6 && restoredTab.scrollOrigin.y==540,"recovery keeps the same tab, group and reading position");
        Expect(!restoredTab.readOnly && !restoredTab.missingFile && [store editableInfoForPath:restoredTab.path],
            "recovered document is an editable working file");
        Expect([recovery.indicator.title containsString:@"Original missing"],"recovered tab retains missing original toolbar status");
        [recovery collectionRememberGroups];
        Expect(Await(^BOOL { return [[store documentForPath:restoredTab.path][@"tabGroup"][@"name"] isEqual:@"Project"]; }),
            "group mutations persist source membership for later Collection opening");
        RecoveryProbe* alreadyPrepared=[RecoveryProbe new]; [alreadyPrepared seed]; [alreadyPrepared restoreChecksPath:recovered];
        alreadyPrepared.selectedTab.group=project; alreadyPrepared.selectedTab.pageIndex=6;
        [alreadyPrepared collectionPresentEditablePath:restoredTab.path info:[store editableInfoForPath:restoredTab.path]];
        Expect(alreadyPrepared.loads==1 && alreadyPrepared.selectedTab.pageIndex==6 && alreadyPrepared.selectedTab.group==project,
            "opening a prepared Collection document replaces its missing placeholder synchronously without resetting position");
        RecoveryProbe* stale=[RecoveryProbe new]; [stale seed]; [stale restoreChecksPath:recovered];
        [stale collectionRestoreMissingTab:stale.selectedTab path:recovered]; stale.selectedTab.path=@"/another-document.md";
        NSDate* drained=[NSDate dateWithTimeIntervalSinceNow:.2];
        while(drained.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:drained];
        Expect(stale.loads==0 && [stale.selectedTab.path isEqual:@"/another-document.md"],"late recovery never replaces a changed tab");
        method_setImplementation(init,oldInit);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        if (!failures) puts("SPDFMacCollectionReaderNavigationTests passed");
    }
    return failures ? 1 : 0;
}
