#pragma once
// Internal pieces of SPDFMacChatMarkdown.h: blocks drawn from their own page plan, and the attachments that show
// them and remote-image placeholders inside a text view.
#import "SPDFMacChatMarkdown.h"
#import "markdown/SPDFMarkdownDiagram.h"
#import "markdown/SPDFMarkdownPaginator.h"
#import "markdown/SPDFMarkdownParser.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacChatBlockKind) {
    SPDFMacChatBlockTable = 0,
    SPDFMacChatBlockDiagram,
    SPDFMacChatBlockCode,
};

// One block rendered alone and paginated onto one tall page `layoutWidth` wide. `contentRect` is the drawn part
// in page coordinates (x from the left, y down from the top): the code box, the table grid, the diagram; the
// engine's outer margins around it are left out because the chat paragraph already spaces blocks.
@interface SPDFMacChatBlock : NSObject
@property(nonatomic) SPDFMacChatBlockKind kind;
@property(nonatomic, strong) SPDFMarkdownRenderedDocument* rendered;
@property(nonatomic, strong) SPDFMarkdownPaginationPlan* plan;
@property(nonatomic) NSRect contentRect;
@property(nonatomic) SPDFMarkdownThemeVariant variant;
@property(nonatomic, copy) NSString* source;  // what copying the block gives
@property(nonatomic, copy, nullable) NSString* language;  // a code block's fence language, shown in its header
// Citation links travel under https aliases through the engine (SPDFMacChatMarkdown.mm); clicks map them back.
@property(nonatomic, copy, nullable) NSDictionary<NSString*, NSURL*>* aliases;
// The column the block sits in: Copy stays at its right edge however far the code runs past it.
@property(nonatomic) CGFloat visibleWidth;
// A diagram's node borders, in the bubble's secondary text colour (SPDFMacChatMarkdownDiagrams.mm).
@property(nonatomic, strong, nullable) NSColor* nodeStrokeColor;
@end

// A cell that draws itself with y running down from its top-left corner, at its cellSize.
@protocol SPDFMacChatContentCell <NSTextAttachmentCell>
- (void)drawContent;
@optional
// How far a sideways strip has scrolled the block: a code block's header (language, Copy) stays in view.
@property(nonatomic) CGFloat headerOffset;
@end

// An attachment drawn and clicked through its cell. It has no image or bounds of its own: TextKit 1 lets a cell track
// clicks only then (with either set it treats the attachment as a picture and ignores the cell). Views that draw an
// attachment as an image (a sideways strip, TextKit 2) get the cell's drawing from -imageForBounds:.
@interface SPDFMacChatAttachment : NSTextAttachment
+ (instancetype)attachmentWithCell:(NSTextAttachmentCell<SPDFMacChatContentCell>*)cell;
@end

// Chat-scale engine options: 13 pt text, 12 pt code, concrete colours from `options`, no resource of any kind.
SPDFMarkdownRenderOptions* SPDFMacChatRenderOptions(SPDFMacChatMarkdownOptions* options);
// The engine's rendered text at chat scale: headings 17, 15 and 13 pt, list items 2 pt apart, display math at 13 pt.
// Run before anything moves the rendered blocks' ranges.
void SPDFMacChatScaleText(NSMutableAttributedString* text, SPDFMarkdownRenderedDocument* rendered);
// On a drawn diagram's characters: SPDFMacChatSpaceBlocks sets its paragraph, like a display formula's, closer to
// its neighbours, then removes the mark.
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMacChatTightBlockAttribute;
void SPDFMacChatSpaceBlocks(NSMutableAttributedString* text);
// A block shown as text rather than drawn: `shown` in the code font, after `note` in the secondary colour. Its lines
// break with U+2028 inside the one paragraph the block stands in, so rows are not spaced apart like paragraphs;
// copying gives `copied`, and nothing for the note.
NSAttributedString* SPDFMacChatTextBlock(NSString* shown, NSString* copied, NSString* _Nullable note,
                                         SPDFMacChatMarkdownOptions* options);

// Lays out a table, a non-wrapping code block or a diagram for a column `visibleWidth` wide. A diagram that would
// put a label under SPDFMacChatMarkdownMinimumDiagramLabelSize is laid out wider instead (or larger, when its
// smallest labels are small even at natural size). `timeLeft` is what this message has left for laying out drawn
// blocks; the layout's own time comes off it. nil when it is already spent (the caller shows the block as text) or
// the block cannot be drawn (a diagram falls back to code).
SPDFMacChatBlock* _Nullable SPDFMacChatLayOutBlock(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind,
                                                   CGFloat visibleWidth, SPDFMacChatMarkdownOptions* options,
                                                   SPDFMarkdownDiagramCache* cache, NSTimeInterval* timeLeft);

// One render's clock (SPDFMacChatMarkdownBudget.mm), started before parsing: `budget` is the most it may take (0.4 s,
// or less when its allowance has less left); drawn blocks start only before `drawUntil` and the walk over the
// message's blocks stops at `walkUntil`, which leaves the rest of the budget for the engine to set the text.
typedef struct {
    NSTimeInterval start, budget, drawUntil, walkUntil;
} SPDFMacChatClock;
NSTimeInterval SPDFMacChatNow(void);
SPDFMacChatClock SPDFMacChatStartClock(SPDFMacChatMarkdownAllowance* _Nullable allowance);
// Spends the render's time from `allowance`.
void SPDFMacChatStopClock(SPDFMacChatClock clock, SPDFMacChatMarkdownAllowance* _Nullable allowance);
// The most one render may take: 0.4 s. Test seam: a value <= 0 restores it.
NSTimeInterval SPDFMacChatLayoutTime(void);
void SPDFMacChatSetLayoutTime(NSTimeInterval seconds);
// Test seam: every block laid out from here on counts as taking this much longer than it did, so a test can spend
// a message's time at a chosen block whatever the machine. 0 turns it off. SPDFMacChatLayOutBlock calls
// SPDFMacChatPassExtraLayoutTime after each layout.
void SPDFMacChatSetExtraLayoutTime(NSTimeInterval seconds);
void SPDFMacChatPassExtraLayoutTime(void);

// Laid-out blocks kept in memory (a few tens of MB at most), so rendering the same block again at the same width and
// colours, as reopening a conversation or switching appearance back does, reuses its layout. The key covers the
// block's content (links included), its kind and column, and everything in `options` it is drawn with.
NSString* SPDFMacChatBlockKey(SPDFMarkdownBlock* block, SPDFMacChatBlockKind kind, CGFloat column,
                              SPDFMacChatMarkdownOptions* options);
SPDFMacChatBlock* _Nullable SPDFMacChatKeptBlock(NSString* key);
void SPDFMacChatKeepBlock(NSString* key, SPDFMacChatBlock* block);
// Test seam: forgets every kept block, so a timed render lays its blocks out afresh.
void SPDFMacChatForgetKeptBlocks(void);
// The rest of a message once its time is spent, as plain text: its blocks a blank line apart, their words in order,
// tables and code as their Markdown, list items after a dash or number. One pass with no layout, so it is cheap at
// any length.
NSAttributedString* SPDFMacChatPlainRest(NSArray<SPDFMarkdownBlock*>* blocks, NSString* _Nullable note,
                                         SPDFMacChatMarkdownOptions* options);

// The most a chat draws of one table: 500 body rows, 10,000 cells. A table past that keeps its header and first rows
// (`drawnRows` of them) and hands the rest back in `rest` as Markdown rows; otherwise `rest` is nil.
SPDFMarkdownBlock* SPDFMacChatCapTable(SPDFMarkdownBlock* table, NSUInteger* drawnRows,
                                       NSString* _Nullable* _Nonnull rest);
// GitHub table Markdown for a table block: its cells' text and a header separator with each column's alignment.
NSString* SPDFMacChatTableSource(SPDFMarkdownBlock* table);
// `block` with other runs and children, everything else kept.
SPDFMarkdownBlock* SPDFMacChatRebuiltBlock(SPDFMarkdownBlock* block, NSArray<SPDFMarkdownInlineRun*>* runs,
                                           NSArray<SPDFMarkdownBlock*>* children);

// The part of a diagram's box its shapes and labels cover, in diagram-local points (y down).
NSRect SPDFMacChatDiagramInkRect(SPDFMarkdownDiagramLayout* layout);
// The engine's diagram drawing (SPDFMarkdownDrawDiagramShapes) with node borders in `nodeStroke` when given.
void SPDFMacChatDrawDiagramShapes(CGContextRef context, SPDFMarkdownDiagramLayout* layout, CGRect rect,
                                  SPDFMarkdownThemeVariant variant, NSColor* _Nullable nodeStroke);

// Draws the block's content rect at the origin of a y-up context `scale` times its natural size.
void SPDFMacChatDrawBlock(SPDFMacChatBlock* block, CGContextRef context, CGFloat scale);
// The character of the block's own string under `point` (y down from the content rect's top, natural size), or
// NSNotFound off any text.
NSUInteger SPDFMacChatBlockCharacterAtPoint(SPDFMacChatBlock* block, NSPoint point);
// Where the code block's Copy control sits, in the same space; NSZeroRect for other blocks.
NSRect SPDFMacChatBlockCopyRect(SPDFMacChatBlock* block);
// Where the characters `range` of the block's own string are drawn, in the same space; NSZeroRect when nowhere.
NSRect SPDFMacChatBlockRectForRange(SPDFMacChatBlock* block, NSRange range);

// The attachment showing a block, `scale` times its natural size. Clicks on links inside it go to
// options.linkHandler or options.openLink, else to SPDFMacChatLinkMenu; Copy on a code block writes
// options.pasteboard.
NSAttributedString* SPDFMacChatBlockAttachment(SPDFMacChatBlock* block, CGFloat scale,
                                               SPDFMacChatMarkdownOptions* options);
// The engine's menu for an https link in a table: a warning when `shownText` presents another site, the address,
// then Open in Browser (SPDFMacChatMarkdownLinks.mm).
NSMenu* SPDFMacChatLinkMenu(NSURL* URL, NSString* shownText);
// The site or email address `shownText` presents when that is not where `URL` goes, else nil. Words count as an
// address when they carry a scheme, start with www., are an email address, or are a bare name ending in a common web
// ending ("report.pdf" does not count); a subdomain of the shown site is the same site.
NSString* _Nullable SPDFMacChatLinkShownElsewhere(NSString* shownText, NSURL* URL);
// Opens a link from a drawn block as options say (linkHandler, openLink, else the menu above at `point` in `view`).
// NO when nothing could take it.
BOOL SPDFMacChatOpenBlockLink(NSURL* URL, NSString* shownText, SPDFMacChatMarkdownOptions* options,
                              NSView* _Nullable view, NSPoint point);
// A small rounded control drawn inside an attachment ("Copy", "Load image") in the theme's code-control colours.
void SPDFMacChatDrawPill(NSRect rect, NSString* title, SPDFMarkdownTheme* theme, NSColor* ink);
// A thin full-width rule, for `---`.
NSAttributedString* SPDFMacChatRuleAttachment(CGFloat width, SPDFMacChatMarkdownOptions* options);
// A remote image: its picture when this message already loaded it, otherwise a placeholder with its host and
// Load image. `maximumWidth` is the column it sits in.
NSAttributedString* SPDFMacChatImageAttachment(NSURL* URL, NSString* alt, CGFloat maximumWidth,
                                               SPDFMacChatMarkdownOptions* options);

// This message's loaded images and the ones loading, kept in memory for the session: a Load image click holds for
// its message only, across re-renders, and never for another message showing the same address.
NSData* _Nullable SPDFMacChatLoadedImage(NSString* messageKey, NSURL* URL);
BOOL SPDFMacChatImageIsLoading(NSString* messageKey, NSURL* URL);
BOOL SPDFMacChatImageFailed(NSString* messageKey, NSURL* URL);
void SPDFMacChatLoadImage(NSString* messageKey, NSURL* URL, SPDFMacChatMarkdownImageFetch _Nullable fetch,
                          void (^_Nullable finished)(void));
// Test seam: forgets every consent and loaded image.
void SPDFMacChatForgetLoadedImages(void);

NS_ASSUME_NONNULL_END
