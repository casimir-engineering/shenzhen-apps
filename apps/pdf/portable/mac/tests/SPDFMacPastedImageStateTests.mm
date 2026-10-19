#import "SPDFMacPastedImageState.h"
#import "SPDFMacImageSaveIntegration.h"
#import "SPDFMacModels.h"

static void Check(BOOL condition, NSString* message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
@implementation ShenzhenMacDelegate
@end
@interface SaveHost : ShenzhenMacDelegate
@property(nonatomic) NSUInteger loads, opens, discards, stateSaves, tabStateSaves;
@property(nonatomic, strong) NSMutableArray* testTabs;
@property(nonatomic) NSInteger testSelectedIndex;
@property(nonatomic, copy) NSString* testPath;
@property(nonatomic, copy) NSString* rememberedPath;
@property(nonatomic, copy) NSString* capturedPath;
@property(nonatomic, copy) NSDictionary* lastSavedTab;
@end
@implementation SaveHost
- (NSMutableArray*)testTabs { return _tabs; }
- (void)setTestTabs:(NSMutableArray*)tabs { _tabs = tabs; }
- (NSInteger)testSelectedIndex { return _selectedTabIndex; }
- (void)setTestSelectedIndex:(NSInteger)index { _selectedTabIndex = index; }
- (NSString*)testPath { return _path; }
- (void)setTestPath:(NSString*)path { _path = path; }
- (SPDFDocumentTab*)selectedTab {
    return _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count ? _tabs[_selectedTabIndex] : nil;
}
- (void)rememberActiveTabState { }
- (void)loadSelectedTab { Check([self.capturedPath isEqual:[self selectedTab].path], @"observed save capture precedes pasted reload"); self.loads++; _path = [self selectedTab].path; }
- (void)openPath:(NSString*)path { Check([self.capturedPath isEqual:path], @"observed save capture precedes ordinary copy open"); self.opens++; _path = path; }
- (void)discardCachedRuntimeForTab:(SPDFDocumentTab*)tab { self.discards++; [tab clearCachedRuntime]; }
- (void)rememberRecentlyOpenedPath:(NSString*)path { self.rememberedPath = path; }
- (void)collectionDidSavePath:(NSString*)path { self.capturedPath = path; }
- (void)updateTabStrip { }
- (void)saveDocumentStateForTab:(SPDFDocumentTab*)tab { self.tabStateSaves++; self.lastSavedTab = spdf_dictionary_from_tab(tab, 0); }
- (void)savePersistentState { self.stateSaves++; }
@end
static SPDFDocumentTab* Tab(NSString* path) {
    SPDFDocumentTab* tab = [SPDFDocumentTab new]; tab.path = path; return tab;
}
int main(void) {
    @autoreleasepool {
        NSString* stateRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("SPDF_STATE_DIR", stateRoot.fileSystemRepresentation, 1);
        NSString* filename = [NSString stringWithFormat:@"Pasted Image %@.png", NSUUID.UUID.UUIDString];
        NSString* path = [[stateRoot stringByAppendingPathComponent:@"Pasted Images"] stringByAppendingPathComponent:filename];
        SPDFDocumentTab* ordinary = Tab(@"/user/notes.png");
        Check(!ordinary.unsavedPastedImage, @"ordinary image has no badge");
        SPDFDocumentTab* pasted = Tab(path);
        pasted.zoom = 2.5; pasted.pageIndex = 1; pasted.scrollOrigin = NSMakePoint(14, 88); pasted.hasScrollOrigin = YES;
        Check(pasted.unsavedPastedImage, @"app-owned capture has red unsaved badge");
        Check(![NSFileManager.defaultManager fileExistsAtPath:stateRoot], @"path classification creates no directories");
        SPDFDocumentTab* restored = spdf_tab_from_dictionary(spdf_dictionary_from_tab(pasted, 0));
        Check(restored.unsavedPastedImage && spdf_copy_document_tab(pasted).unsavedPastedImage,
            @"session restore and tab handoff preserve unsaved state through durable path");
        Check(!Tab([[@"/user/Pasted Images" stringByAppendingPathComponent:filename] copy]).unsavedPastedImage &&
            !Tab([[stateRoot stringByAppendingPathComponent:@"Pasted Images"] stringByAppendingPathComponent:@"normal.png"]).unsavedPastedImage,
            @"similar user folders and ordinary names cannot become unsaved captures");
        SaveHost* host = [SaveHost new]; host.testTabs = [@[pasted, ordinary] mutableCopy]; host.testSelectedIndex = 0;
        NSString* destination = @"/user/saved-image.pdf";
        [host completeImageSaveFromPath:path tab:pasted destination:destination asPDF:YES];
        Check(host.testTabs.count == 2 && host.testTabs[0] == pasted && host.loads == 1 && host.opens == 0 &&
            !pasted.unsavedPastedImage && [pasted.path isEqual:destination], @"save replaces originating tab and clears red dot");
        Check(pasted.zoom == 2.5 && pasted.pageIndex == 1 && NSEqualPoints(pasted.scrollOrigin, NSMakePoint(14,88)),
            @"saving keeps reading position and zoom");
        Check(host.stateSaves == 1 && host.tabStateSaves == 1 && [host.capturedPath isEqual:destination] &&
            [host.rememberedPath isEqual:destination], @"saved destination is persisted, remembered and collected");
        Check(!spdf_tab_from_dictionary(host.lastSavedTab).unsavedPastedImage, @"saved path remains saved after relaunch");
        SPDFDocumentTab* background = Tab(path); host.testTabs[0] = background; host.testSelectedIndex = 1;
        host.testPath = ordinary.path;
        [host completeImageSaveFromPath:path tab:background destination:@"/user/saved-image.png" asPDF:NO];
        Check(host.loads == 1 && host.opens == 0 && host.discards == 1 && host.testSelectedIndex == 1 &&
            [host.testPath isEqual:ordinary.path] && !background.unsavedPastedImage,
            @"background save updates origin without selecting it or changing active document");
        [host.testTabs removeObject:background];
        [host completeImageSaveFromPath:path tab:background destination:@"/user/closed-save.png" asPDF:NO];
        Check(host.opens == 0 && host.loads == 1 && host.testTabs.count == 1, @"completed save never reopens a closed pasted tab");
        [host completeImageSaveFromPath:ordinary.path tab:ordinary destination:@"/user/ordinary-copy.png" asPDF:NO];
        Check(host.opens == 1, @"normal image Save As opens its separate copy");
        printf("SPDFMacPastedImageStateTests passed\n");
    }
    return 0;
}
