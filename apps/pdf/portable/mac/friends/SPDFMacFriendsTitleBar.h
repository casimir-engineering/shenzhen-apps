// Placing the Friends button in ShenzhenPDF's title bar, between Groups and Search.
//
// Today's title bar (ShenzhenPDFMac.mm, SPDFMacWorkspaceChrome.mm): the tab strip ends 44 pt before the content
// view's trailing edge and draws its Groups button 28 pt wide, 8 pt inside its own trailing edge; Search is a
// 24 pt button 8 pt from the trailing edge. The bare content view between them is title-bar space that drags the
// window. Installing Friends puts its button 8 pt before Search and moves the strip's trailing edge to the
// button's leading edge, so Groups ends 8 pt before Friends: two equal gaps of bare title bar, each still
// dragging the window, and three buttons whose frames never overlap. The button is added straight to the content
// view (no container), so nothing but the button itself covers title-bar space, and its whole frame is its
// hit area. Uninstalling restores the strip's original constraint exactly.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat SPDFMacFriendsTitleBarGap;          // 8 pt of bare title bar each side
FOUNDATION_EXPORT const CGFloat SPDFMacFriendsGroupsInsetInStrip;   // the tab strip draws Groups 8 pt inside

@interface SPDFMacFriendsTitleBarPlacement : NSObject
@property(nonatomic, readonly) NSView* button;
@property(nonatomic, readonly, getter=isInstalled) BOOL installed;
- (void)uninstall;
@end

// The constraint pinning `view`'s trailing edge to `container`'s, or nil. The coordinator creates the tab strip's
// without keeping it, so the placement finds it rather than asking for a new ivar in a capped header.
NSLayoutConstraint* _Nullable SPDFMacFriendsTrailingConstraint(NSView* container, NSView* view);

// The direct subview of `container` that is a button sending `action` (Search sends showFavoritesPalette:), or nil.
// The workspace chrome keeps Search in a private associated object, so the placement finds it by what it does.
NSButton* _Nullable SPDFMacFriendsButtonWithAction(NSView* container, SEL action);

// Adds `button` (the views' Friends button) to `container` with a `side`-pt square frame, centred on the tab
// strip's row, its trailing edge SPDFMacFriendsTitleBarGap before `searchButton`, and swaps `stripTrailing` for
// one ending the strip at the button. nil when the pieces are not in one view tree (nothing is changed then).
SPDFMacFriendsTitleBarPlacement* _Nullable SPDFMacFriendsInstallTitleBarButton(NSView* button, NSView* container,
                                                                               NSView* tabStrip,
                                                                               NSLayoutConstraint* stripTrailing,
                                                                               NSView* searchButton, CGFloat side);

// The rectangle the tab strip draws its Groups button in, in the strip's coordinates (SPDFMacTabStripLayout.mm
// -overflowRectAssumingVisible, kept in step by a source-contract test).
NSRect SPDFMacFriendsGroupsRectInStrip(NSRect stripBounds);

NS_ASSUME_NONNULL_END
