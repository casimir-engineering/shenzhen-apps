// Links in the reader (portable/friends/PROTOCOL.md § Links): shenzhenpdf://friends/link#… opened from a link's web
// page, and Copy Download Link in File ▸ Share, the tab's menu and the Friends drop panel.
//
// Nothing here runs at launch. -application:openURLs: exists only for URLs the system hands the app (a document
// opened from Finder arrives here too and goes on to -application:openFiles: unchanged); the Share item is added when
// Friends attaches, after the first paint, and removed when it detaches.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacUnifiedSettings.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacFriendsLinkURL.h"
#import "SPDFMacFriendsShareMenu.h"
#import "SPDFMacRemoteLinks.h"

static NSString* const SPDFMacFriendsLinkScheme = @"shenzhenpdf";

@interface ShenzhenMacDelegate (SPDFMacFriendsLinksPrivate)
- (BOOL)friendsValidateShareItem:(NSMenuItem*)item;
- (void)friendsOpenLinkPayload:(NSString*)payload;
- (void)friendsOpenRoute:(NSString*)route;
- (void)friendsAskToTurnOnForLink;
- (void)friendsCopyDownloadLink:(id)sender;
@end

// The menus' target: menu items hold their target weakly, and the reader's own -validateMenuItem: knows nothing of
// these, so this object enables them only while a link can be made for that document.
@interface SPDFMacFriendsShareTarget : NSObject <NSMenuItemValidation>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@end

@implementation SPDFMacFriendsShareTarget
- (BOOL)validateMenuItem:(NSMenuItem*)menuItem {
    return [self.reader friendsValidateShareItem:menuItem];
}
- (void)copyDownloadLink:(id)sender {
    [self.reader friendsCopyDownloadLink:sender];
}
@end

static BOOL SPDFMacFriendsCanShare(NSString* path) {
    BOOL directory = NO;
    return path.length && [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory;
}

@implementation ShenzhenMacDelegate (SPDFMacFriendsLinks)

#pragma mark - Opening a link

- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
    urls = [self openRemoteLinksAmongURLs:urls]; // szpdf: links from web pages (SPDFMacRemoteLinks.h)
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    NSMutableArray<NSString*>* payloads = [NSMutableArray array];
    NSMutableArray<NSString*>* routes = [NSMutableArray array];
    // A URL that fails the check is dropped without a word: no link's page made it, and saying anything about it
    // would only let whoever crafted it put words in front of the person.
    SPDFMacFriendsSortOpenedURLsWithRoutes(urls, SPDFMacFriendsLinkScheme, paths, payloads, routes);
    // The last link wins: the person pressed it most recently.
    if (payloads.count) [self friendsOpenLinkPayload:payloads.lastObject];
    // A notification's click (portable/friends/PROTOCOL.md § Notifications): the dropdown on that conversation.
    else if (routes.count) [self friendsOpenRoute:routes.lastObject];
    // With this method implemented AppKit no longer calls -application:openFiles:, so documents go there as before.
    if (paths.count) [self application:application openFiles:paths];
}

- (void)friendsOpenLinkPayload:(NSString*)payload {
    SPDFMacFriendsReaderState* state = [self friendsState];
    state.pendingLinkPayload = payload;
    if (state.dropdown) [self friendsShowPendingLink];
    else if (!SPDFMacFriendsSettingsState.sharedState.enabled) [self friendsAskToTurnOnForLink];
    // Otherwise Friends attaches after the first paint, which shows it.
}

// Friends off in this app: the click still brings ShenzhenPDF forward, and there is no dropdown to open.
- (void)friendsOpenRoute:(NSString*)route {
    SPDFMacFriendsReaderState* state = [self friendsState];
    state.pendingRoute = route;
    if (state.dropdown) [self friendsShowPendingLink];
    else if (!SPDFMacFriendsSettingsState.sharedState.enabled) state.pendingRoute = nil;
    // Otherwise Friends attaches after the first paint, which shows it.
}

- (void)friendsShowPendingLink {
    SPDFMacFriendsReaderState* state = [self friendsState];
    NSString* route = state.pendingRoute;
    if (route && state.dropdown) {
        state.pendingRoute = nil;
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        if (route.length) [state.dropdown showConversation:route highlightMessage:nil];
        else [state.dropdown showList];
    }
    NSString* payload = state.pendingLinkPayload;
    if (!payload.length || !state.dropdown) return;
    state.pendingLinkPayload = nil;
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [state.dropdown showLinkPayload:payload];
}

// The person pressed Open in ShenzhenPDF on a link's page, and Friends is off in this app. They may never have heard
// of Friends; the page told them what the link is, so this says what is missing and where to turn it on. The link
// opens by itself once Friends is on (-friendsAttach shows the pending link).
- (void)friendsAskToTurnOnForLink {
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"Turn on Friends to open this link";
    alert.informativeText = @"Friends is the part of ShenzhenPDF that adds people and receives files from them, and "
                            @"it’s off on this Mac. Turn it on in Settings and the link opens.";
    [alert addButtonWithTitle:@"Open Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.window.identifier = @"szfriends.alert";
    alert.window.contentView.identifier = @"szfriends.alert";
    __weak ShenzhenMacDelegate* weakSelf = self;
    void (^answer)(NSModalResponse) = ^(NSModalResponse response) {
        ShenzhenMacDelegate* reader = weakSelf;
        if (response != NSAlertFirstButtonReturn) {
            [reader friendsState].pendingLinkPayload = nil;
            return;
        }
        [reader showUnifiedSettings:nil];
        for (NSWindow* window in NSApp.windows) {
            id controller = window.windowController;
            if ([controller isKindOfClass:SPDFMacUnifiedSettingsController.class])
                [(SPDFMacUnifiedSettingsController*)controller selectSection:SPDFMacFriendsSettingsSectionKey];
        }
    };
    if (_window.isVisible) [alert beginSheetModalForWindow:_window completionHandler:answer];
    else answer([alert runModal]);
}

#pragma mark - Copy Download Link

- (SPDFMacFriendsShareTarget*)friendsShareTarget {
    SPDFMacFriendsReaderState* state = [self friendsState];
    if (!state.shareTarget) {
        SPDFMacFriendsShareTarget* target = [SPDFMacFriendsShareTarget new];
        target.reader = self;
        state.shareTarget = target;
    }
    return state.shareTarget;
}

- (void)friendsInstallShareMenu {
    NSMenu* fileMenu = [NSApp.mainMenu itemWithTitle:@"File"].submenu;
    if (fileMenu) SPDFMacFriendsInstallShareItem(fileMenu, [self friendsShareTarget], @selector(copyDownloadLink:));
}

- (void)friendsRemoveShareMenu {
    NSMenu* fileMenu = [NSApp.mainMenu itemWithTitle:@"File"].submenu;
    if (fileMenu) SPDFMacFriendsRemoveShareItem(fileMenu);
}

// SPDFMacTabStripMenus.mm asks for these when it builds a tab's menu (SPDFTabFriendsMenuProviding).
- (void)friendsAddItemsToTabMenu:(NSMenu*)menu path:(NSString*)path {
    if (!path.length || !SPDFMacFriendsCanShare(path) || ![self friendsState].dropdown.offersLinks) return;
    [menu addItem:SPDFMacFriendsCopyDownloadLinkItem([self friendsShareTarget], @selector(copyDownloadLink:), path)];
}

- (NSString*)friendsSharePathForSender:(id)sender {
    id object = [sender isKindOfClass:NSMenuItem.class] ? ((NSMenuItem*)sender).representedObject : nil;
    if ([object isKindOfClass:NSString.class]) return object;
    return [self hasActiveDocument] ? _path : nil;
}

- (BOOL)friendsValidateShareItem:(NSMenuItem*)item {
    return [self friendsState].dropdown.offersLinks && SPDFMacFriendsCanShare([self friendsSharePathForSender:item]);
}

- (void)friendsCopyDownloadLink:(id)sender {
    NSInteger days = SPDFMacFriendsExpiryDays(sender);
    NSString* path = [self friendsSharePathForSender:sender];
    if (!days || !SPDFMacFriendsCanShare(path)) {
        NSBeep();
        return;
    }
    SZFriendsAttachableItem* item = [SZFriendsAttachableItem new];
    item.fileURL = [NSURL fileURLWithPath:path];
    item.title = path.lastPathComponent;
    [self friendsCopyDownloadLinkForItem:item days:days];
}

- (void)friendsBridgeCopyDownloadLinkForItem:(SZFriendsAttachableItem*)item days:(NSInteger)days {
    [self friendsCopyDownloadLinkForItem:item days:days];
}

- (void)friendsCopyDownloadLinkForItem:(SZFriendsAttachableItem*)item days:(NSInteger)days {
    SZFriendsDropdownController* dropdown = [self friendsState].dropdown;
    if (!dropdown) {
        NSBeep();
        return;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    [dropdown copyDownloadLinkForItem:item expiresDays:days completion:^(NSString* message, BOOL copied) {
        ShenzhenMacDelegate* reader = weakSelf;
        if (!reader) return;
        if (!message.length && !copied) NSBeep();
        // The status line, where Copy Path says "Path copied.": until when the link works, or why there is none.
        if (message.length) reader->_statusLabel.stringValue = message;
    }];
}

@end
