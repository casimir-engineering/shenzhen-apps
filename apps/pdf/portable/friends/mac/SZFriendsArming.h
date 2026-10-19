// Shenzhen Friends arming: actions that ask for a second, deliberate click, and the one button every view draws
// PROTOCOL.md action objects with (internal).
//
// An action with `arm` sends nothing on its first click: the button turns into a red pill showing arm.label. A
// second click within arm.seconds sends it. WHY so strict about that second click: Block and Remove cannot be
// undone from this Mac, and a habitual double-click must not arm and confirm in one gesture.

#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

// YES when a press at `pressedAt` with `clickCount` may confirm what was armed at `armedAt`: never the second click
// of a double-click (clickCount > 1), and never within `doubleClickInterval` of arming, which catches a fast double
// click that the system reports as two single clicks.
BOOL SZFriendsArmAcceptsConfirm(NSTimeInterval armedAt, NSTimeInterval pressedAt, NSInteger clickCount,
                                NSTimeInterval doubleClickInterval);

// One button's armed state: when it was armed, and the timer that turns it back. Only the latest arming's timer
// counts, so a timer left over from an earlier, already reverted pill does nothing.
@interface SZFriendsArming : NSObject
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, readonly, getter=isArmed) BOOL armed;
// The first press: arms for `seconds` (at least 1, so a snapshot without a usable time cannot arm for good) and
// calls `expired` once that passes unconfirmed.
- (void)armForSeconds:(double)seconds expired:(void (^)(void))expired;
// A later press: YES when it confirms. A press that does not (the second half of a double-click) leaves it armed.
- (BOOL)pressConfirms;
- (BOOL)disarm; // YES when it was armed
@end

// A button for one PROTOCOL.md action object: its label, its style, its `arm` and its `confirm` (asked through the
// context), sent with `ids`. Cards, details, history items and notices all draw actions with it, so a destructive
// action looks and behaves the same wherever it appears.
@interface SZFriendsActionButton : SZFriendsButton
// nil for an action this view does not know (PROTOCOL.md § Principles: hide it).
+ (nullable instancetype)buttonForAction:(nullable NSDictionary *)action
                                     ids:(nullable NSDictionary<NSString *, NSString *> *)ids
                                 context:(SZFriendsContext *)context;
@property(nonatomic, copy, readonly) NSDictionary *actionObject; // not `action`: NSControl's selector
@property(nonatomic, readonly, getter=isArmed) BOOL armed;
// The helper's reply to the intent the button sent, for a view that shows its words (a mention card's Add).
@property(nonatomic, copy, nullable) SZFriendsReplyHandler onReply;
// Pressed once, the button stays disabled until the snapshot replaces it, or comes back if the helper refused (a
// join row's Approve: the code shows in place of the buttons once the helper answers).
@property(nonatomic) BOOL disablesOncePressed;
- (BOOL)disarm; // YES when it was armed
@end

// Buttons for `actions` (known ones only, in their order), reusing a button from `previous` whose action and ids are
// unchanged, so a snapshot that changes nothing about it keeps its armed pill, hover and focus. The caller removes
// the previous buttons that are not returned and adds the new ones.
NSArray<SZFriendsActionButton *> *SZFriendsActionButtonsFor(NSArray *actions,
                                                            NSDictionary<NSString *, NSString *> *_Nullable ids,
                                                            SZFriendsContext *context,
                                                            NSArray<SZFriendsActionButton *> *_Nullable previous);

// Turns back every armed action button under `root`; YES when one was armed. Escape does this before anything else,
// since closing the dropdown under a "Block?" would leave the person unsure whether they blocked someone.
BOOL SZFriendsDisarmActionButtons(NSView *root);

// Speaks an armed button's new label and tells VoiceOver its title changed (shared with the row buttons).
void SZFriendsAnnounceArmed(SZFriendsContext *context, NSButton *button, NSString *_Nullable text);

NS_ASSUME_NONNULL_END
