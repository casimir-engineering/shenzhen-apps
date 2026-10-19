// Shenzhen Friends history items: what the item classes spread over several files share (internal).

#import "mac/SZFriendsConversationPage.h"

NS_ASSUME_NONNULL_BEGIN

// What every item subclass reads and overrides; SZFriendsItemViews.m implements it.
@interface SZFriendsItemView ()
@property(nonatomic, strong) SZFriendsContext *context;
@property(nonatomic, copy) NSDictionary *item;
@property(nonatomic, copy, readwrite) NSString *itemID;
@property(nonatomic, copy, readwrite) NSString *itemKind;
@property(nonatomic, readwrite) BOOL highlighted;
@property(nonatomic, copy, readwrite) NSArray<SZFriendsButton *> *actionButtons;
@property(nonatomic, strong, readwrite, nullable) NSView *progressView;
- (void)setUp;
- (CGFloat)layoutForWidth:(CGFloat)width apply:(BOOL)apply;
- (NSArray<SZFriendsButton *> *)buttonsForActions:(NSArray *)actions;
@end

// "Via the assistant" (the item's assistant_label) on the time line under a bubble or a transfer card: a small spark
// and the helper's words, leading the line on the item's side. Hidden when the item has no label.
@interface SZFriendsAssistantLabelView : SZFriendsFlippedView
- (instancetype)initWithAppearance:(SZFriendsAppearance *)appearance;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, readonly) CGFloat fittingWidth; // 0 without text
@end

// The words inside a message bubble: the helper's plain segments, or, when the item's text_format is "markdown"
// and the host renders it, the host's rendering (SZFriendsHost.h § Optional Markdown rendering). Blocks wider than
// the bubble (tables, diagrams) scroll sideways inside it; the conversation still scrolls vertically over them.
@interface SZFriendsMessageBody : NSView
- (instancetype)initWithContext:(SZFriendsContext *)context;
- (void)applyItem:(NSDictionary *)item;
// The size the body needs: its natural width when narrower than the limit, and the height at that width. Plain text
// keeps to `plainWidth`; the host's Markdown may use `markdownWidth` (tables, code). Renders and caches as needed.
- (NSSize)sizeForPlainWidth:(CGFloat)plainWidth markdownWidth:(CGFloat)markdownWidth;
@property(nonatomic, weak, readonly, nullable) SZFriendsContext *context;
@property(nonatomic, readonly) BOOL showsMarkdown; // YES while the host's rendering is shown
// The plain words, laid out and measured by this one text view (selectable; its links answer with the link menu).
@property(nonatomic, strong, readonly) NSTextView *plainText;
// Under plain text cut short (welcome string show_all); hidden when the whole message shows.
@property(nonatomic, strong, readonly) SZFriendsButton *showAllButton;
@property(nonatomic, strong, readonly, nullable) NSTextView *markdownView;
// One sideways-scrolling strip per wide block, inside markdownView (tests read their frames and content widths).
@property(nonatomic, copy, readonly) NSArray<NSScrollView *> *wideBlocks;
// The bubble's fill, which a strip fades into at an edge with more of its block beyond it.
@property(nonatomic, strong, nullable) NSColor *edgeColor;
@end

// A bubble's text view; Copy and drags carry plain text from SZFriendsMarkdownCopyText (SZFriendsWideBlocks.m).
@interface SZFriendsMarkdownTextView : NSTextView
@property(nonatomic, copy) NSString *source;
@end

// One wide block at its natural size, drawn from the host's attachment as the text system would draw it, and
// clicked through its cell as the text system would (a code block's Copy, a link in a table).
@interface SZFriendsAttachmentView : NSView
@property(nonatomic, strong) NSTextAttachment *attachment;
@property(nonatomic) NSUInteger characterIndex; // the placeholder's, in the message's text
@end

// A wide block's strip. It scrolls sideways itself and passes vertical wheel movement on to the conversation, so a
// table under the pointer never stops the history from scrolling.
@interface SZFriendsWideBlockScrollView : NSScrollView
@property(nonatomic, strong, readonly) SZFriendsEdgeFade *leadingFade;
@property(nonatomic, strong, readonly) SZFriendsEdgeFade *trailingFade;
- (void)setFadeColor:(nullable NSColor *)color;
- (void)updateFades;
@end

// YES when `text` holds anything Markdown draws differently from plain text (emphasis, code, a list, a table...).
BOOL SZFriendsTextMayBeMarkdown(NSString *text);

// What copying `range` of a rendered message gives: `source` when the range holds everything visible, otherwise the
// text shown, with each SZFriendsMarkdownSourceAttributeName range replaced by its source and attachment characters
// that have none dropped.
NSString *SZFriendsMarkdownCopyText(NSAttributedString *rendered, NSRange range, NSString *source);

// Links in a friend's message (SZFriendsLinkMenu.m). A click never opens one: it shows a menu with the address the
// link goes to, a warning first when the link's words show another site or address, then the open item.
BOOL SZFriendsLinkMayOpen(NSURL *url); // https, http and mailto; nothing else in a friend's message opens
// What the link's words show (a host, or an email address) when the link goes somewhere else; nil when the words
// are not an address or show where it goes.
NSString *_Nullable SZFriendsLinkShownElsewhere(NSString *text, NSURL *url);
// The address as the menu shows it: whole up to about 80 characters, then cut in the path, never in the host.
NSString *SZFriendsLinkAddressTitle(NSURL *url);
// The menu for `url` clicked on `text`; its words come from welcome.strings (link_elsewhere, link_open,
// link_open_email), and without them the address item itself opens the link.
NSMenu *SZFriendsLinkMenu(SZFriendsContext *context, NSURL *url, NSString *text);
// Answers a click on `link` at `charIndex` in `textView`: the menu through context.presentMenu, under the link.
void SZFriendsShowLinkMenu(SZFriendsContext *_Nullable context, id _Nullable link, NSTextView *textView,
                           NSUInteger charIndex);

// How strongly a cancelled message's bubble shows (its alphaValue): faded like the list's rows that take nothing.
extern const CGFloat SZFriendsCancelledBubbleAlpha;

@interface SZFriendsMessageItemView : SZFriendsItemView
@property(nonatomic, strong, readonly) SZFriendsMessageBody *body;
@property(nonatomic, strong, readonly) NSView *bubble; // the rounded fill around the body
@property(nonatomic, strong, readonly) SZFriendsAssistantLabelView *assistantLabel;
@property(nonatomic, strong, readonly) NSTextField *timeLabel;
@end

// The picture at a transfer card's leading edge (SZFriendsFilePreview.m): the helper's preview of the file, laid out
// from its width and height before it loads, or the file type's icon when there is none or it cannot be read.
typedef NS_ENUM(NSInteger, SZFriendsPreviewState) {
    SZFriendsPreviewTypeIcon = 0, // no preview, or one missing or unreadable
    SZFriendsPreviewLoading,      // its place is laid out; the picture is on its way
    SZFriendsPreviewShown,
};

@interface SZFriendsFilePreviewView : NSView
@property(nonatomic, strong) SZFriendsAppearance *theme;
- (void)applyFile:(nullable NSDictionary *)file thumbnail:(nullable NSDictionary *)thumbnail; // PROTOCOL.md objects
@property(nonatomic, readonly) SZFriendsPreviewState state;
@property(nonatomic, readonly) NSSize size; // the slot the card gives it
@property(nonatomic, strong, readonly, nullable) NSImage *image;
@property(nonatomic, strong, readonly, nullable) NSImage *typeIcon; // file.type_identifier's; nil: the drawn page
@end

// The preview at `path` when it is the helper's (directly in its state directory's thumbnails/), a regular file and a
// PNG of exactly `width` x `height` pixels, 1 to 192; NULL otherwise. Any thread; the caller releases it.
CGImageRef _Nullable SZFriendsCopyThumbnailImage(NSString *path, NSInteger width, NSInteger height) CF_RETURNS_RETAINED;

@interface SZFriendsTransferItemView : SZFriendsItemView
@property(nonatomic, strong, readonly) SZFriendsAssistantLabelView *assistantLabel;
@property(nonatomic, strong, readonly) NSTextField *timeLabel;
@property(nonatomic, strong, readonly) SZFriendsFilePreviewView *preview;
@end

NS_ASSUME_NONNULL_END
