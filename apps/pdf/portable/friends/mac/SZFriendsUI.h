// Shenzhen Friends views: the small toolkit every view shares (internal; not a public header).
//
// Snapshot accessors, colors, labels, buttons and vector icons. WHY one toolkit: every view renders the same
// snapshot shapes (avatar, route, action, rich text) and must look identical wherever they appear, and a GTK
// port reimplements exactly this file's worth of drawing. Nothing here decides what to show; it only draws
// what a snapshot says.

#import <AppKit/AppKit.h>

#import "mac/SZFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Hidden from the host's assistant

// Every Friends surface carries an NSUserInterfaceItemIdentification identifier starting with "szfriends.": the
// title button, the dropdown's content view, the inline confirmation, the Settings section, and every alert and
// panel Friends opens (on the window and its content view). The host's app-access tool (ShenzhenPDF's assistant
// app_controls) skips any view with such an identifier or inside one, and any window marked so, because without an
// @ scope the assistant must not see or press anything of Friends (brief § AI boundaries). The prefix is the
// contract with the host; SZFriendsHost.h says so for host authors.
extern NSString *const SZFriendsHiddenIdentifierPrefix;     // "szfriends."
extern NSString *const SZFriendsIdentifierTitleButton;      // "szfriends.title-button"
extern NSString *const SZFriendsIdentifierDropdown;         // "szfriends.dropdown"
extern NSString *const SZFriendsIdentifierConfirmation;     // "szfriends.confirmation"
extern NSString *const SZFriendsIdentifierSettings;         // "szfriends.settings"
extern NSString *const SZFriendsIdentifierAlert;            // "szfriends.alert"
extern NSString *const SZFriendsIdentifierOpenPanel;        // "szfriends.open-panel"
// Marks a window Friends opens (an alert, an open panel) and its content view.
void SZFriendsHideWindowFromAssistant(NSWindow *window, NSString *identifier);

#pragma mark - Snapshot accessors

// JSON values may be NSNull ("a field that does not apply is null"); these return nil (or NO / 0) for NSNull,
// a missing key or a value of the wrong type, so a malformed snapshot draws less instead of crashing.
NSString *_Nullable SZFStr(id _Nullable object, NSString *key);
NSDictionary *_Nullable SZFDict(id _Nullable object, NSString *key);
NSArray *SZFArr(id _Nullable object, NSString *key); // never nil: empty when absent
BOOL SZFBool(id _Nullable object, NSString *key);
double SZFNum(id _Nullable object, NSString *key);

#pragma mark - Colors and type

NSColor *SZFriendsColorFromHex(NSString *_Nullable hex, NSColor *fallback);
NSColor *SZFriendsDynamicColor(uint32_t light, uint32_t dark);
// The route icon's color for a route object's kind ("local", "online"; "connecting", "offline" and others grey).
NSColor *SZFriendsRouteColor(SZFriendsAppearance *appearance, NSString *_Nullable kind);
NSFont *SZFriendsSemibold(NSFont *font);

#pragma mark - Layout

// Flipped views lay out top-down like the mockups; every Friends view lays out by frames, not constraints, so
// a snapshot renders deterministically offscreen and a GTK port can copy the numbers.
@interface SZFriendsFlippedView : NSView
@property(nonatomic, strong, nullable) NSColor *fillColor;
@property(nonatomic, strong, nullable) NSColor *strokeColor;
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic) BOOL dashedStroke;
// Extra drawing in the view's own coordinates (dividers, icons beside labels), after the fill and stroke.
@property(nonatomic, copy, nullable) void (^drawContents)(SZFriendsFlippedView *view);
@end

// The fill colour fading in toward `edge` (in the fade's own unflipped coordinates: NSMinYEdge is the bottom), laid
// over content that continues beyond that edge: overlay scrollers stay hidden until scrolled, and content cut at a
// column or a line looked complete. It takes no clicks or scrolling; the view under it keeps them.
@interface SZFriendsEdgeFade : NSView
@property(nonatomic) NSRectEdge edge;
@property(nonatomic, strong, nullable) NSColor *color;
@end

// A non-editable, non-selectable wrapping label. Plain text only: names and messages come from other people and
// are never interpreted as markup.
NSTextField *SZFriendsLabel(NSString *_Nullable text, NSFont *font, NSColor *color);
// Height of `field` laid out at `width` (wrapping labels and attributed strings alike).
CGFloat SZFriendsFieldHeight(NSTextField *field, CGFloat width);
// Width of one line of `text` in `font`, rounded up.
CGFloat SZFriendsTextWidth(NSString *_Nullable text, NSFont *font);
// Places a wrapping label at (x, y) with `width`, returns its bottom edge.
CGFloat SZFriendsPlace(NSTextField *field, CGFloat x, CGFloat y, CGFloat width);
// PROTOCOL.md rich text: segments concatenated in order; `emphasis` bolds, `match` highlights, `url` links.
NSAttributedString *SZFriendsRichText(NSArray *segments, NSFont *font, NSColor *color,
                                      SZFriendsAppearance *appearance);

#pragma mark - Buttons

// PROTOCOL.md action styles. Every button draws its own background so its whole frame is one contiguous hit area
// (brief § Interface: every visible button has one contiguous hit area).
typedef NS_ENUM(NSInteger, SZFriendsButtonStyle) {
    SZFriendsButtonStylePrimary = 0,
    SZFriendsButtonStyleSecondary,
    SZFriendsButtonStyleLink,
    SZFriendsButtonStyleDestructive,
    SZFriendsButtonStyleIcon,      // square, icon only (back arrow, copy)
    SZFriendsButtonStylePlain,     // full-width rows and header titles: no chrome until hovered or pressed
    // A secondary button with a red title: the confirm button of a destructive confirmation, as NSAlert draws
    // hasDestructiveAction, so "Remove" never wears the blue that means "go ahead".
    SZFriendsButtonStyleDestructiveBordered,
};

SZFriendsButtonStyle SZFriendsButtonStyleNamed(NSString *_Nullable style);

typedef void (^SZFriendsIconDrawer)(NSRect rect, NSColor *color);

@interface SZFriendsButton : NSButton
@property(nonatomic) SZFriendsButtonStyle style;
@property(nonatomic, strong) SZFriendsAppearance *theme; // not `appearance`: NSView's NSAppearance
@property(nonatomic, copy, nullable) SZFriendsIconDrawer icon;
@property(nonatomic) NSSize iconSize;
@property(nonatomic) BOOL iconTrailing; // the icon after the title ("Raph ✎") instead of before it
@property(nonatomic, copy, nullable) NSString *badgeLabel; // the back arrow's waiting count
@property(nonatomic, copy, nullable) void (^onPress)(SZFriendsButton *button);
// Whom a mouse press acts on, read when the button goes down and again at release; when they differ, the click is
// dropped. Rows are reused by position, so a snapshot arriving mid-press can put someone else under the pointer. nil
// (the default), or a press from the keyboard or VoiceOver, which has no gap: every press counts.
@property(nonatomic, copy, nullable) id _Nullable (^pressSubject)(void);
@property(nonatomic) BOOL selectedLook; // a selected tab, a pressed toggle
@property(nonatomic, strong, nullable) NSColor *selectedFillColor; // overrides the selection colour when selected
@property(nonatomic, strong, nullable) NSColor *selectedStrokeColor; // an outline while selected (the selected tab)
@property(nonatomic) BOOL hovered;
// Chrome drawn inside the frame by these insets, so a badge can sit outside the chrome yet inside the hit area.
@property(nonatomic) NSEdgeInsets chromeInsets;
+ (instancetype)buttonWithTitle:(NSString *)title style:(SZFriendsButtonStyle)style
                     appearance:(SZFriendsAppearance *)appearance;
// The width the title needs plus padding, at the button's height.
- (CGFloat)fittingWidth;
// The color the icon is drawn in for the button's current style and state.
- (NSColor *)iconColor;
@end

#pragma mark - Icons (vector, drawn in a 16-unit box scaled to `rect`)

void SZFriendsDrawPeopleIcon(NSRect rect, NSColor *color);
void SZFriendsDrawBackArrow(NSRect rect, NSColor *color);
void SZFriendsDrawCopyIcon(NSRect rect, NSColor *color);
void SZFriendsDrawPencilIcon(NSRect rect, NSColor *color);
void SZFriendsDrawSearchIcon(NSRect rect, NSColor *color);
void SZFriendsDrawCheckIcon(NSRect rect, NSColor *color);
void SZFriendsDrawCheckCircleIcon(NSRect rect, NSColor *color);
void SZFriendsDrawChevronDown(NSRect rect, NSColor *color);
// Navigation ("opens a page"), as the conversation title shows it; a chevron down would promise a menu.
void SZFriendsDrawChevronRight(NSRect rect, NSColor *color);
void SZFriendsDrawArcIcon(NSRect rect, NSColor *color);       // "still looking"
void SZFriendsDrawBluetoothIcon(NSRect rect, NSColor *color);
void SZFriendsDrawInfoIcon(NSRect rect, NSColor *color);
void SZFriendsDrawCloseIcon(NSRect rect, NSColor *color);
void SZFriendsDrawBlockIcon(NSRect rect, NSColor *color);     // a circle with a slash
void SZFriendsDrawAssistantIcon(NSRect rect, NSColor *color); // a spark: "Via the assistant", the `/` tag
void SZFriendsDrawArrowUpIcon(NSRect rect, NSColor *color);   // runs a `/` command
// The route icon for a PROTOCOL.md route object: its `method` when the helper names one it knows (lan, p2p_wifi,
// bluetooth, internet, relay), else by `kind` (local: lan's waves, online: internet's globe), the globe for
// "connecting" (an online attempt runs; drawn in the offline colour) and "offline" for a route that is down; nil for
// kind none or one this view does not know, which draws nothing.
NSString *_Nullable SZFriendsRouteGlyph(NSDictionary *_Nullable route);
// Draws one of SZFriendsRouteGlyph's names in a 12-unit box: lan (waves either side of a dot), p2p_wifi (two laptops
// joined by a wave), bluetooth (the rune), internet (a globe), relay (a server), offline (a hollow dot with a slash:
// a dashed circle read as a loading spinner). The kinds "local" and "online" draw lan and internet; others nothing.
// gtk/szfriends_gtk_glyphs.c strokes the same paths.
void SZFriendsDrawRouteIcon(NSString *_Nullable glyph, NSRect rect, NSColor *color);
// Where the second figure's head of SZFriendsDrawPeopleIcon lies for an icon drawn in `iconRect` (stroke included),
// so a badge can keep clear of it: covered, the two-people icon reads as one person.
NSRect SZFriendsPeopleIconSecondHeadRect(NSRect iconRect);
// A document glyph with its kind label ("PDF") at the bottom, as transfer cards and chips show it.
void SZFriendsDrawDocumentGlyph(NSRect rect, NSString *_Nullable kindLabel, NSColor *labelColor);
// A count badge (red pill with white text) whose top-right corner sits at `corner`.
NSRect SZFriendsBadgeRect(NSString *label, NSPoint topRight, NSFont *font);
void SZFriendsDrawBadge(NSString *label, NSRect rect, NSFont *font, SZFriendsAppearance *appearance);

NS_ASSUME_NONNULL_END
