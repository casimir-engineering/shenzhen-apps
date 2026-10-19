#import "SPDFMacTabDetach.h"

#import "SPDFMacLaunchPrerenderPrivate.h"
#import "SPDFMacModels.h"
#import "SPDFMacTabGroups.h"
#import "SPDFMacSupport.h"

// Defined in ShenzhenPDFMac.mm.
@interface ShenzhenMacDelegate (SPDFMacTabDetachPrivate)
- (void)writeStateObject:(id)object toFile:(NSString*)name;
- (void)rememberActiveTabState;
- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)preferMostRecentActive;
- (void)seedKeepImageColorsForNewTab:(SPDFDocumentTab*)tab;
- (void)showError:(NSString*)message detail:(NSString*)detail;
@end

// A handoff is consumed by the launch it was written for. One left behind by a
// process that died before reading it must not resurface days later on an
// unrelated open, so anything older than this is ignored and deleted.
static const NSTimeInterval kSPDFDetachHandoffMaxAge = 120.0;

@implementation ShenzhenMacDelegate (SPDFMacTabDetach)

- (void)detachTabAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) return;

    [self rememberActiveTabState];
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    NSString* path = [tab.path copy];
    if (path.length == 0) return;

    NSString* executable = NSBundle.mainBundle.executablePath ?: NSProcessInfo.processInfo.arguments.firstObject;
    if (executable.length == 0) return;

    // Written before the launch: the child reads it during its own startup.
    [self writeStateObject:spdf_dictionary_from_tab(tab, 0) toFile:spdf_mac_detach_handoff_name(path)];

    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[ @"--detached-tab", path ];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError* error = nil;
    if (![task launchAndReturnError:&error]) {
        [NSFileManager.defaultManager removeItemAtPath:[self pathForStateFile:spdf_mac_detach_handoff_name(path)]
                                                 error:nil];
        [self showError:@"Could not detach tab" detail:error.localizedDescription ?: @"Launch failed"];
        return;
    }

    [self closeTabAtIndex:index preferMostRecentActive:index == _selectedTabIndex];
}

- (void)adoptDetachedTabForLaunch {
    NSString* path = self.initialPath;
    if (!path.length) return;
    NSString* name = spdf_mac_detach_handoff_name(path);
    NSString* file = [self pathForStateFile:name];
    if (!file.length) return;

    NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
    id stored = attributes ? [self stateObjectFromFile:name] : nil;
    // Consumed either way: a handoff is for exactly one launch.
    [NSFileManager.defaultManager removeItemAtPath:file error:nil];
    if (!attributes || ![stored isKindOfClass:NSDictionary.class]) return;
    if (fabs([attributes.fileModificationDate timeIntervalSinceNow]) > kSPDFDetachHandoffMaxAge) return;

    NSArray* groupTabs = ((NSDictionary*)stored)[@"tabs"];
    if ([groupTabs isKindOfClass:NSArray.class]) {
        [_tabs removeAllObjects];
        for (id item in groupTabs) {
            SPDFDocumentTab* member = spdf_tab_from_dictionary(item);
            if (member) [_tabs addObject:member];
        }
        spdf_tab_groups_normalize(_tabs);
        _selectedTabIndex = 0;
        for (NSUInteger i = 0; i < _tabs.count; ++i)
            if ([_tabs[i].path isEqualToString:_tabs[i].group.lastUsedPath]) _selectedTabIndex = i;
        NSString* frame = ((NSDictionary*)stored)[@"frame"];
        if ([frame isKindOfClass:NSString.class]) {
            NSRect rect = NSRectFromString(frame);
            if (rect.size.width > 100 && rect.size.height > 100) {
                _restoredWindowFrame = rect;
                _restoredWindowContentSize = rect.size;
                _hasRestoredWindowFrame = YES;
            }
        }
        // The launch open must target the remembered document, not always the
        // first group's tab used to name the handoff file.
        if (_tabs.count) self.initialPath = _tabs[(NSUInteger)_selectedTabIndex].path;
        return;
    }

    SPDFDocumentTab* tab = spdf_tab_from_dictionary((NSDictionary*)stored);
    if (!tab.path.length) return;
    if (((NSDictionary*)stored)[@"preservesImageColors"] == nil) [self seedKeepImageColorsForNewTab:tab];
    if (!tab.title.length) tab.title = spdf_display_name_for_path(tab.path);
    // -openPaths: reuses a tab that already exists for the path, so seeding it
    // here is what makes the new window open where the old one was.
    [_tabs removeAllObjects];
    [_tabs addObject:tab];
    _selectedTabIndex = 0;
}

@end
