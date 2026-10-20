// The reader side of Shenzhen Friends: launch, attach and detach, the title-bar button, the host adapter's bridge
// into the coordinator, the Settings pane's source and following other windows' changes.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import <objc/runtime.h>
#include <unistd.h>

static char kStateKey;
static void* kSearchHiddenContext = &kSearchHiddenContext;

// Attach, detach and cross-window following: private to this file.
@interface ShenzhenMacDelegate (SPDFMacFriendsLifecycle)
- (void)friendsAttach;
- (void)friendsDetachDisabling:(BOOL)disabling;
- (void)friendsObserveOtherWindows;
@end

@implementation SPDFMacFriendsReaderState
- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change
                       context:(void*)context {
    if (context != kSearchHiddenContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    // Presentation mode hides Search (SPDFMacWorkspaceChrome.mm -syncWorkspaceChrome); Friends follows it so the
    // title bar never shows one action without the other.
    self.placement.button.hidden = self.searchButton.hidden;
}
- (void)stopMirroringSearch {
    if (self.searchButton) [self.searchButton removeObserver:self forKeyPath:@"hidden" context:kSearchHiddenContext];
    self.searchButton = nil;
}
- (void)dealloc { [self stopMirroringSearch]; }
@end

@implementation ShenzhenMacDelegate (SPDFMacFriends)

- (NSDictionary*)friendsLaunchWithSettings:(NSDictionary*)settings {
    [[self friendsState].lifecycle launchWithSettings:[settings isKindOfClass:NSDictionary.class] ? settings : nil];
    return settings;
}

- (void)friendsAfterFirstPaint {
    SPDFMacFriendsSetSettingsPaneSource(self);
    [self friendsObserveOtherWindows];
    [[self friendsState].lifecycle firstPaintDidHappen];
    [self friendsShowSettingsIntroductionIfNeeded];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsLifecycle)

- (void)friendsAttach {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (!state.collection)
        state.collection = [[SPDFMacFriendsCollectionSource alloc] initWithStore:SPDFMacCollectionStore.defaultStore];
    state.host = [[SPDFMacFriendsHost alloc] initWithBridge:self bundle:NSBundle.mainBundle
                                                    formats:[NSSet setWithArray:SPDFReadableDocumentExtensions()]];
    state.link = [[SZFriendsHelperLink alloc] initWithHost:state.host];
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.link.onStateChange = ^(SZFriendsLinkState linkState) {
        (void)linkState;
        [weakSelf friendsAssistantAvailabilityDidChange];
    };
    state.dropdown = [[SZFriendsDropdownController alloc] initWithHost:state.host link:state.link];
    [state.link start];
    [state.dropdown install];
    [self friendsInstallShareMenu];
    [self friendsInstallMenu];
    [self friendsShowPendingLink];
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMacFriendsSettingsPaneRefreshNotification object:nil];
}

- (void)friendsDetachDisabling:(BOOL)disabling {
    SPDFMacFriendsReaderState* state = [self friendsState];
    [state.gate endRequest];
    [state.settingsSection sectionDidDisappear];
    [state.dropdown uninstall];
    [self friendsRemoveShareMenu];
    [self friendsRemoveMenu];
    [state.link stopDisablingFriends:disabling];
    state.settingsSection = nil;
    state.dropdown = nil;
    state.link = nil;
    state.host = nil;
    state.services = nil;
    [self friendsAssistantAvailabilityDidChange];
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFMacFriendsSettingsPaneRefreshNotification object:nil];
}

// Windows are processes: a change saved by another window arrives as a distributed notification, and this window
// rereads settings.yaml before anything here can save a stale value over it.
- (void)friendsObserveOtherWindows {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (state.settingsObserver) return;
    NSString* me = [NSString stringWithFormat:@"%d", getpid()];
    __weak ShenzhenMacDelegate* weakSelf = self;
    state.settingsObserver = [NSDistributedNotificationCenter.defaultCenter
        addObserverForName:SPDFMacFriendsSettingsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
        ShenzhenMacDelegate* reader = weakSelf;
        if (!reader || [note.object isEqual:me]) return;
        id settings = [reader stateObjectFromFile:@"settings.yaml"];
        [[reader friendsState].lifecycle
            settingsDidChange:[settings isKindOfClass:NSDictionary.class] ? settings : nil];
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFMacFriendsSettingsPaneRefreshNotification
                                                          object:nil];
    }];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsState)

- (SPDFMacFriendsReaderState*)friendsState {
    SPDFMacFriendsReaderState* state = objc_getAssociatedObject(self, &kStateKey);
    if (state) return state;
    state = [SPDFMacFriendsReaderState new];
    __weak ShenzhenMacDelegate* weakSelf = self;
    // Only object construction here; nothing reads a file, opens a socket or starts a timer.
    state.lifecycle = [[SPDFMacFriendsLifecycle alloc] initWithSettings:SPDFMacFriendsSettingsState.sharedState
        environment:SPDFMacFriendsDefaultLaunchEnvironment()
        helperPath:^NSString* { return SPDFMacFriendsHelperExecutablePath(NSBundle.mainBundle); }
        attach:^{ [weakSelf friendsAttach]; }
        detach:^(BOOL disabling) { [weakSelf friendsDetachDisabling:disabling]; }];
    objc_setAssociatedObject(self, &kStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return state;
}

#pragma mark - SPDFMacFriendsSettingsPaneSource

- (BOOL)friendsEnabled { return SPDFMacFriendsSettingsState.sharedState.enabled; }

- (void)friendsSettingsSetEnabled:(BOOL)enabled {
    [[self friendsState].lifecycle setEnabled:enabled];
    [self savePersistentState];
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:SPDFMacFriendsSettingsDidChangeNotification
        object:[NSString stringWithFormat:@"%d", getpid()] userInfo:nil deliverImmediately:YES];
}

- (NSView*)friendsSettingsSectionViewWillAppear {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (!state.link || !state.host) return nil;
    if (!state.settingsSection)
        state.settingsSection = [[SZFriendsSettingsSection alloc] initWithHost:state.host link:state.link];
    [state.settingsSection sectionWillAppear];
    return state.settingsSection.view;
}

- (void)friendsSettingsSectionDidDisappear { [[self friendsState].settingsSection sectionDidDisappear]; }

#pragma mark - SPDFMacFriendsReaderBridge

- (void)friendsBridgeInstallTitleBarButton:(NSView*)button {
    SPDFMacFriendsReaderState* state = [self friendsState];
    [self friendsBridgeRemoveTitleBarButton:state.placement.button ?: button];
    NSView* content = _window.contentView;
    NSButton* search = SPDFMacFriendsButtonWithAction(content, @selector(showFavoritesPalette:));
    NSLayoutConstraint* strip = SPDFMacFriendsTrailingConstraint(content, _tabStrip);
    CGFloat side = state.host.friendsAppearance.titleBarButtonSize;
    // A title bar that is not the one this placement knows is left untouched rather than overlapped.
    if (!search || !strip) return;
    state.placement =
        SPDFMacFriendsInstallTitleBarButton(button, content, _tabStrip, strip, search, side > 0 ? side : 28);
    if (!state.placement) return;
    state.searchButton = search;
    [search addObserver:state forKeyPath:@"hidden" options:NSKeyValueObservingOptionInitial
                context:kSearchHiddenContext];
}

- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (!state.placement || (button && state.placement.button != button)) return;
    [state stopMirroringSearch];
    [state.placement uninstall];
    state.placement = nil;
}

- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments {
    NSMutableArray* tabs = [_tabs mutableCopy] ?: [NSMutableArray array];
    // The tab on screen first, then the rest by when they were last viewed: the picker's best guess at what the
    // person means.
    SPDFDocumentTab* selected = _selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)tabs.count
        ? tabs[(NSUInteger)_selectedTabIndex] : nil;
    [tabs sortUsingComparator:^NSComparisonResult(SPDFDocumentTab* a, SPDFDocumentTab* b) {
        if (a == selected) return NSOrderedAscending;
        if (b == selected) return NSOrderedDescending;
        return a.lastViewedAt == b.lastViewedAt ? NSOrderedSame :
            (a.lastViewedAt > b.lastViewedAt ? NSOrderedAscending : NSOrderedDescending);
    }];
    NSMutableArray* documents = [NSMutableArray array];
    for (SPDFDocumentTab* tab in tabs) {
        if (!tab.path.length) continue;
        NSMutableDictionary* document = [spdf_dictionary_from_tab(tab, _window.windowNumber) mutableCopy];
        document[@"inThisWindow"] = @YES;
        [documents addObject:document];
    }
    return documents;
}

- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return [self friendsState].collection; }

- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { [self openPaths:paths]; }

- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs {
    if (fileURLs.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:fileURLs];
}

- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services {
    [self friendsState].services = services;
    [self friendsAssistantAvailabilityDidChange];
}

- (SZFriendsAppearance*)friendsBridgeAppearance { return SPDFMacFriendsReaderAppearance(); }

@end
