#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionHistory.h"
#import "SPDFMacSidebarModeControl.h"
#import "SPDFMacCollectionStore.h"
#import "../SPDFMacCollectionSidebarIntegration.mm"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
@end
@implementation SPDFDocumentTab
@end
SPDFDocumentTab* spdf_copy_document_tab(SPDFDocumentTab* tab) {
    (void)tab; abort(); // Recovery is exercised by the reader-navigation suite, never this layout probe.
}
#pragma clang diagnostic pop
@interface HistorySidebarProbe : ShenzhenMacDelegate
- (void)seed;
- (void)reveal;
@end
@implementation HistorySidebarProbe
- (void)seed {
    SPDFDocumentTab* tab = [SPDFDocumentTab new]; tab.collectionHistoryDocumentID = @"fixture";
    _tabs = [NSMutableArray arrayWithObject:tab]; _selectedTabIndex = 0;
    _sidebarContainer = [NSView new]; _sidebarModeControl = [SPDFSidebarNavigationControl new];
    spdf_sidebar_mode_control_configure_navigation(_sidebarModeControl, YES, YES);
    _sidebarModeControl.spdf_selectedSidebarMode = SPDFSidebarModeHistory;
    [_sidebarContainer addSubview:_sidebarModeControl];
}
- (SPDFDocumentTab*)selectedTab { return _tabs.firstObject; }
- (BOOL)hasSearchSidebar { return NO; }
- (void)syncSidebarModeControlSegmentsForSearchAvailability:(BOOL)available { (void)available; }
- (void)setSidebarActuallyVisible:(BOOL)visible { _sidebarVisible = visible; }
- (void)restoreSidebarWidth {}
- (void)reveal { _sidebarPreferredVisible = YES; }
@end
@interface CollectionEvidenceSurface : NSView
@end
@implementation CollectionEvidenceSurface
- (void)drawRect:(NSRect)dirty { [NSColor.windowBackgroundColor setFill]; NSRectFill(dirty); }
@end
static int failures;
static void Expect(BOOL result, const char* label) {
    if (!result) { fprintf(stderr,"FAIL: %s\n",label); ++failures; }
}
static NSView* Find(NSView* view, Class cls) {
    if ([view isKindOfClass:cls]) return view;
    for (NSView* child in view.subviews) { NSView* found = Find(child,cls); if (found) return found; }
    return nil;
}
static NSUInteger Badges(NSView* view) {
    NSUInteger count = [view.identifier isEqual:@"CollectionLatestBadge"] ? 1 : 0;
    for (NSView* child in view.subviews) count += Badges(child);
    return count;
}
static NSView* Identified(NSView* view, NSString* identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView* child in view.subviews) { NSView* found = Identified(child,identifier); if (found) return found; }
    return nil;
}
@interface HistoryFixtureStore : SPDFMacCollectionStore
@property NSString* fixturePath;
@property NSUInteger materializations;
@property BOOL empty;
@property BOOL kept;
@property unsigned long long storageLimit;
@property NSString* deletedVersion;
@property NSString* clearedDocument;
@property NSMutableArray<NSString*>* editableVersions;
@end
@implementation HistoryFixtureStore
- (BOOL)isStorageLimited { return self.storageLimit>0; }
- (NSDictionary*)settings { return @{@"storageLimitBytes":@(self.storageLimit)}; }
- (NSArray*)documents {
    return @[@{@"id":@"fixture",@"title":@"Garden notes.md",@"status":@"Protected local copies",@"path":self.fixturePath ?: @"/missing/Notes.md",@"versions":(self.empty ? @[] : @[
        @{@"id":@"old",@"capturedAt":@1780358400,@"size":@1240,@"reason":@"Before edit"},@{@"id":@"new",@"keep":@(self.kept),@"capturedAt":@1790121600,@"size":@1510,@"reason":@"Saved"}])}];
}
- (BOOL)deleteDocumentID:(NSString*)documentID versionID:(NSString*)versionID error:(NSError**)error {
    (void)documentID; (void)error;
    dispatch_async(dispatch_get_main_queue(), ^{ self.deletedVersion=versionID; }); return YES;
}
- (BOOL)deletePreviousBackupsForDocumentID:(NSString*)documentID error:(NSError**)error {
    (void)error; dispatch_async(dispatch_get_main_queue(), ^{ self.clearedDocument=documentID; }); return YES;
}
- (NSURL*)materializeVersionID:(NSString*)version documentID:(NSString*)document error:(NSError**)error {
    (void)document; (void)error;
    dispatch_async(dispatch_get_main_queue(), ^{ self.materializations++; });
    return [self.rootURL URLByAppendingPathComponent:[version stringByAppendingString:@".md"]];
}
- (NSURL*)editableVersionID:(NSString*)version documentID:(NSString*)document error:(NSError**)error {
    (void)document; (void)error;
    if (!self.editableVersions) self.editableVersions=[NSMutableArray array];
    @synchronized (self.editableVersions) { [self.editableVersions addObject:version]; }
    return [[[[self.rootURL URLByAppendingPathComponent:@"editable"] URLByAppendingPathComponent:@"fixture"]
        URLByAppendingPathComponent:version] URLByAppendingPathComponent:[version stringByAppendingString:@".md"]];
}
@end
@interface SPDFMacCollectionHistoryController (TestActions)
- (void)revealPath:(NSString*)path;
- (void)showVersionInExplorer:(NSMenuItem*)sender;
- (void)saveVersion:(NSDictionary*)version restoreLink:(BOOL)restore;
- (void)didRestorePath:(NSString*)path;
@end
@interface HistoryProbe : SPDFMacCollectionHistoryController
@property NSString* revealedPath;
@property NSString* savedVersion;
@property BOOL restoresLink;
@property(copy) void (^pendingDeletion)(BOOL);
@property NSString* deletionVersion;
@property BOOL deletionPrevious;
@property NSString* comparedVersion;
@property BOOL comparedPrevious;
@end
@implementation HistoryProbe
- (void)compareVersion:(NSDictionary*)version previous:(BOOL)previous {
    self.comparedVersion=version[@"id"]; self.comparedPrevious=previous;
}
- (void)confirmDeletionOfVersion:(NSDictionary*)version previousBackups:(BOOL)previous completion:(void (^)(BOOL))completion {
    self.deletionVersion=version[@"id"]; self.deletionPrevious=previous; self.pendingDeletion=completion;
}
- (void)revealPath:(NSString*)path { self.revealedPath = path; }
- (void)saveVersion:(NSDictionary*)version restoreLink:(BOOL)restore { self.savedVersion = version[@"id"]; self.restoresLink = restore; }
@end
static BOOL Await(BOOL (^ready)(void)) {
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:3];
    while (!ready() && end.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return ready();
}
static void Capture(NSView* view, NSString* evidence, NSString* suffix) {
    if (!evidence.length) return;
    [view layoutSubtreeIfNeeded];
    NSBitmapImageRep* image = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
    [view cacheDisplayInRect:view.bounds toBitmapImageRep:image];
    NSString* path = [[evidence stringByDeletingPathExtension] stringByAppendingFormat:@"-%@.png",suffix];
    Expect([[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES],
        "additional History evidence writes a native PNG");
}
static NSButton* Button(NSView* view, NSString* title) {
    if ([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqual:title]) return (id)view;
    for (NSView* child in view.subviews) { NSButton* button = Button(child,title); if (button) return button; }
    return nil;
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        HistoryFixtureStore* store = [[HistoryFixtureStore alloc] initWithRootURL:root];
        __block NSUInteger storeRequests = 0;
        Method defaultStore = class_getClassMethod(SPDFMacCollectionStore.class,@selector(defaultStore));
        IMP originalDefaultStore = method_setImplementation(defaultStore,imp_implementationWithBlock(^id(id receiver) {
            (void)receiver; ++storeRequests; return store;
        }));
        HistorySidebarProbe* sidebar = [HistorySidebarProbe new]; [sidebar seed];
        Expect([sidebar collectionShowSelectedHistoryPanel] && storeRequests == 0,
            "restored hidden History does not initialize Collection or build a controller");
        [sidebar reveal];
        Expect([sidebar collectionShowSelectedHistoryPanel] && storeRequests == 1,
            "revealing History lazily creates exactly one controller");
        [sidebar collectionShowSelectedHistoryPanel];
        Expect(storeRequests == 1,"visible History reuses its controller");
        [sidebar collectionRemoveHistoryView];
        method_setImplementation(defaultStore,originalDefaultStore);
        __block NSUInteger opens = 0;
        __block NSString* openedPath; __block BOOL archivedOpen;
        HistoryProbe* history = [[HistoryProbe alloc]
            initWithStore:store documentID:@"fixture" open:^(NSString* path, BOOL archived) {
                openedPath = path; archivedOpen = archived; ++opens;
            }];
        NSWindow* host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,280,620)
            styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        host.releasedWhenClosed = NO;
        host.contentView = [[CollectionEvidenceSurface alloc] initWithFrame:NSMakeRect(0,0,280,620)];
        NSView* container = host.contentView;
        SPDFSidebarNavigationControl* modes = [SPDFSidebarNavigationControl new];
        spdf_sidebar_mode_control_configure_navigation(modes, YES, YES);
        modes.spdf_selectedSidebarMode = SPDFSidebarModeHistory;
        modes.translatesAutoresizingMaskIntoConstraints = NO;
        history.view.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:modes]; [container addSubview:history.view];
        [NSLayoutConstraint activateConstraints:@[
            [modes.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
            [modes.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
            [modes.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
            [history.view.topAnchor constraintEqualToAnchor:modes.bottomAnchor constant:8],
            [history.view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [history.view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [history.view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor]]];
        [host.contentView layoutSubtreeIfNeeded];
        NSTableView* table = (id)Find(history.view,NSTableView.class);
        NSDate* end = [NSDate dateWithTimeIntervalSinceNow:3];
        while (table.numberOfRows != 3 && end.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(table.numberOfRows == 3,"both versions load in the reader history");
        NSView* newest = [history tableView:table viewForTableColumn:table.tableColumns.firstObject row:1];
        NSView* older = [history tableView:table viewForTableColumn:table.tableColumns.firstObject row:2];
        Expect(Badges(newest) == 1,"latest row has exactly one Latest pill");
        Expect(Badges(older) == 0,"older row never claims to be Latest");
        Expect(table.rowHeight <= 56,"compact version rows preserve history reading space");
        NSPopUpButton* actions = (id)Find(history.view,NSPopUpButton.class);
        Expect(actions && [actions itemWithTitle:@"Compare with Previous"] &&
            [actions itemWithTitle:@"Save a Copy…"] && [actions itemWithTitle:@"Manage Collection…"],
            "secondary version actions remain discoverable in a labeled menu");
        Expect([actions itemWithTitle:@"Manage Collection…"].enabled &&
            ![actions itemWithTitle:@"Save a Copy…"].enabled,"menu availability follows selection");
        history.view.hidden = YES; history.view.hidden = NO;
        Expect(table.numberOfRows == 3,"switching away from History preserves the loaded versions");
        Expect(opens == 0,"loading and panel switching never opens a version implicitly");
        Expect(!host.visible,"history tests never show the app");
        NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_HISTORY_EVIDENCE"];
        if (evidence.length) {
            host.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            [container layoutSubtreeIfNeeded];
            NSBitmapImageRep* bitmap = [container bitmapImageRepForCachingDisplayInRect:container.bounds];
            [container cacheDisplayInRect:container.bounds toBitmapImageRep:bitmap];
            Expect([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:evidence atomically:YES],"history evidence writes a headless PNG");
        }
        Expect(Button(history.view,@"Find Document…") && Button(history.view,@"Save New Copy As…"),
            "missing link offers inline Find and Save actions");
        Expect(!Button(history.view,@"Find Document…").superview.hidden,"missing-source actions are visible without a modal");
        [Button(history.view,@"Save New Copy As…") performClick:nil];
        Expect([history.savedVersion isEqual:@"new"] && history.restoresLink,"Save New Copy restores link from latest version without selection");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        Expect(Await(^BOOL { return opens == 1; }) && archivedOpen && [openedPath.lastPathComponent isEqual:@"new.md"] &&
            [openedPath.pathComponents containsObject:@"editable"],
            "missing latest opens an editable Collection copy without a prompt");
        [history menuNeedsUpdate:table.menu];
        Expect([table.menu itemWithTitle:@"Delete version…"].enabled &&
            ![table.menu itemWithTitle:@"Delete all previous backups…"],
            "missing original's latest saved copy remains a deletable backup");
        [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
        store.fixturePath = [root.path stringByAppendingPathComponent:@"Original.md"];
        [@"live edit" writeToFile:store.fixturePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [table deselectAll:nil];
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        Expect(Await(^BOOL { return opens == 2; }) && !archivedOpen && [openedPath isEqual:store.fixturePath],
            "Latest rechecks current link and opens on-disk original");
        Expect(Await(^BOOL { return table.numberOfRows==2; }),"restoring source removes missing entry");
        Expect(!Button(history.view,@"Compare with Latest").enabled &&
            [actions itemWithTitle:@"Compare with Previous"].enabled,
            "latest selected disables self comparison while previous comparison stays reachable");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        Expect(Await(^BOOL { return opens == 3; }) && archivedOpen && [openedPath.lastPathComponent isEqual:@"old.md"] &&
            [openedPath.pathComponents containsObject:@"editable"],
            "older selection opens an independent editable Collection copy");
        Expect(Button(history.view,@"Compare with Latest").enabled &&
            ![actions itemWithTitle:@"Compare with Previous"].enabled &&
            [actions itemWithTitle:@"Save a Copy…"].enabled,
            "oldest selection compares with latest and exports but has no previous version");
        [history menuNeedsUpdate:table.menu];
        NSMenuItem* reveal = table.menu.itemArray.firstObject;
        Expect([reveal.title isEqual:@"Show in Explorer"],"version context menu offers configured explorer");
        [history showVersionInExplorer:reveal];
        Expect(Await(^BOOL { return history.revealedPath != nil; }) && [history.revealedPath.lastPathComponent isEqual:@"old.md"],
            "older-version reveal uses materialized selected version");
        history.revealedPath = nil; reveal.representedObject = [store.documents.firstObject[@"versions"] lastObject];
        [history showVersionInExplorer:reveal];
        Expect(Await(^BOOL { return history.revealedPath != nil; }) && [history.revealedPath isEqual:store.fixturePath],
            "Latest reveal uses live original");
        store.fixturePath = @"/missing/Notes.md";
        NSUInteger editableVersions;
        @synchronized (store.editableVersions) { editableVersions=store.editableVersions.count; }
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [history cancelPendingPreviews];
        Expect(Await(^BOOL {
            @synchronized (store.editableVersions) { return store.editableVersions.count > editableVersions; }
        }),"pending preview resolves an editable Collection copy");
        NSDate* drained = [NSDate dateWithTimeIntervalSinceNow:.1];
        while (drained.timeIntervalSinceNow > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:drained];
        Expect(opens == 3,"leaving History cancels stale preview navigation");
        __block NSString* retainedSource; __block NSString* restoredSource;
        history.restoreLinkHandler = ^(NSString* previous, NSString* restored) { retainedSource = previous; restoredSource = restored; };
        [history didRestorePath:@"/restored/Notes.md"];
        Expect([retainedSource hasSuffix:@"Original.md"] && [restoredSource isEqual:@"/restored/Notes.md"] && opens == 3,
            "recovery routes old and new identities to retain existing reader tab instead of opening a duplicate");
        Expect(Await(^BOOL { return !Button(history.view,@"Find Document…").superview.hidden; }),
            "missing-link recovery reload finishes before short-window layout");
        [host setContentSize:NSMakeSize(176,296)];
        [container layoutSubtreeIfNeeded];
        Expect(container.bounds.size.height == 296 && container.bounds.size.width == 176,
            "History preserves the true minimum sidebar width and short height");
        fprintf(stderr,"History geometry panel=%.0f table=%.0f clip=%.0f column=%.0f\n",
            NSWidth(history.view.bounds),NSWidth(table.bounds),
            NSWidth(table.enclosingScrollView.contentView.bounds),table.tableColumns.firstObject.width);
        Expect(table.numberOfRows==3,"missing source remains a distinct history entry above saved copies");
        NSView* missingCell=[table viewAtColumn:0 row:0 makeIfNecessary:YES];
        Expect([[(NSTextField*)Identified(missingCell,@"HistoryVersionDate") stringValue] isEqual:@"Missing document"],"history explicitly marks the lost source");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [history menuNeedsUpdate:table.menu];
        Expect([table.menu itemWithTitle:@"Locate document…"]!=nil && ![table.menu itemWithTitle:@"Delete version…"],"missing entry offers recovery rather than snapshot deletion");
        NSView* latestCell = [table viewAtColumn:0 row:1 makeIfNecessary:YES];
        Expect([Identified(latestCell,@"CollectionLatestBadge").accessibilityLabel isEqual:@"Latest copy"],"newest saved version is Latest copy when source is missing");
        NSTextField* fullDate = (id)Identified(latestCell,@"HistoryVersionDate");
        Expect(fullDate && NSWidth(fullDate.bounds) >=
            [fullDate.stringValue sizeWithAttributes:@{NSFontAttributeName:fullDate.font}].width,
            "minimum-width History shows the whole date beside always-visible scrollbars");
        if (evidence.length) {
            NSBitmapImageRep* bitmap = [container bitmapImageRepForCachingDisplayInRect:container.bounds];
            [container cacheDisplayInRect:container.bounds toBitmapImageRep:bitmap];
            NSString* shortPath = [[evidence stringByDeletingPathExtension] stringByAppendingString:@"-short.png"];
            Expect([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:shortPath atomically:YES],
                "short History evidence writes a headless PNG");
        }
        NSScrollView* viewport = (id)Find(history.view,NSScrollView.class);
        Expect(viewport.documentView.bounds.size.height > viewport.contentView.bounds.size.height,
            "short History scrolls its actions instead of clipping them");
        NSRect firstVersion = [table convertRect:[table rectOfRow:0] toView:viewport.documentView];
        Expect(NSContainsRect(viewport.documentVisibleRect,firstVersion),
            "minimum missing-source History shows a complete version before recovery actions");
        for (NSString* title in @[@"Compare with Latest",@"Actions",@"Find Document…",@"Save New Copy As…"]) {
            NSButton* button = Button(history.view,title);
            [button scrollRectToVisible:button.bounds];
            NSRect frame = [button convertRect:button.bounds toView:viewport.documentView];
            Expect(!button.hiddenOrHasHiddenAncestor && button.bounds.size.height >= 20 &&
                NSContainsRect(viewport.documentVisibleRect,frame),"History actions are reachable at minimum window size");
        }
        Capture(container,evidence,@"actions-minimum");
        [host setContentSize:NSMakeSize(240,620)];
        host.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [container layoutSubtreeIfNeeded];
        [viewport.contentView scrollToPoint:NSZeroPoint]; [viewport reflectScrolledClipView:viewport.contentView];
        Capture(container,evidence,@"dark");
        host.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        store.fixturePath = [root.path stringByAppendingPathComponent:@"Original.md"];
        [history reload];
        Expect(Await(^BOOL { return [[(NSTextField*)[history valueForKey:@"status"] stringValue]
            containsString:@"Original available"]; }),"linked History refreshes source context");
        [container layoutSubtreeIfNeeded];
        [viewport.contentView scrollToPoint:NSZeroPoint];
        Capture(container,evidence,@"linked");
        NSButton* keep = (id)Identified(history.view,@"HistoryKeepForever");
        Expect(keep.hidden,"unlimited storage hides History retention action");
        store.storageLimit = 1000000000;
        [NSNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionSettingsChanged" object:store];
        Expect(Await(^BOOL { return !keep.hidden; }),"applying a cap reveals retention without reopening History");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        Expect([keep.title isEqual:@"Keep forever"] && keep.enabled,"unkept history selection offers Keep forever");
        store.kept = YES; [history reload];
        Expect(Await(^BOOL { return [keep.title isEqual:@"Stop keep forever"]; }),"kept history selection offers Stop keep forever");
        [host setContentSize:NSMakeSize(176,296)]; [container layoutSubtreeIfNeeded];
        Expect(NSWidth(keep.frame) <= NSWidth(history.view.bounds),"full retention label fits minimum-width History");
        store.storageLimit = 0;
        [NSNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionSettingsChanged" object:store];
        Expect(Await(^BOOL { return keep.hidden; }) && store.kept,"unlimited storage hides retention without clearing existing marks");
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        [history menuNeedsUpdate:table.menu];
        NSMenuItem* compare=[table.menu itemWithTitle:@"Compare with Latest"];
        Expect(compare.enabled && [compare.representedObject[@"id"] isEqual:@"old"],
            "older history row offers Compare with Latest for its own snapshot");
        if(compare) {
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            [NSApp sendAction:compare.action to:compare.target from:compare];
            Expect([history.comparedVersion isEqual:@"old"] && !history.comparedPrevious,
                "history context comparison follows the clicked version, regardless of current selection");
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
        }
        NSMenuItem* remove=[table.menu itemWithTitle:@"Delete version…"];
        Expect(remove.enabled && [remove.representedObject[@"version"][@"id"] isEqual:@"old"],
            "older version has scoped deletion in its context menu");
        if(remove) {
            [NSApp sendAction:remove.action to:remove.target from:remove];
            Expect([history.deletionVersion isEqual:@"old"] && !history.deletionPrevious && !store.deletedVersion,
                "deletion requests confirmation before touching stored copies");
            history.pendingDeletion(NO);
            Expect(!store.deletedVersion,"cancelling deletion preserves stored copies");
            [NSApp sendAction:remove.action to:remove.target from:remove];
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            history.pendingDeletion(YES);
            Expect(Await(^BOOL { return [store.deletedVersion isEqual:@"old"]; }),
                "selection changes during confirmation cannot retarget deletion");
            Expect(Await(^BOOL { return ![[history valueForKey:@"deletionPending"] boolValue]; }),"version deletion completes");
        }
        [history menuNeedsUpdate:table.menu];
        NSMenuItem* clear=[table.menu itemWithTitle:@"Delete all previous backups…"];
        Expect(![table.menu itemWithTitle:@"Compare with Latest"],"latest history row has no self-comparison action");
        Expect(clear.enabled && ![table.menu itemWithTitle:@"Delete version…"],
            "linked original offers previous-backup cleanup instead of deleting itself");
        if(clear) {
            [NSApp sendAction:clear.action to:clear.target from:clear];
            Expect(history.deletionPrevious,"original context action has previous-backups scope");
            history.pendingDeletion(YES);
            Expect(Await(^BOOL { return [store.clearedDocument isEqual:@"fixture"]; }),"original clears only its document's previous backups");
            Expect(Await(^BOOL { return ![[history valueForKey:@"deletionPending"] boolValue]; }),"previous-backup deletion completes");
        }
        store.empty = YES; [history reload];
        Expect(Await(^BOOL { return table.numberOfRows == 0; }),"empty History reloads without opening a document");
        Expect(!Button(history.view,@"Compare with Latest").enabled &&
            ![actions itemWithTitle:@"Save a Copy…"].enabled && [actions itemWithTitle:@"Manage Collection…"].enabled,
            "empty History disables version actions and preserves Collection access");
        Expect([[(NSTextField*)[history valueForKey:@"status"] stringValue] isEqual:@"No saved versions yet"],
            "empty History explains the absent versions");
        Capture(container,evidence,@"empty");
        Expect(!host.visible,"all History interaction tests remain headless");
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        if (!failures) puts("SPDFMacCollectionHistorySidebarTests passed");
    }
    return failures ? 1 : 0;
}
