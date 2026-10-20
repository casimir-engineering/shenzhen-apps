// Shenzhen Friends rows: one person per row in the list, Nearby and the send picker (internal).

#import "mac/SZFriendsDrops.h"
#import "mac/SZFriendsPage.h"

NS_ASSUME_NONNULL_BEGIN

// One of a row's own buttons (PROTOCOL.md row_action): a round icon, or the armed pill ("Block?") after a first
// click on an action that asks for a second one.
@interface SZFriendsRowActionButton : SZFriendsButton
@property(nonatomic, copy, readonly) NSDictionary *rowAction;
@property(nonatomic, readonly, getter=isArmed) BOOL armed;
@end

// A request row's buttons, answered without opening the request: Accept, Decline and Block in place of the time.
// An action with `arm` sends nothing on its first click; a second click within arm.seconds sends it. The pill turns
// back when that time passes (through the context's scheduleAfter), and on -disarm, which the row calls when the
// pointer leaves it and the list page calls on Escape.
@interface SZFriendsRowActionsView : SZFriendsFlippedView
- (instancetype)initWithContext:(SZFriendsContext *)context;
// Keeps the buttons, and an armed pill, when the actions are unchanged; otherwise rebuilds them, showing only
// actions and icons this view knows. Returns NO when none remain.
- (BOOL)applyActions:(NSArray *)actions;
@property(nonatomic, copy, readonly) NSArray<SZFriendsRowActionButton *> *buttons;
@property(nonatomic, readonly, getter=isArmed) BOOL armed;
- (BOOL)disarm; // YES when an armed pill turned back
- (CGFloat)fittingWidth;
// Sent and not yet answered, or the row drawn faded: the buttons ignore clicks.
@property(nonatomic, getter=isBusy) BOOL busy;
@property(nonatomic) BOOL inactive;
@property(nonatomic, copy, nullable) void (^onAction)(NSDictionary *action);
@property(nonatomic, copy, nullable) void (^onWidthChange)(void);
// Given to each of its buttons (SZFriendsButton pressSubject): the row's person, so a press on Accept for one
// request never answers another that a new snapshot moved into the row.
@property(nonatomic, copy, nullable) id _Nullable (^pressSubject)(void);
@end

// The whole row is one button and one drop target. It draws avatar, title, subtitle, time and the route icon or
// waiting label itself, so no part of it is a dead zone; only its own buttons (Request in Nearby; Accept, Decline
// and Block on a request) are separate targets.
@interface SZFriendsRowView : SZFriendsButton
- (instancetype)initWithContext:(SZFriendsContext *)context;
@property(nonatomic, weak, readonly, nullable) SZFriendsContext *context;
- (void)configureWithListRow:(NSDictionary *)row;          // PROTOCOL.md list_row
- (void)configureWithNearbyPerson:(NSDictionary *)person;   // PROTOCOL.md nearby_person
@property(nonatomic, copy, readonly, nullable) NSString *conversationID;
@property(nonatomic, copy, readonly, nullable) NSString *dropLabel;   // nil: the row refuses drops
@property(nonatomic, strong, readonly, nullable) SZFriendsButton *accessoryButton;
// list_row actions; nil when the row has none.
@property(nonatomic, strong, readonly, nullable) SZFriendsRowActionsView *actionsView;
@property(nonatomic, copy, nullable) void (^onRowAction)(SZFriendsRowView *row, NSDictionary *action);
// list_row menu (PROTOCOL.md, capability list.menu; SZFriendsRowMenu.m): the actions this view knows, in order; empty when the row has
// none. Right-click or Control-click opens them as a menu (through the context's presentMenu), VoiceOver's Show Menu
// does too, and each is also one of the row's accessibility custom actions. Delete or Forward Delete on the focused
// row chooses the first. A choice goes to onMenuAction with the person the row showed when the menu opened; one that
// a snapshot has since moved elsewhere in the list is dropped.
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *menuActions;
@property(nonatomic, copy, nullable) void (^onMenuAction)(SZFriendsRowView *row, NSDictionary *action,
                                                          NSString *conversationID);
@property(nonatomic, readonly) SZFriendsDropHighlight dropHighlight;
// Drawn faded: the send picker's rows that cannot receive files.
@property(nonatomic) BOOL dimmed;
// The list row's style is "muted" (someone blocked): a faded avatar and the title in secondary text. Unlike
// `dimmed` the text keeps its contrast, because the row still opens the conversation where they can be unblocked.
@property(nonatomic, readonly) BOOL muted;
// list_row id_confirmed: the Friends server confirmed this person holds the Friends ID (a small check).
@property(nonatomic, readonly) BOOL idConfirmed;
// What the row says under the pointer while it refuses files (list_row drop_refusal), or nil when it shows nothing.
- (nullable NSString *)refusalText;
// The list above the rows already says why the files are refused (drop_folders_refused, drop_not_a_file): a row that
// takes files then shows only the refuse style, never the sentence, so its name and preview stay whole.
@property(nonatomic) BOOL dropRefusalShownAbove;
// The pill of a row that takes files while a drag is over it: "Send to Mei", why not, or nil for none.
- (nullable NSString *)dropPillText;
// The accent bar a row waiting for an answer draws at its leading edge.
- (NSRect)waitingBarRect;
// Files dropped on the row, already read off the pasteboard; the list sends them at once to `conversationID`, the
// person the row showed when the drag entered it and still showed at the drop. Rows are reused by position: a drop
// after a snapshot moved someone else into the row is refused, and the drag shows nothing there until it re-enters.
@property(nonatomic, copy, nullable) void (^onDropItems)(SZFriendsRowView *row, NSString *conversationID,
        NSArray<SZFriendsAttachableItem *> *items);
@end

@interface SZFriendsRowView (Menu)
// The menu as it opens now; nil when the row has no menu.
- (nullable NSMenu *)contextMenu;
// Opens the menu at `point` (the row's coordinates); NO when the row has none.
- (BOOL)showContextMenuAtPoint:(NSPoint)point;
@end

extern const CGFloat SZFriendsRowHeight;

NS_ASSUME_NONNULL_END
