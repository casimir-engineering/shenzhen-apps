// A conversation's item views, built newest first so that opening a long history is instant (internal).
//
// The first frame gets the newest items, as many as the page is tall, so the list is full. The older ones are built
// after that frame is on screen, one slice per turn of the run loop, above what the person sees. One Markdown render
// pass of the host spans the whole build, so a hostile history still costs one allowance, however many turns it takes
// (SZFriendsHost.h § Optional Markdown rendering). Used by SZFriendsConversationPage, which lays the views out.

#import "mac/SZFriendsConversationPage.h"

NS_ASSUME_NONNULL_BEGIN

@interface SZFriendsHistoryBuild : NSObject
- (instancetype)initWithContext:(SZFriendsContext *)context container:(NSView *)container;
// The views built so far, oldest first: the newest `views.count` of the items last applied.
@property(nonatomic, copy, readonly) NSArray<SZFriendsItemView *> *views;
// Items older than the oldest view, still to build.
@property(nonatomic, readonly) NSUInteger pending;
// A snapshot's items, oldest first. Views are reused by kind and id, and an item that did not change is not applied
// again, so a progress tick neither rebuilds nor measures the history again. With `everything` (a highlighted message,
// older history the person asked for) every item is built now. Otherwise what was built stays built and new items are
// added below it; the first build stops once the newest items are `height` points tall at `width`.
- (void)applyItems:(NSArray<NSDictionary *> *)items
        everything:(BOOL)everything
             width:(CGFloat)width
            height:(CGFloat)height;
// Builds the next slice of older items now (the person scrolled to the top of what is built), and calls onGrow; NO
// when none was left.
- (BOOL)buildSlice;
// After a slice was built: the page lays it out and keeps what the person sees where it was.
@property(nonatomic, copy, nullable) void (^onGrow)(void);
// YES while the page is off screen (built ahead of a click, or left by Back): nothing is built in the background and
// the host's pass is not held.
@property(nonatomic) BOOL paused;
@end

// Runs `block` once, on the main run loop, after the frame being prepared now has been handed to the screen.
void SZFriendsAfterNextFrame(dispatch_block_t block);

NS_ASSUME_NONNULL_END
