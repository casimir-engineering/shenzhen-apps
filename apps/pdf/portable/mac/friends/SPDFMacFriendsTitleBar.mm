#import "SPDFMacFriendsTitleBar.h"

const CGFloat SPDFMacFriendsTitleBarGap = 8.0;
const CGFloat SPDFMacFriendsGroupsInsetInStrip = 8.0;

@interface SPDFMacFriendsTitleBarPlacement ()
@property(nonatomic, readwrite) NSView* button;
@property(nonatomic) NSLayoutConstraint* originalStripTrailing;
@property(nonatomic) NSArray<NSLayoutConstraint*>* constraints;
@property(nonatomic, readwrite, getter=isInstalled) BOOL installed;
@end

@implementation SPDFMacFriendsTitleBarPlacement
- (void)uninstall {
    if (!self.installed) return;
    [NSLayoutConstraint deactivateConstraints:self.constraints];
    // Back to the coordinator's own constraint, untouched while Friends was installed, so disabling Friends
    // returns the title bar to exactly what it was.
    self.originalStripTrailing.active = YES;
    [self.button removeFromSuperview];
    self.installed = NO;
}
@end

NSLayoutConstraint* SPDFMacFriendsTrailingConstraint(NSView* container, NSView* view) {
    for (NSLayoutConstraint* constraint in container.constraints) {
        if (!constraint.active || constraint.relation != NSLayoutRelationEqual) continue;
        if (constraint.firstAttribute != NSLayoutAttributeTrailing ||
            constraint.secondAttribute != NSLayoutAttributeTrailing)
            continue;
        BOOL forward = constraint.firstItem == view && constraint.secondItem == container;
        BOOL reverse = constraint.firstItem == container && constraint.secondItem == view;
        if (forward || reverse) return constraint;
    }
    return nil;
}

NSButton* SPDFMacFriendsButtonWithAction(NSView* container, SEL action) {
    for (NSView* view in container.subviews)
        if ([view isKindOfClass:NSButton.class] && ((NSButton*)view).action == action) return (NSButton*)view;
    return nil;
}

SPDFMacFriendsTitleBarPlacement* SPDFMacFriendsInstallTitleBarButton(NSView* button, NSView* container,
                                                                     NSView* tabStrip,
                                                                     NSLayoutConstraint* stripTrailing,
                                                                     NSView* searchButton, CGFloat side) {
    if (!button || !container || tabStrip.superview != container || searchButton.superview != container ||
        !stripTrailing.active || side <= 0)
        return nil;
    [button removeFromSuperview];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    // Hidden from the assistant's app_controls (SPDFMacAIAppControls.h) whatever the views named it, since it sits
    // among the reader's own title-bar buttons, which app_controls does list.
    if (![button.identifier hasPrefix:@"szfriends."]) button.identifier = @"szfriends.title-button";
    // Above the strip and Search in z-order: frames do not overlap, but a later relayout must never hide the
    // button under a sibling that happens to grow.
    [container addSubview:button positioned:NSWindowAbove relativeTo:nil];
    SPDFMacFriendsTitleBarPlacement* placement = [SPDFMacFriendsTitleBarPlacement new];
    placement.button = button;
    placement.originalStripTrailing = stripTrailing;
    placement.constraints = @[
        [button.widthAnchor constraintEqualToConstant:side],
        [button.heightAnchor constraintEqualToConstant:side],
        [button.centerYAnchor constraintEqualToAnchor:tabStrip.centerYAnchor],
        [button.trailingAnchor constraintEqualToAnchor:searchButton.leadingAnchor constant:-SPDFMacFriendsTitleBarGap],
        // Groups is drawn SPDFMacFriendsGroupsInsetInStrip inside the strip; ending the strip this far right of
        // the button's leading edge leaves exactly one gap of bare title bar between Groups and Friends.
        [tabStrip.trailingAnchor constraintEqualToAnchor:button.leadingAnchor
                                                constant:SPDFMacFriendsGroupsInsetInStrip - SPDFMacFriendsTitleBarGap],
    ];
    stripTrailing.active = NO;
    [NSLayoutConstraint activateConstraints:placement.constraints];
    placement.installed = YES;
    return placement;
}

NSRect SPDFMacFriendsGroupsRectInStrip(NSRect bounds) {
    // Mirrors -overflowRectAssumingVisible's right-edge branch: NSMakeRect(width - 36, (height - 28) / 2, 28, 28).
    return NSMakeRect(NSWidth(bounds) - 36.0, floor((NSHeight(bounds) - 28.0) / 2.0), 28.0, 28.0);
}
