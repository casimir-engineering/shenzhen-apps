// SZFriendsRowView's menu (PROTOCOL.md list_row menu): right-click, Control-click, Delete and VoiceOver.

#import "mac/SZFriendsRowView.h"

// A menu item's choice: the action and whom the row showed when the menu opened.
@interface SZFRowMenuChoice : NSObject
@property(nonatomic, copy) NSDictionary *action;
@property(nonatomic, copy) NSString *conversationID;
@end

@implementation SZFRowMenuChoice
@end

// VoiceOver speaks to a button's cell, not to the button: the row's cell offers its menu (Show Menu, and each item as
// a custom action by its label) beside the press.
@interface SZFRowCell : NSButtonCell
@end

@implementation SZFRowCell

- (SZFriendsRowView *)row {
    return [self.controlView isKindOfClass:SZFriendsRowView.class] ? (SZFriendsRowView *)self.controlView : nil;
}

- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformShowMenu)) return [self row].contextMenu != nil;
    return [super isAccessibilitySelectorAllowed:selector];
}

- (BOOL)accessibilityPerformShowMenu {
    return [[self row] accessibilityPerformShowMenu];
}

- (NSArray<NSAccessibilityCustomAction *> *)accessibilityCustomActions {
    return [[self row] accessibilityCustomActions];
}

// NSButtonCell answers its actions through the older calls, which list only Press: Show Menu is added there.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (NSArray<NSAccessibilityActionName> *)accessibilityActionNames {
    NSArray *names = [super accessibilityActionNames] ?: @[];
    if (![self row].contextMenu || [names containsObject:NSAccessibilityShowMenuAction]) return names;
    return [names arrayByAddingObject:NSAccessibilityShowMenuAction];
}

- (void)accessibilityPerformAction:(NSAccessibilityActionName)action {
    if ([action isEqualToString:NSAccessibilityShowMenuAction]) [self accessibilityPerformShowMenu];
    else [super accessibilityPerformAction:action];
}
#pragma clang diagnostic pop

@end

@implementation SZFriendsRowView (Menu)

+ (Class)cellClass {
    return SZFRowCell.class;
}

- (NSMenu *)contextMenu {
    if (!self.menuActions.count || !self.conversationID) return nil;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.autoenablesItems = NO;
    for (NSDictionary *action in self.menuActions) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:SZFStr(action, @"label") action:@selector(menuItemChosen:)
                                               keyEquivalent:@""];
        item.target = self;
        SZFRowMenuChoice *choice = [SZFRowMenuChoice new];
        choice.action = action;
        choice.conversationID = self.conversationID;
        item.representedObject = choice;
        [menu addItem:item];
    }
    return menu;
}

- (BOOL)showContextMenuAtPoint:(NSPoint)point {
    NSMenu *menu = [self contextMenu];
    SZFriendsContext *context = self.context;
    if (!menu || !context.presentMenu) return NO;
    context.presentMenu(menu, self, point);
    return YES;
}

- (void)menuItemChosen:(NSMenuItem *)item {
    SZFRowMenuChoice *choice = item.representedObject;
    if (![choice isKindOfClass:SZFRowMenuChoice.class]) return;
    [self chooseMenuAction:choice.action forPerson:choice.conversationID];
}

// The row may show someone else by now (rows are reused by position): the choice is for whom it was opened on.
- (void)chooseMenuAction:(NSDictionary *)action forPerson:(NSString *)conversationID {
    if (![conversationID isEqualToString:self.conversationID] || !self.onMenuAction) return;
    self.onMenuAction(self, action, conversationID);
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (![self showContextMenuAtPoint:point]) [super rightMouseDown:event];
}

// Control-click is the one-button way to the same menu; it never opens the conversation.
- (void)mouseDown:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagControl) && self.menuActions.count) {
        [self showContextMenuAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
        return;
    }
    [super mouseDown:event];
}

// Delete or Forward Delete on the focused row: the menu's first action, which asks first as the menu's does.
- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags flags = event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                        NSEventModifierFlagControl | NSEventModifierFlagShift);
    BOOL deleteKey = event.keyCode == 51 || event.keyCode == 117;
    if (deleteKey && !flags && self.menuActions.count && self.conversationID) {
        [self chooseMenuAction:self.menuActions.firstObject forPerson:self.conversationID];
        return;
    }
    [super keyDown:event];
}

- (BOOL)accessibilityPerformShowMenu {
    return [self showContextMenuAtPoint:NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds))];
}

// VoiceOver's Actions rotor lists each menu action by its label ("Remove"), beside the row's own press.
- (NSArray<NSAccessibilityCustomAction *> *)accessibilityCustomActions {
    if (!self.menuActions.count || !self.conversationID) return nil;
    NSMutableArray *actions = [NSMutableArray array];
    __weak SZFriendsRowView *weakSelf = self;
    NSString *conversationID = self.conversationID;
    for (NSDictionary *action in self.menuActions) {
        [actions addObject:[[NSAccessibilityCustomAction alloc] initWithName:SZFStr(action, @"label")
                                                                     handler:^BOOL {
                                                                         [weakSelf chooseMenuAction:action
                                                                                          forPerson:conversationID];
                                                                         return YES;
                                                                     }]];
    }
    return actions;
}

@end
