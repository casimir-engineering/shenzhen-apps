// Shenzhen Friends: Tab and Shift-Tab inside the dropdown, whether or not macOS Keyboard navigation (Full Keyboard
// Access) is on (internal).
//
// With it off, the default, AppKit's key-view loop holds text fields only, and a field with nothing after it keeps
// the focus: Tab did nothing. So Friends moves the focus itself. Each page (and the confirmation over it) lists its
// stops in order; Tab goes to the next one that can take the focus, Shift-Tab to the one before, round and round. A
// field forwards insertTab: and insertBacktab: from its delegate, a focused button and the list take Tab in -keyDown:.
// A focused button presses on Return or Space and shows the system focus ring.

#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

// Something whose stops Tab goes through: every page (SZFriendsPage keyFocusStops), the confirmation overlay.
@protocol SZFriendsFocusScope <NSObject>
- (NSArray<NSView *> *)keyFocusStops;
@end

@interface SZFriendsPage (FocusScope) <SZFriendsFocusScope>
@end

// What under `root` can take the focus, top to bottom and left to right on each line: editable fields and text views,
// enabled buttons. Hidden views and those scrolled out of sight are left out, and so are list rows (the list is one
// stop of its own, SZFriendsListPage) and everything inside them.
NSArray<NSView *> *SZFriendsFocusStops(NSView *root);

// Gives `view` the focus, a Friends button included (with Full Keyboard Access off AppKit refuses buttons); YES when
// it has it.
BOOL SZFriendsFocus(NSView *view);

// Inside a page or the confirmation: where Tab is Friends' own.
BOOL SZFriendsInFocusScope(NSView *view);

// SZFriendsMoveFocus and SZFriendsFocusCommand, which every field delegate uses, are in SZFriendsPage.h.

// A key that reached the dropdown itself, with nothing inside focused: Tab and Shift-Tab enter `scope` at its first
// or last stop, and Return presses its primary button when it has one. NO for any other key.
BOOL SZFriendsHandleUnfocusedKey(id<SZFriendsFocusScope> scope, NSEvent *event);

// Tab or Shift-Tab; Return or Enter without Shift: neither with Command, Option or Control.
BOOL SZFriendsIsTabKey(NSEvent *event);
BOOL SZFriendsIsReturnKey(NSEvent *event);

// The list's own stop (SZFriendsListPage): an invisible view over the rows that takes the focus for them, so the
// highlighted row moves with Up and Down, opens with Return, and a letter typed goes back to the search field. It
// takes no clicks; the rows under it keep them.
@interface SZFriendsListKeyView : NSView
@property(nonatomic, copy, nullable) BOOL (^onKey)(NSEvent *event);
@property(nonatomic, copy, nullable) void (^onFocusChange)(BOOL focused);
@property(nonatomic, readonly, getter=isFocused) BOOL focused;
@end

NS_ASSUME_NONNULL_END
