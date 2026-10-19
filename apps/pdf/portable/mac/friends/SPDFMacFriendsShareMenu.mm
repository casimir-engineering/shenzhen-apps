// Copy Download Link's menu items (SPDFMacFriendsShareMenu.h).

#import "SPDFMacFriendsShareMenu.h"

NSString* const SPDFMacFriendsShareMenuTitle = @"Share";
NSString* const SPDFMacFriendsCopyDownloadLinkTitle = @"Copy Download Link";
NSString* const SPDFMacFriendsCopyLinkInsteadTitle = @"Copy link instead";
NSString* const SPDFMacFriendsShareItemIdentifier = @"szfriends.share";
NSString* const SPDFMacFriendsCopyLinkItemIdentifier = @"szfriends.copy-download-link";

NSMenu* SPDFMacFriendsExpiryMenu(id target, SEL action, id object) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:SPDFMacFriendsCopyDownloadLinkTitle];
    // Whoever opens the link downloads from this Mac, so how long it keeps working is the one thing to choose.
    NSArray* choices = @[ @[ @7, @"For 7 Days" ], @[ @1, @"For 1 Day" ], @[ @30, @"For 30 Days" ] ];
    for (NSArray* choice in choices) {
        NSMenuItem* item = [menu addItemWithTitle:choice[1] action:action keyEquivalent:@""];
        item.target = target;
        item.tag = [choice[0] integerValue];
        item.representedObject = object;
        item.identifier = SPDFMacFriendsCopyLinkItemIdentifier;
    }
    return menu;
}

NSMenuItem* SPDFMacFriendsCopyDownloadLinkItem(id target, SEL action, id object) {
    NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:SPDFMacFriendsCopyDownloadLinkTitle action:nil
                                           keyEquivalent:@""];
    item.identifier = SPDFMacFriendsCopyLinkItemIdentifier;
    item.submenu = SPDFMacFriendsExpiryMenu(target, action, object);
    if (@available(macOS 11.0, *))
        item.image = [NSImage imageWithSystemSymbolName:@"link" accessibilityDescription:nil];
    return item;
}

NSMenuItem* SPDFMacFriendsInstallShareItem(NSMenu* fileMenu, id target, SEL action) {
    for (NSMenuItem* existing in fileMenu.itemArray)
        if ([existing.identifier isEqualToString:SPDFMacFriendsShareItemIdentifier]) return nil;
    NSMenuItem* share = [[NSMenuItem alloc] initWithTitle:SPDFMacFriendsShareMenuTitle action:nil keyEquivalent:@""];
    share.identifier = SPDFMacFriendsShareItemIdentifier;
    NSMenu* submenu = [[NSMenu alloc] initWithTitle:SPDFMacFriendsShareMenuTitle];
    [submenu addItem:SPDFMacFriendsCopyDownloadLinkItem(target, action, nil)];
    share.submenu = submenu;
    // Beside the other ways of passing a document on (Show in Folder, Copy Path).
    NSInteger index = -1;
    for (NSMenuItem* item in fileMenu.itemArray)
        if (item.action == NSSelectorFromString(@"copyCurrentDocumentPath:")) index = [fileMenu indexOfItem:item];
    if (index >= 0) [fileMenu insertItem:share atIndex:index + 1];
    else [fileMenu addItem:share];
    return share;
}

void SPDFMacFriendsRemoveShareItem(NSMenu* fileMenu) {
    for (NSMenuItem* item in [fileMenu.itemArray copy])
        if ([item.identifier isEqualToString:SPDFMacFriendsShareItemIdentifier]) [fileMenu removeItem:item];
}

NSInteger SPDFMacFriendsExpiryDays(id sender) {
    if (![sender isKindOfClass:NSMenuItem.class]) return 0;
    NSInteger days = ((NSMenuItem*)sender).tag;
    return days == 1 || days == 7 || days == 30 ? days : 0;
}
