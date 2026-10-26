// Where a conversation's history goes as items arrive (PROTOCOL.md § Views, conversation): to its end when the
// person sends something, from wherever they had scrolled; nowhere when they read above while the friend's messages
// arrive below, which a pill over the bottom counts instead ("New message ↓", "3 new messages ↓", the static strings
// new_message and new_messages). Clicking the pill scrolls smoothly to the first of them; it goes once that one is in
// view. Used by SZFriendsConversationPage, which owns the list and its item views.

#import <AppKit/AppKit.h>

#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsHistoryFollow : NSObject
- (instancetype)initWithList:(NSScrollView *)list host:(NSView *)host context:(SZFriendsContext *)context;
// The history's item views (each with an itemID), to scroll to one and to tell when it is in view.
@property(nonatomic, copy, nullable) NSArray<NSView *> * (^itemViews)(void);
@property(nonatomic, strong, readonly) SZFriendsButton *pill;
@property(nonatomic, readonly) NSUInteger unseen;
// A snapshot's items, before the page shows them. YES when the person sent something since the last one (an `out`
// item after the newest): the page then goes to the end. Otherwise, with the history scrolled up (!atBottom), the
// friend's new items are counted for the pill.
- (BOOL)noteItems:(NSArray<NSDictionary *> *)items atBottom:(BOOL)atBottom;
// Places the pill over the bottom of the list (the list's frame in the host).
- (void)layoutOverList:(NSRect)frame;
// After a scroll or a layout: the pill's words, and whether it shows.
- (void)refresh;
@end

NS_ASSUME_NONNULL_END
