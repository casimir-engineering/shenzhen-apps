// View ▸ Friends (SPDFMacFriendsMenu.h).

#import "SPDFMacFriendsMenu.h"

// Friends is a beta: the View menu says so (Settings and the button's tooltip do too).
NSString* const SPDFMacFriendsMenuTitle = @"Friends (Beta)";
NSString* const SPDFMacFriendsOpenTitle = @"Open Friends";
NSString* const SPDFMacFriendsCloseTitle = @"Close Friends";
NSString* const SPDFMacFriendsAddByIDTitle = @"Add by ID…";
// How long it lasts is the helper's to say; the Nearby tab shows the countdown.
NSString* const SPDFMacFriendsVisibleTitle = @"Make Myself Visible";
NSString* const SPDFMacFriendsSettingsTitle = @"Friends Settings…";
NSString* const SPDFMacFriendsShortcutKey = @"j";
NSString* const SPDFMacFriendsShortcutToolTipSuffix = @" · ⌘J";

NSString* const SPDFMacFriendsMenuItemIdentifier = @"szfriends.menu";
NSString* const SPDFMacFriendsMenuSeparatorIdentifier = @"szfriends.menu-separator";
NSString* const SPDFMacFriendsOpenItemIdentifier = @"szfriends.open";
NSString* const SPDFMacFriendsAddByIDItemIdentifier = @"szfriends.add-by-id";
NSString* const SPDFMacFriendsVisibleItemIdentifier = @"szfriends.make-visible";
NSString* const SPDFMacFriendsSettingsItemIdentifier = @"szfriends.settings";

static NSMenuItem* Item(NSMenu* menu, NSString* title, SEL action, NSString* key, NSString* identifier, id target) {
    NSMenuItem* item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = key.length ? NSEventModifierFlagCommand : 0;
    item.identifier = identifier;
    item.target = target;
    return item;
}

NSMenuItem* SPDFMacFriendsInstallMenu(NSMenu* viewMenu, id<SPDFMacFriendsMenuActions> target) {
    for (NSMenuItem* existing in viewMenu.itemArray)
        if ([existing.identifier isEqualToString:SPDFMacFriendsMenuItemIdentifier]) return nil;
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:SPDFMacFriendsMenuTitle];
    Item(submenu, SPDFMacFriendsOpenTitle, @selector(toggleFriends:), SPDFMacFriendsShortcutKey,
         SPDFMacFriendsOpenItemIdentifier, target);
    [submenu addItem:NSMenuItem.separatorItem];
    Item(submenu, SPDFMacFriendsAddByIDTitle, @selector(addFriendByID:), @"", SPDFMacFriendsAddByIDItemIdentifier,
         target);
    Item(submenu, SPDFMacFriendsVisibleTitle, @selector(makeVisibleNearby:), @"", SPDFMacFriendsVisibleItemIdentifier,
         target);
    [submenu addItem:NSMenuItem.separatorItem];
    Item(submenu, SPDFMacFriendsSettingsTitle, @selector(showFriendsSettings:), @"",
         SPDFMacFriendsSettingsItemIdentifier, target);
    NSMenuItem* separator = NSMenuItem.separatorItem;
    separator.identifier = SPDFMacFriendsMenuSeparatorIdentifier;
    [viewMenu addItem:separator];
    NSMenuItem* friends = [viewMenu addItemWithTitle:SPDFMacFriendsMenuTitle action:nil keyEquivalent:@""];
    friends.identifier = SPDFMacFriendsMenuItemIdentifier;
    friends.submenu = submenu;
    return friends;
}

void SPDFMacFriendsRemoveMenu(NSMenu* viewMenu) {
    for (NSMenuItem* item in [viewMenu.itemArray copy])
        if ([item.identifier isEqualToString:SPDFMacFriendsMenuItemIdentifier] ||
            [item.identifier isEqualToString:SPDFMacFriendsMenuSeparatorIdentifier])
            [viewMenu removeItem:item];
}

NSString* SPDFMacFriendsToolTipWithShortcut(NSString* toolTip) {
    if (!toolTip.length || [toolTip hasSuffix:SPDFMacFriendsShortcutToolTipSuffix]) return toolTip;
    return [toolTip stringByAppendingString:SPDFMacFriendsShortcutToolTipSuffix];
}
