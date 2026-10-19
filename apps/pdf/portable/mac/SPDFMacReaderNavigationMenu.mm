#import "SPDFMacReaderNavigationMenu.h"

void SPDFInstallReaderNavigationMenu(NSMenu* appMenu, NSMenu* goMenu, NSMenu* viewMenu, id reader) {
    NSMenuItem* previous = [goMenu addItemWithTitle:@"Previous Document" action:NSSelectorFromString(@"returnToPreviousTab:") keyEquivalent:@"d"];
    previous.target = reader; previous.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem* groups = [viewMenu addItemWithTitle:@"Groups" action:NSSelectorFromString(@"showGroupsSidebar:") keyEquivalent:@"g"];
    groups.target = reader; groups.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSMenuItem* history = [[NSMenuItem alloc] initWithTitle:@"Version History" action:NSSelectorFromString(@"showCollectionHistory:") keyEquivalent:@"h"];
    history.target = reader; history.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [viewMenu insertItem:history atIndex:MIN(1,viewMenu.numberOfItems)];
    // The user explicitly assigns Cmd+H to History; Hide remains reachable by menu.
    NSMenuItem* hide = [[NSMenuItem alloc] initWithTitle:@"Hide Shenzhen PDF" action:@selector(hide:) keyEquivalent:@""];
    hide.target = NSApp;
    [appMenu insertItem:hide atIndex:MAX(0,appMenu.numberOfItems-1)];
}
