// Cmd+J and View ▸ Friends in the reader (SPDFMacFriendsMenu.h): installed by -friendsAttach, removed by
// -friendsDetachDisabling:, so nothing here runs at launch or while Friends is off.
//
// Cmd+J is the Open Friends item's key equivalent, so it reaches -toggleFriends: the way every menu shortcut does:
// the key window's views pass it on (the reader's, or the dropdown's own search field while it has focus) and the
// main menu runs the item. The items have a target of their own because the reader's -validateMenuItem: disables
// actions it does not know while no document is open, and Cmd+K lists only enabled items.

#import "SPDFMacFriendsReaderState.h"
#import "SPDFMacFriendsMenu.h"
#import "mac/SZFriendsDropdownInternal.h"

static void* kToolTipContext = &kToolTipContext;

// The items' target, and the title-bar button's tooltip keeper: the views set the button's tooltip from the helper's
// words whenever the badge changes, and this puts the shortcut back after it each time.
@interface SPDFMacFriendsMenuTarget : NSObject <SPDFMacFriendsMenuActions, NSMenuItemValidation>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@property(nonatomic, nullable) NSButton* observedButton;
- (void)observeButton:(nullable NSButton*)button;
@end

@implementation SPDFMacFriendsMenuTarget

- (SZFriendsDropdownController*)dropdown { return [self.reader friendsState].dropdown; }

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    SZFriendsDropdownController* dropdown = self.dropdown;
    if (item.action == @selector(toggleFriends:)) {
        item.title = dropdown.shown ? SPDFMacFriendsCloseTitle : SPDFMacFriendsOpenTitle;
        return dropdown != nil;
    }
    if (item.action == @selector(makeVisibleNearby:))
        return dropdown && [self.reader friendsState].link.state == SZFriendsLinkStateReady;
    if (item.action == @selector(addFriendByID:)) return dropdown != nil;
    return item.action == @selector(showFriendsSettings:);
}

- (void)toggleFriends:(id)sender {
    (void)sender;
    [self.dropdown toggle];
}

// Opens the dropdown unless it is open; YES when it is open afterwards.
- (BOOL)openDropdown {
    SZFriendsDropdownController* dropdown = self.dropdown;
    if (dropdown && !dropdown.shown) [dropdown toggle];
    return dropdown.shown;
}

// Add by ID is on the profile page, which takes focus in its ID field when it opens.
- (void)addFriendByID:(id)sender {
    (void)sender;
    if ([self openDropdown]) [self.dropdown.content openProfile];
}

- (void)makeVisibleNearby:(id)sender {
    (void)sender;
    if (![self openDropdown]) return;
    SZFriendsDropdownContent* content = self.dropdown.content;
    [content popToList];
    [content.listPage showNearby:YES];
    // What the Nearby tab's own button sends; the tab then shows the countdown, or why it could not start.
    [[self.reader friendsState].link sendIntent:@"start_visibility" fields:nil reply:nil];
}

- (void)showFriendsSettings:(id)sender {
    (void)sender;
    [self.reader friendsShowSettingsSection];
}

- (void)observeButton:(NSButton*)button {
    if (button == self.observedButton) return;
    [self.observedButton removeObserver:self forKeyPath:@"toolTip" context:kToolTipContext];
    self.observedButton = button;
    [button addObserver:self forKeyPath:@"toolTip" options:NSKeyValueObservingOptionInitial
                context:kToolTipContext];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change
                       context:(void*)context {
    if (context != kToolTipContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    NSButton* button = object;
    NSString* toolTip = SPDFMacFriendsToolTipWithShortcut(button.toolTip);
    // Setting it notifies again; the second time it already ends with the shortcut and is left alone.
    if (toolTip != button.toolTip) button.toolTip = toolTip;
}

- (void)dealloc { [self observeButton:nil]; }

@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsMenu)

- (void)friendsInstallMenu {
    SPDFMacFriendsReaderState* state = [self friendsState];
    SPDFMacFriendsMenuTarget* target = state.menuTarget;
    if (!target) {
        target = [SPDFMacFriendsMenuTarget new];
        target.reader = self;
        state.menuTarget = target;
    }
    NSMenu* viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    if (viewMenu) SPDFMacFriendsInstallMenu(viewMenu, target);
    [target observeButton:state.dropdown.button];
}

- (void)friendsRemoveMenu {
    SPDFMacFriendsReaderState* state = [self friendsState];
    NSMenu* viewMenu = [NSApp.mainMenu itemWithTitle:@"View"].submenu;
    if (viewMenu) SPDFMacFriendsRemoveMenu(viewMenu);
    [state.menuTarget observeButton:nil];
    state.menuTarget = nil;
}

@end
