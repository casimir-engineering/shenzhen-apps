#import "SPDFMacTabStripViewPrivate.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "markdown/SPDFTextDocumentFormats.h"

@protocol SPDFTabCollectionMenuProviding <NSObject>
- (void)addCollectionItemsToTabMenu:(NSMenu*)menu path:(NSString*)path;
@end
@protocol SPDFTabFriendsMenuProviding <NSObject>
- (void)friendsAddItemsToTabMenu:(NSMenu*)menu path:(NSString*)path;
@end

@implementation SPDFTabStripView (Menus)
- (NSMenu*)newTabOrGroupMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"New Tab or Group"];
    NSMenuItem* tab = [menu addItemWithTitle:@"New Tab" action:@selector(newTabRequested:) keyEquivalent:@""];
    tab.target = self.reader;
    spdf_set_menu_item_system_symbol(tab, @"doc.badge.plus");
    NSMenuItem* group = [menu addItemWithTitle:@"New Group…"
        action:NSSelectorFromString(@"createEmptyTabGroupFromPlus:") keyEquivalent:@""];
    group.target = self.reader;
    spdf_set_menu_item_system_symbol(group, @"folder.badge.plus");
    return menu;
}

- (void)showNewTabOrGroupMenu {
    [self dismissHoverPanel];
    NSRect rect = [self plusRect];
    [[self newTabOrGroupMenu] popUpMenuPositioningItem:nil
        atLocation:NSMakePoint(NSMinX(rect), NSMinY(rect)) inView:self];
}

- (NSMenu*)overflowMenu {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"All Groups"];
    NSMutableSet* seen = [NSMutableSet set];
    for (NSUInteger index=0;index<self.tabs.count;index++) {
        SPDFDocumentTab* tab = self.tabs[index];
        SPDFTabGroup* group = tab.group;
        if (group && ![seen containsObject:group.identifier]) {
            [seen addObject:group.identifier];
            if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
            NSString* name = [NSString stringWithFormat:@"%@%@",group.displayName,group.hidden ? @" · Hidden" : @""];
            NSMenuItem* heading = [menu addItemWithTitle:name action:@selector(browseGroupFromMenu:) keyEquivalent:@""];
            heading.target = self;
            heading.representedObject = group;
            heading.image = spdf_tab_group_swatch_image(group.colorName);
            heading.state = group.collapsed ? NSControlStateValueOff : NSControlStateValueOn;
        }
        NSMenuItem* item = [menu addItemWithTitle:[self fullTitleForTabAtIndex:index]
            action:@selector(overflowTabMenuItemSelected:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = @(index);
        item.indentationLevel = group ? 1 : 0;
        item.state = index == (NSUInteger)self.selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
    }
    for (SPDFTabGroup* group in self.emptyGroups) {
        if ([seen containsObject:group.identifier]) continue;
        [seen addObject:group.identifier];
        if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
        NSMenuItem* heading = [menu addItemWithTitle:group.displayName
            action:@selector(browseGroupFromMenu:) keyEquivalent:@""];
        heading.target=self; heading.representedObject=group;
        heading.image=spdf_tab_group_swatch_image(group.colorName);
    }
    return menu;
}
- (void)browseGroupFromMenu:(NSMenuItem*)sender {
    SPDFTabGroup* group = sender.representedObject;
    if (!group) return;
    if (group.hidden) [self.groupReader setTabGroup:group hidden:NO];
    if (group.collapsed) [self.groupReader toggleTabGroup:group];
}

- (void)showOverflowMenuWithEvent:(NSEvent*)event {
    (void)event;
    [self showGroupPicker];
}
- (void)showOverflowMenuForAccessibility { [self showGroupPicker]; }
- (void)showGroupDocuments:(SPDFTabGroup*)group event:(NSEvent*)event {
    NSMenu* menu=[[NSMenu alloc] initWithTitle:group.displayName];
    for (NSUInteger index=0;index<self.tabs.count;index++) {
        if (self.tabs[index].group!=group) continue;
        NSMenuItem* item=[menu addItemWithTitle:[self fullTitleForTabAtIndex:index]
            action:@selector(overflowTabMenuItemSelected:) keyEquivalent:@""];
        item.target=self; item.representedObject=@(index);
        item.state=index==(NSUInteger)self.selectedIndex ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self dismissHoverPanel];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)overflowTabMenuItemSelected:(NSMenuItem*)sender {
    NSNumber* indexNumber = [sender.representedObject isKindOfClass:NSNumber.class] ? sender.representedObject : nil;
    if (!indexNumber) return;
    [self.reader selectTabAtIndex:indexNumber.integerValue];
}

- (void)tabContextShowInFolder:(NSMenuItem*)sender {
    NSNumber* indexNumber = [sender.representedObject isKindOfClass:NSNumber.class] ? sender.representedObject : nil;
    if (!indexNumber) return;
    [self.reader showTabInFolderAtIndex:indexNumber.integerValue];
}

- (void)tabContextCopyFile:(NSMenuItem*)sender {
    NSNumber* indexNumber = [sender.representedObject isKindOfClass:NSNumber.class] ? sender.representedObject : nil;
    if (!indexNumber) return;
    [self.reader copyTabFileToPasteboardAtIndex:indexNumber.integerValue];
}

- (void)tabContextCopyPath:(NSMenuItem*)sender {
    NSNumber* indexNumber = [sender.representedObject isKindOfClass:NSNumber.class] ? sender.representedObject : nil;
    if (!indexNumber) return;
    [self.reader copyTabPathToPasteboardAtIndex:indexNumber.integerValue];
}

- (void)tabContextCopyTitle:(NSMenuItem*)sender {
    NSNumber* indexNumber = [sender.representedObject isKindOfClass:NSNumber.class] ? sender.representedObject : nil;
    if (!indexNumber) return;
    [self.reader copyTabTitleToPasteboardAtIndex:indexNumber.integerValue];
}

- (void)tabContextCloseDocument:(NSMenuItem*)sender {
    if([sender.representedObject isKindOfClass:NSNumber.class])
        [self.reader closeTabAtIndex:[sender.representedObject integerValue]];
}

- (NSMenu*)contextMenuForTabAtIndex:(NSInteger)tabIndex {
    if (tabIndex < 0 || tabIndex >= (NSInteger)self.tabs.count) return nil;
    NSNumber* indexNumber = @(tabIndex);
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Tab"];
    NSMenuItem* group = [menu addItemWithTitle:@"Add to New Group" action:@selector(tabContextNewGroup:)
                               keyEquivalent:@""];
    group.target = self; group.representedObject = indexNumber;
    NSMenu* moveToGroup = [self moveToGroupMenuForTabAtIndex:tabIndex];
    if (moveToGroup.numberOfItems) {
        NSMenuItem* move = [[NSMenuItem alloc] initWithTitle:@"Move to Group" action:nil keyEquivalent:@""];
        move.submenu = moveToGroup; [menu addItem:move];
    }
    NSString* tabPath = self.tabs[(NSUInteger)tabIndex].path;
    if (SPDFIsRenderedTextDocumentPath(tabPath)) {
        NSMenuItem* editor = [menu addItemWithTitle:@"Open in Editor" action:NSSelectorFromString(@"openMarkdownInEditor:")
                                     keyEquivalent:@""];
        editor.target = self.reader; editor.representedObject = tabPath;
        editor.enabled = !SPDFMacPathIsCollectionArchive(tabPath);
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem* showInFolder = [menu addItemWithTitle:@"Show in Folder" action:@selector(tabContextShowInFolder:)
                                        keyEquivalent:@""];
    showInFolder.target = self; showInFolder.representedObject = indexNumber;
    NSMenuItem* rename = [menu addItemWithTitle:@"Rename Document…"
        action:NSSelectorFromString(@"renameDocumentFromTab:") keyEquivalent:@""];
    rename.target=self.reader; rename.representedObject=tabPath;
    SPDFDocumentTab* document=self.tabs[(NSUInteger)tabIndex];
    rename.enabled=!document.missingFile && !document.unsavedPastedImage && !SPDFMacPathIsCollectionArchive(tabPath);
    if (!rename.enabled) rename.action=nil;
    spdf_set_menu_item_system_symbol(rename,@"pencil");
    NSMenuItem* copy = [menu addItemWithTitle:@"Copy Document" action:@selector(tabContextCopyFile:) keyEquivalent:@""];
    copy.target = self; copy.representedObject = indexNumber;
    NSMenuItem* copyTitle = [menu addItemWithTitle:@"Copy Title" action:@selector(tabContextCopyTitle:) keyEquivalent:@""];
    copyTitle.target = self; copyTitle.representedObject = indexNumber;
    NSMenuItem* copyPath = [menu addItemWithTitle:@"Copy Path" action:@selector(tabContextCopyPath:) keyEquivalent:@""];
    copyPath.target = self; copyPath.representedObject = indexNumber;
    if ([self.reader respondsToSelector:@selector(addCollectionItemsToTabMenu:path:)])
        [(id<SPDFTabCollectionMenuProviding>)self.reader addCollectionItemsToTabMenu:menu path:tabPath];
    if ([self.reader respondsToSelector:@selector(friendsAddItemsToTabMenu:path:)] && !document.missingFile)
        [(id<SPDFTabFriendsMenuProviding>)self.reader friendsAddItemsToTabMenu:menu path:tabPath];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem* close=[menu addItemWithTitle:@"Close Document" action:@selector(tabContextCloseDocument:) keyEquivalent:@""];
    close.target=self; close.representedObject=indexNumber;
    spdf_set_menu_item_system_symbol(showInFolder, @"folder");
    spdf_set_menu_item_system_symbol(copy, @"doc.on.doc");
    spdf_set_menu_item_system_symbol(copyTitle, @"character.cursor.ibeam");
    spdf_set_menu_item_system_symbol(copyPath, @"doc.text");
    return menu;
}

- (void)showContextMenuForTabAtIndex:(NSInteger)index {
    NSMenu* menu = [self contextMenuForTabAtIndex:index];
    if (!menu) return;
    [self dismissHoverPanel];
    NSRect rect = [self rectForTabAtIndex:index];
    if (NSIsEmptyRect(rect)) rect = [self overflowRect];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(rect), NSMinY(rect)) inView:self];
}

- (void)rightMouseDown:(NSEvent*)event {
    if ([self handleGroupRightMouseDown:event]) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger tabIndex = [self tabIndexAtPoint:point];
    if (tabIndex < 0) {
        [self dismissHoverPanel];
        [super rightMouseDown:event];
        return;
    }

    [self dismissHoverPanel];
    NSMenu* menu = [self contextMenuForTabAtIndex:tabIndex];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

@end
