#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionWindowPrivate.h"
#import "SPDFMacCollectionHistory.h"
#import "SPDFMacCollectionCompareViews.h"
#import "SPDFMacCollectionWindowHistory.h"

// The comparison controller stays private in the app; the test exercises the
// real constructor without calling the facade that orders its window onscreen.
@interface SPDFCollectionCompareController : NSWindowController
- (instancetype)initWithOldLabel:(NSString*)oldLabel newLabel:(NSString*)newLabel;
@end

static int failures;
static void Expect(NSString* label, BOOL value) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",label.UTF8String); failures++; }
}
#import "SPDFMacCollectionThumbnailChecks.h"
#import "SPDFMacCollectionRetentionChecks.h"
#import "SPDFMacCollectionOpenChecks.h"
static void Layout(NSWindow* window, NSSize size) {
    [window setContentSize:size];
    [window.contentView layoutSubtreeIfNeeded];
    Expect(@"headless layout never shows a window",!window.visible);
}
static NSView* Label(NSView* view, NSString* string) {
    if ([view isKindOfClass:NSTextField.class] && [[(NSTextField*)view stringValue] isEqual:string]) return view;
    for (NSView* child in view.subviews) { NSView* found = Label(child,string); if (found) return found; }
    return nil;
}
static NSView* Descendant(NSView* view, Class cls) {
    if ([view isKindOfClass:cls]) return view;
    for (NSView* child in view.subviews) {
        NSView* found = Descendant(child,cls); if (found) return found;
    }
    return nil;
}
static NSView* Identified(NSView* view,NSString* identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView* child in view.subviews) { NSView* found = Identified(child,identifier); if (found) return found; }
    return nil;
}
#import "SPDFMacCollectionWorkspaceChecks.h"
#import "SPDFMacCollectionStorageControlsChecks.h"
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        CheckCollectionThumbnails();
        CheckCollectionStorageControls();
        NSURL* root = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
        SPDFMacCollectionStore* store = [[SPDFMacCollectionStore alloc] initWithRootURL:root];
        SPDFMacCollectionWindow* manager = nil;
        @try {
            manager = [[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path, BOOL archived) {
                (void)path; (void)archived;
            }];
            Layout(manager.window,NSMakeSize(1100,690));
            __block BOOL returnedToReader = NO;
            manager.returnHandler = ^{ returnedToReader = YES; };
            [manager returnToReader:nil];
            Expect(@"Return to reader routes activation without discarding Collection",returnedToReader && manager.window.contentView != nil);
            Expect(@"manager construction starts no capture or thumbnail work",manager.thumbnailQueue.operationCount == 0 &&
                ![NSFileManager.defaultManager fileExistsAtPath:root.path]);
            Expect(@"document pane uses the available window width",fabs(NSWidth(manager.documentsPane.frame)-(NSWidth(manager.window.contentView.bounds)-125)) < 1);
            Expect(@"manager list has a readable viewport",manager.listScroll.frame.size.width > 300 &&
                manager.listScroll.frame.size.height > 350);
            Expect(@"Collection navigation has only Documents and Settings",manager.documentsButton && manager.settingsButton &&
                ![manager.viewPicker.itemTitles containsObject:@"Storage"] && manager.documentsPane && manager.settingsPane);
            Expect(@"unlimited is the default storage setting",manager.limitField.doubleValue == 0);
            Expect(@"location is displayed before loading documents",[manager.locationField.stringValue isEqual:root.path]);
            [manager showDestination:@"Settings"];
            Layout(manager.window,NSMakeSize(940,560));
            Expect(@"Settings replaces the document pane",manager.documentsPane.hidden && !manager.settingsPane.hidden);
            Expect(@"storage controls belong exclusively to Settings",[manager.limitField isDescendantOf:manager.settingsPane] &&
                ![manager.limitField isDescendantOf:manager.documentsPane]);
            Expect(@"settings controls fit the minimum window",NSContainsRect(manager.settingsPane.bounds,
                [manager.limitPicker convertRect:manager.limitPicker.bounds toView:manager.settingsPane]));
            CheckCollectionSettingsApplyPlacement(manager);
            [manager showDestination:@"Documents"]; Layout(manager.window,NSMakeSize(1100,690));
            Expect(@"Documents removes the permanent options tower",!Label(manager.window.contentView,@"Document options") &&
                fabs(manager.listScroll.frame.size.width-NSWidth(manager.documentsPane.bounds)) < 1);
            Expect(@"navigation uses the mockup compact type and height",manager.documentsButton.font.pointSize == 12 &&
                fabs(manager.documentsButton.frame.size.height-30)<1);
            Expect(@"navigation accessibility names describe destinations instead of symbols",
                [manager.documentsButton.accessibilityLabel isEqual:@"Documents"] && [manager.settingsButton.accessibilityLabel isEqual:@"Settings"]);
            NSSearchFieldCell* searchCell = (id)manager.search.cell;
            NSRect searchText = [searchCell searchTextRectForBounds:manager.search.bounds];
            NSRect searchIcon = [searchCell searchButtonRectForBounds:manager.search.bounds];
            Expect(@"search text is centered with a separate icon inset",NSMinX(searchText)>=29 &&
                fabs(NSMidY(searchText)-NSMidY(manager.search.bounds))<=1 && NSMinX(searchText)>NSMaxX(searchIcon));
            Expect(@"search field stays editable after custom cell installation",manager.search.editable && manager.search.selectable);
            [manager.window makeFirstResponder:manager.search]; [manager.search selectText:nil];
            NSTextView* searchEditor = (id)manager.search.currentEditor;
            Expect(@"focusing search creates the real field editor",searchEditor != nil);
            if (!searchEditor) searchEditor = (id)[manager.window fieldEditor:YES forObject:manager.search];
            [searchCell selectWithFrame:manager.search.bounds inView:manager.search editor:searchEditor
                delegate:manager.search start:0 length:0];
            NSRect editing = searchEditor ? [searchEditor convertRect:searchEditor.bounds toView:manager.search] : NSZeroRect;
            Expect(@"focused search editor preserves the icon inset and centered text",searchEditor &&
                NSMinX(editing)>=NSMinX(searchText)-1 && fabs(NSMidY(editing)-NSMidY(searchText))<=2);
            [searchCell endEditing:searchEditor]; [manager.window makeFirstResponder:manager.table];
            Expect(@"storage defaults to dynamic capacity at 80 percent",[manager.limitPicker.title containsString:@"Dynamic"] &&
                manager.limitField.hidden && manager.dynamicPercent.integerValue==80 && !manager.dynamicPercent.hidden);
            [manager.limitPicker selectItemAtIndex:1];
            [manager performSelector:@selector(changeLimitMode:) withObject:manager.limitPicker];
            Expect(@"custom storage policy updates before Apply and reveals its field",!manager.limitField.hidden &&
                [manager.storagePolicy.stringValue containsString:@"Least opened"] && [manager.settingsStatus.stringValue containsString:@"Pending change"] &&
                [manager.settingsStatus.stringValue containsString:@"Applied limit: Dynamic"]);
            Expect(@"changing cap mode does not apply or delete anything",[store.settings[@"storageLimitBytes"] unsignedLongLongValue] == 0);
            manager.limitField.stringValue = @"0"; [manager updateStoragePolicy];
            Expect(@"zero custom cap describes unlimited accurately",[manager.storagePolicy.stringValue containsString:@"No automatic deletion"]);
            [manager.limitPicker selectItemAtIndex:0]; [manager performSelector:@selector(changeLimitMode:) withObject:manager.limitPicker];
            [store updateSettings:@{@"storageMode":@"unlimited",@"storageLimitBytes":@0} error:nil];
            NSMenu* actions = [NSMenu new]; [manager populateDocumentMenu:actions];
            Expect(@"unlimited Collection exposes document commands without retention or capture toggles",actions.numberOfItems == 7 &&
                [actions itemWithTitle:@"Save a Copy…"] && [actions itemWithTitle:@"Delete all previous backups…"]);
            Expect(@"Collection does not offer comparison with its own latest snapshot",![actions itemWithTitle:@"Compare with Latest"]);
            NSString* evidence = NSProcessInfo.processInfo.environment[@"SPDF_COLLECTION_WINDOW_EVIDENCE"];
            if (evidence.length) {
                NSBitmapImageRep* bitmap = [manager.window.contentView bitmapImageRepForCachingDisplayInRect:manager.window.contentView.bounds];
                [manager.window.contentView cacheDisplayInRect:manager.window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:evidence atomically:YES];
            }
            NSDictionary* fixtureDocument = @{@"id": @"fixture-document", @"title": @"Bridge Notes.pdf",
                @"path": @"/tmp/Bridge Notes.pdf", @"versions": @[]};
            NSDictionary* fixtureVersion = @{@"id": @"fixture-version", @"capturedAt": @1727092800,
                @"encrypted": @YES};
            manager.rows = @[@{@"document": fixtureDocument, @"version": fixtureVersion}];
            [manager.table reloadData];
            if (evidence.length) {
                Layout(manager.window,NSMakeSize(850,590));
                NSBitmapImageRep* bitmap = [manager.window.contentView bitmapImageRepForCachingDisplayInRect:manager.window.contentView.bounds];
                [manager.window.contentView cacheDisplayInRect:manager.window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:evidence atomically:YES];
                [manager showDestination:@"Settings"]; Layout(manager.window,NSMakeSize(680,460));
                bitmap = [manager.window.contentView bitmapImageRepForCachingDisplayInRect:manager.window.contentView.bounds];
                [manager.window.contentView cacheDisplayInRect:manager.window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                    writeToFile:[evidence.stringByDeletingPathExtension stringByAppendingString:@"-settings.png"] atomically:YES];
                [manager showDestination:@"Documents"];
                Layout(manager.window,NSMakeSize(940,560));
            }
            NSMutableDictionary* latestDoc = [fixtureDocument mutableCopy]; latestDoc[@"latestVersionID"] = fixtureVersion[@"id"];
            latestDoc[@"versions"] = @[fixtureVersion];
            manager.rows = @[@{@"document":latestDoc,@"version":fixtureVersion}];
            Expect(@"Documents never displays the History-only Latest pill",!Identified([manager resultCellForRow:0],@"CollectionLatestBadge"));
            CheckCollectionThumbnailRequests(manager);
            NSString* indexedPath = [root.path stringByAppendingString:@"-Field Notes.md"];
            [@"# Greenhouse log\nThe orchid bloomed overnight.\n" writeToFile:indexedPath atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
            [store updateSettings:@{@"choice":@"enabled"} error:nil];
            NSDictionary* indexed = [store capturePath:indexedPath reason:@"Opened" error:nil];
            [manager.viewPicker selectItemAtIndex:0]; manager.search.stringValue = @"orchid"; manager.rows = @[];
            Expect(@"stale AppKit row-height requests are safe during a result refresh",[manager tableView:manager.table heightOfRow:0] == 100);
            [manager.table reloadData];
            [manager reload:nil];
            NSDate* filterDeadline = [NSDate dateWithTimeIntervalSinceNow:2];
            while (!manager.rows.count && filterDeadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:
                    [NSDate dateWithTimeIntervalSinceNow:.01]];
            Expect(@"manager content search includes an indexed document whose title does not match",
                indexed && manager.rows.count == 1 &&
                [manager.rows.firstObject[@"document"][@"id"] isEqual:indexed[@"id"]]);
            Expect(@"search uses the same list as browsing",!manager.listScroll.hidden);
            NSDictionary* result = manager.rows.firstObject;
            Expect(@"native search retains exact text contexts and version identity",[result[@"matches"] count] > 0 && result[@"version"][@"id"]);
            NSView* resultCell = [manager resultCellForRow:0];
            NSImageView* thumbnail = (id)Descendant(resultCell,NSImageView.class);
            Expect(@"text results include a saved-page thumbnail",thumbnail != nil);
            NSArray* matches = result[@"matches"];
            Expect(@"context highlights are available",[matches.firstObject[@"ranges"] count] > 0);
            if (evidence.length) {
                NSDate* previewDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
                while (manager.pendingThumbnails.count && previewDeadline.timeIntervalSinceNow > 0)
                    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
                Layout(manager.window,NSMakeSize(850,590));
                NSView* renderedRow = [manager.table viewAtColumn:0 row:0 makeIfNecessary:YES];
                [renderedRow layoutSubtreeIfNeeded];
                NSImageView* renderedPreview = (id)Descendant(renderedRow,NSImageView.class);
                Expect(@"Collection preview and title use the approved side-by-side geometry",
                    fabs(NSWidth(renderedPreview.frame)-65)<1 && fabs(NSHeight(renderedPreview.frame)-88)<1 &&
                    NSMinX(Identified(renderedRow,@"CollectionResultTitle").frame) > NSMaxX(renderedPreview.frame));
                Expect(@"Collection row fits its viewport without horizontal overflow",NSWidth(renderedRow.bounds) <= NSWidth(manager.listScroll.contentView.bounds)+1);
                [manager.window.contentView layoutSubtreeIfNeeded];
                NSBitmapImageRep* bitmap = [manager.window.contentView bitmapImageRepForCachingDisplayInRect:manager.window.contentView.bounds];
                [manager.window.contentView cacheDisplayInRect:manager.window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:
                    [[evidence stringByDeletingPathExtension] stringByAppendingString:@"-search.png"] atomically:YES];
                [manager showDestination:@"Settings"]; [manager.window.contentView layoutSubtreeIfNeeded];
                [manager.window.contentView cacheDisplayInRect:manager.window.contentView.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:
                    [[evidence stringByDeletingPathExtension] stringByAppendingString:@"-settings.png"] atomically:YES];
                [manager showDestination:@"Documents"];
            }
            manager.search.stringValue = @"orchid";
            [manager showDestination:@"Settings"]; [manager showDestination:@"Documents"];
            Expect(@"settings navigation preserves query and document rows",[manager.search.stringValue isEqual:@"orchid"] && manager.rows.count == 1);
            NSMutableDictionary* remembered = [manager.rows.firstObject mutableCopy];
            remembered[@"selectedMatchIndex"] = @0; remembered[@"selectedMatch"] = matches.firstObject;
            remembered[@"selectedPage"] = matches.firstObject[@"page"] ?: @0;
            manager.rows = @[remembered];
            NSString* resultKey = [NSString stringWithFormat:@"%@/%@",remembered[@"document"][@"id"],remembered[@"version"][@"id"]];
            [manager.expandedResults addObject:resultKey];
            [manager.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            CheckCollectionOpenTargets(manager,store);
            __block NSDictionary* navigation = nil;
            manager.navigateHandler = ^(NSDictionary* doc, NSDictionary* version, NSUInteger page, NSString* query, BOOL history) {
                navigation = @{@"document":doc,@"version":version ?: @{},@"page":@(page),@"query":query,@"history":@(history)};
            };
            [manager showHistoryForDocument:remembered[@"document"] version:remembered[@"version"]];
            Expect(@"History requests reader navigation without a second history view",[navigation[@"history"] boolValue] &&
                [navigation[@"version"][@"id"] isEqual:remembered[@"version"][@"id"]] && !manager.historyPane &&
                [manager.destination isEqual:@"Documents"]);
            NSButton* matchButton = [NSButton new]; matchButton.tag = 0; matchButton.identifier = @"0";
            [manager selectSearchMatch:matchButton];
            Expect(@"search result opens its saved page in the reader without History",navigation && ![navigation[@"history"] boolValue] &&
                [navigation[@"page"] isEqual:matches.firstObject[@"page"]] && [navigation[@"query"] isEqual:@"orchid"] && !manager.historyPane);
            Expect(@"reader navigation keeps the selected context and expanded result",
                manager.table.selectedRow == 0 && manager.rows.firstObject[@"selectedMatch"] &&
                [manager.rows.firstObject[@"selectedPage"] isEqual:remembered[@"selectedPage"]] &&
                [manager.expandedResults containsObject:resultKey] && [manager.search.stringValue isEqual:@"orchid"]);
            // Context is JSON-safe and stable across sorting. Scroll restoration runs after
            // native row layout, so returning from a long result list does not jump to its top.
            NSMutableArray* longRows = [NSMutableArray array];
            for (NSUInteger n=0;n<15;n++) {
                NSMutableDictionary* copy = [remembered mutableCopy]; NSMutableDictionary* version = [copy[@"version"] mutableCopy];
                version[@"id"] = [NSString stringWithFormat:@"layout-%lu",(unsigned long)n]; copy[@"version"] = version;
                [longRows addObject:copy];
            }
            manager.rows = longRows; [manager.table reloadData];
            [manager.table selectRowIndexes:[NSIndexSet indexSetWithIndex:7] byExtendingSelection:NO];
            [manager.window.contentView layoutSubtreeIfNeeded];
            [manager.listScroll.contentView scrollToPoint:NSMakePoint(0,320)];
            NSDictionary* browsing = [manager captureBrowseState];
            Expect(@"browsing state can persist in the JSON manifest",[NSJSONSerialization isValidJSONObject:browsing]);
            Expect(@"browsing state contains only the remaining list position",browsing[@"listY"] && !browsing[@"gridY"] && !browsing[@"gridX"]);
            NSMutableArray* reordered = [[[longRows reverseObjectEnumerator] allObjects] mutableCopy];
            [manager restoreBrowseState:browsing toRows:reordered query:@"orchid"];
            manager.rows = reordered; [manager.table reloadData]; [manager restoreBrowseSelectionAndScroll:browsing];
            Expect(@"restored native list keeps its scroll offset",fabs(manager.listScroll.contentView.bounds.origin.y-320) < 1);
            Expect(@"restored selection follows version identity",[[manager selectedVersion][@"id"] isEqual:@"layout-7"]);
            NSMutableArray* changedQuery = [NSMutableArray arrayWithObject:@{@"document":remembered[@"document"],
                @"version":remembered[@"version"],@"matches":matches}];
            [manager restoreBrowseState:browsing toRows:changedQuery query:@"different query"];
            Expect(@"changed searches never inherit an unrelated hit",!changedQuery.firstObject[@"selectedMatch"]);
            dispatch_sync(manager.preferenceQueue,^{});
            [@"# Greenhouse log\nThe orchid has a new leaf.\n" writeToFile:indexedPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary* newer = [store capturePath:indexedPath reason:@"Modified" continuingDocumentID:indexed[@"id"] error:nil];
            Expect(@"latest-only fixture contains two versions of one document",[newer[@"id"] isEqual:indexed[@"id"]] && [newer[@"versions"] count] == 2);
            NSString* oldVersion = remembered[@"version"][@"id"];
            [store updateSettings:@{@"managerDestination":@"Documents",@"managerLayout":@1,@"managerView":@1,@"managerSearchScope":@1,@"managerQuery":@""} error:nil];
            __block NSString* openedPath = nil;
            __block BOOL openedArchive = YES;
            SPDFMacCollectionWindow* latestOnly = [[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived) {
                openedPath = path; openedArchive = archived;
            }];
            Expect(@"legacy Versions preference migrates to All Documents with no version controls",
                latestOnly.viewPicker.selectedItem.tag == 0 && ![latestOnly.viewPicker.itemTitles containsObject:@"Versions"] &&
                !Label(latestOnly.window.contentView,@"All saved versions"));
            Expect(@"legacy thumbnail preference opens the document list",!latestOnly.listScroll.hidden &&
                !Descendant(latestOnly.window.contentView,NSCollectionView.class));
            NSMenu* viewOptions = [latestOnly collectionViewOptionsMenu];
            Expect(@"Collection offers filtering and sorting without layout modes",viewOptions.numberOfItems == 2 &&
                [viewOptions itemWithTitle:@"Show"] && [viewOptions itemWithTitle:@"Sort"] && ![viewOptions itemWithTitle:@"Layout"]);
            NSMenuItem* sortByName = [[viewOptions itemWithTitle:@"Sort"].submenu itemWithTitle:@"Name"];
            Expect(@"Sort uses its new menu position after removing Layout",[sortByName.representedObject isEqual:@[@1,@2]]);
            void (^refreshLatest)(id) = ^(id sender) {
                NSArray* previous = latestOnly.rows; [latestOnly reload:sender];
                NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
                while (latestOnly.rows == previous && deadline.timeIntervalSinceNow>0)
                    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
                Expect(@"latest-only manager refresh completes",latestOnly.rows != previous);
            };
            refreshLatest(nil);
            Expect(@"Documents shows exactly one canonical latest version despite legacy all-version preferences",latestOnly.rows.count == 1 &&
                [latestOnly.rows.firstObject[@"version"][@"id"] isEqual:newer[@"latestVersionID"]]);
            [latestOnly.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            CheckCollectionRetentionMenu(latestOnly);
            [latestOnly openOriginal:nil];
            Expect(@"Open Original uses the editable original",
                [openedPath isEqual:indexedPath] && !openedArchive);
            NSString* displaced = [indexedPath stringByAppendingString:@".moved"];
            [NSFileManager.defaultManager moveItemAtPath:indexedPath toPath:displaced error:nil];
            openedPath = nil; [latestOnly preview:nil];
            NSDate* previewDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (!openedPath && previewDeadline.timeIntervalSinceNow>0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            Expect(@"missing original opens latest saved copy without a blocking locate prompt",
                openedArchive && [store editableInfoForPath:openedPath]!=nil);
            [NSFileManager.defaultManager moveItemAtPath:displaced toPath:indexedPath error:nil];
            [store setKeep:YES versionID:oldVersion documentID:indexed[@"id"] error:nil];
            [latestOnly.viewPicker selectItemWithTag:3]; refreshLatest(latestOnly.viewPicker);
            Expect(@"Kept filter shows the latest document when only an older version is kept",latestOnly.rows.count == 1 &&
                [latestOnly.rows.firstObject[@"version"][@"id"] isEqual:newer[@"latestVersionID"]] &&
                ![latestOnly.rows.firstObject[@"version"][@"keep"] boolValue]);
            latestOnly.search.stringValue = @"bloomed"; refreshLatest(latestOnly.search);
            Expect(@"Documents search excludes text found only in an older version",latestOnly.rows.count == 0);
            latestOnly.search.stringValue = @"new leaf"; refreshLatest(latestOnly.search);
            Expect(@"Documents search finds the latest version only once",latestOnly.rows.count == 1 &&
                [latestOnly.rows.firstObject[@"version"][@"id"] isEqual:newer[@"latestVersionID"]]);
            dispatch_sync(latestOnly.preferenceQueue,^{});
            Expect(@"tagged filters preserve existing preference identifiers",[store.settings[@"managerView"] integerValue] == 3 &&
                [store.settings[@"managerSearchScope"] integerValue] == 0);
            [latestOnly.window close]; dispatch_sync(latestOnly.preferenceQueue,^{});

            [store updateSettings:@{@"managerDestination":@"History",@"managerHistoryDocumentID":indexed[@"id"],
                @"managerHistoryVersionID":oldVersion,@"managerHistoryPage":@1,@"managerQuery":@"orchid",
                @"managerBrowseState":browsing} error:nil];
            SPDFMacCollectionWindow* restored = [[SPDFMacCollectionWindow alloc] initWithStore:store open:^(NSString* path,BOOL archived) {
                (void)path; (void)archived;
            }];
            Expect(@"constructing a restored manager defers history loading",!restored.historyPane && !restored.hasLoadedResults);
            [restored reload:nil];
            NSDate* restoreDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (!restored.hasLoadedResults && restoreDeadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            Expect(@"legacy embedded History resumes Documents without opening another history view",restored.hasLoadedResults &&
                [restored.destination isEqual:@"Documents"] && !restored.historyPane && ![restored historySelectedVersion]);
            Expect(@"history restoration never shows a window",!restored.window.visible);
            [restored.window close]; dispatch_sync(restored.preferenceQueue,^{});
            NSString* mdownPath = [root.path stringByAppendingString:@"-Thumbnail.mdown"];
            [@"# Markdown thumbnail\nA visible saved page.\n" writeToFile:mdownPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSDictionary* mdown = [store capturePath:mdownPath reason:@"Opened" error:nil];
            [manager requestThumbnail:@{@"document":mdown,@"version":[mdown[@"versions"] lastObject],@"selectedPage":@1} key:@"mdown-thumbnail"];
            NSDate* thumbnailDeadline = [NSDate dateWithTimeIntervalSinceNow:3];
            while (![manager.thumbnailCache objectForKey:@"mdown-thumbnail"] && thumbnailDeadline.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            Expect(@"mdown saved pages render as Markdown thumbnails",[manager.thumbnailCache objectForKey:@"mdown-thumbnail"] != nil);
            [NSFileManager.defaultManager removeItemAtPath:mdownPath error:nil];
            [NSFileManager.defaultManager removeItemAtPath:indexedPath error:nil];
        } @catch (NSException* exception) {
            fprintf(stderr,"FAIL: manager constructor/layout raised %s\n",exception.description.UTF8String); failures++;
        }
        SPDFMacCollectionHistoryController* history = nil;
        NSWindow* historyHost = nil;
        @try {
            history = [[SPDFMacCollectionHistoryController alloc] initWithStore:store documentID:@"missing"
                open:^(NSString* path, BOOL archived) { (void)path; (void)archived; }];
            historyHost = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,280,620)
                styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
            historyHost.releasedWhenClosed = NO;
            history.showsDocumentTitle = NO;
            historyHost.contentViewController = history;
            Expect(@"integrated History suppresses the duplicate document filename",Identified(history.view,@"HistoryDocumentTitle").hidden);
            Layout(historyHost,NSMakeSize(280,620));
            NSScrollView* list = (id)Descendant(history.view,NSScrollView.class);
            Expect(@"history rows fit the sidebar",list.frame.size.width > 200 && list.frame.size.height > 80);
        } @catch (NSException* exception) {
            fprintf(stderr,"FAIL: history constructor/layout raised %s\n",exception.description.UTF8String); failures++;
        }
        SPDFCollectionCompareController* comparison = nil;
        @try {
            comparison = [[SPDFCollectionCompareController alloc] initWithOldLabel:@"Fixture · Old" newLabel:@"Fixture · New"];
            Layout(comparison.window,NSMakeSize(1200,820));
            SPDFCollectionComparePane* pane = (id)Descendant(comparison.window.contentView,SPDFCollectionComparePane.class);
            Expect(@"comparison reader has a useful viewport",pane.reader.frame.size.width > 400 &&
                pane.reader.frame.size.height > 400);
            Layout(comparison.window,NSMakeSize(980,520));
            Expect(@"comparison fits its minimum window",pane.reader.frame.size.width > 300 && pane.reader.frame.size.height > 250);
        } @catch (NSException* exception) {
            fprintf(stderr,"FAIL: comparison constructor/layout raised %s\n",exception.description.UTF8String); failures++;
        }
        // Opening Collection must survive real entries without saved versions.
        NSString* excludedPath = [root.path stringByAppendingString:@"-Excluded.md"];
        NSString* failedPath = [root.path stringByAppendingString:@"-Missing.md"];
        [store setExcluded:YES path:excludedPath error:nil];
        NSError* captureError = nil;
        [store capturePath:failedPath reason:@"Opened" error:&captureError];
        Expect(@"failed initial capture creates an uncaptured document fixture",captureError &&
            [store documentForPath:failedPath] && ![[store documentForPath:failedPath][@"versions"] count]);
        manager.search.stringValue = @""; [manager.viewPicker selectItemWithTag:0];
        [manager showDestination:@"Documents"];
        for (NSInteger sort=0;sort<3;sort++) {
            [manager.sortPicker selectItemAtIndex:sort];
            NSArray* previous = manager.rows; [manager reload:nil];
            NSDate* finish = [NSDate dateWithTimeIntervalSinceNow:3];
            while (manager.rows == previous && finish.timeIntervalSinceNow>0)
                [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            Expect(@"all sort modes load saved and uncaptured documents",manager.rows != previous &&
                manager.rows.count == store.documents.count && manager.rows.count > 2);
            if (sort<2) {
                BOOL reachedUndated = NO;
                for (NSDictionary* row in manager.rows) {
                    BOOL dated = row[@"version"][@"capturedAt"] != nil;
                    Expect(@"uncaptured rows remain after dated rows in both date orders",!reachedUndated || !dated);
                    if (!dated) reachedUndated = YES;
                }
                Expect(@"uncaptured entries remain visible",reachedUndated);
            }
        }
        CheckCollectionPDFWorkspace(manager,store);
        dispatch_sync(manager.preferenceQueue,^{});
        [manager.window close]; [historyHost close]; [comparison.window close];
        NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:.15];
        while ([deadline timeIntervalSinceNow] > 0)
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:deadline];
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        if (!failures) puts("SPDFMacCollectionWindowTests passed");
    }
    return failures ? 1 : 0;
}
