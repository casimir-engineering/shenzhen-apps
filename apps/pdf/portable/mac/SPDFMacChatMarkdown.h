#pragma once
// Markdown in chats: AI chat replies and Friends messages, drawn by the reader's Markdown engine at chat scale.
// Plan: portable/docs/plans/ai-agent-capabilities.md § 5.
//
// One renderer for both. The result is an attributed string for an NSTextView `width` points wide:
//   - Flowing text (paragraphs, headings, lists, task lists, quotes, callouts, inline and display math) is the
//     engine's own text at 13 pt, code 12 pt, H1 17, H2 15, H3 13 semibold, and wraps at `width`.
//   - A table, a diagram, a code block and a rule are each ONE attachment on a paragraph of its own, drawn from the
//     engine's page plan (code boxes, table chrome, vector diagrams) at the block's natural size. A table is sized
//     to the bubble and grows only when its columns would not fit; a code block does not wrap; a diagram is laid
//     out for the bubble and grows only when its labels would fall below 11 pt. keepsWideBlocks says whether the
//     caller scrolls a wider block sideways (AI chat and Friends do) or wants it scaled down to `width`.
//   - A remote image is a placeholder naming its host, with Load image. Nothing is fetched until that click, and
//     the choice holds for that message only. Local, data and non-https images are never read.
//   - Links: AI chat keeps SPDFMacAIChatLinkAllowed (http(s), document and Friends citations); Friends messages keep
//     https only. Every https link carries its destination as a tooltip. Raw HTML is never run: the engine turns
//     its safe subset into ordinary text. Diagram and math layout keep the engine's deadlines and size caps.
//   - Limits, so a hostile message cannot stall a conversation that lays out every message at once: a table draws
//     at most 500 rows and 10,000 cells, the rest following as text. A render takes at most 0.4 s, parsing included,
//     and no more than its allowance has left when several renders share one (SPDFMacChatMarkdownAllowance): tables,
//     code and diagrams are drawn while it has time, later ones appear as text after a note, and past that the rest
//     of the message is plain text. A render that starts with nothing left returns the message as plain text.
//   - Drawn controls (Copy on code, links in a table, Load image) are buttons to assistive apps, with a label and a
//     press action. A link in a table shows where it goes before it opens (see linkHandler).
// Copying: a drawn block carries SPDFMacChatMarkdownSourceAttribute (its Markdown, or a code block's code), which
// is the Friends views' SZFriendsMarkdownSourceAttributeName; SPDFMacChatMarkdownCopyText applies it.
//
// Main thread only: attachments draw and track clicks in the view that shows them.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownDiagramCache;

typedef NS_ENUM(NSInteger, SPDFMacChatMarkdownLinks) {
    SPDFMacChatMarkdownLinksAssistant = 0,  // SPDFMacAIChatLinkAllowed
    SPDFMacChatMarkdownLinksFriends,        // https without credentials, nothing else
};

// Delivers an image's bytes, or nil, on any queue. Tests pass one; nil fetches over the network (an ephemeral
// session, https redirects only, image/* only, 20 MB at most: SPDFMacMarkdownSessionImageLoader).
typedef void (^SPDFMacChatMarkdownImageFetch)(NSURL* URL, void (^completion)(NSData* _Nullable data));

// A link clicked or pressed inside a drawn table: its address, the words the cell shows for it, and where in `view`
// to put a menu, so a host can show the link in its own menu (Friends does).
typedef void (^SPDFMacChatMarkdownLinkHandler)(NSURL* URL, NSString* shownText, NSView* view, NSPoint point);

// Render time that several renders share. Friends gives every message of one conversation render pass the same
// allowance, so a conversation of hostile messages costs at most about its total, not 0.4 s per message: a render
// takes what is left, up to its own 0.4 s, and spends from it what the render took (parsing and text fallbacks
// included). Once nothing is left, later renders return their message as plain text at once. Main thread only.
@interface SPDFMacChatMarkdownAllowance : NSObject
- (instancetype)initWithTotal:(NSTimeInterval)total NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly) NSTimeInterval total;
@property(nonatomic, readonly) NSTimeInterval remaining;  // 0 once spent
@property(nonatomic, readonly, getter=isSpent) BOOL spent;
// Takes `seconds` off what is left; renders call this themselves.
- (void)spend:(NSTimeInterval)seconds;
@end

// What one Friends conversation render pass may spend on Markdown: 1 s, on top of each message's own 0.4 s.
FOUNDATION_EXPORT const NSTimeInterval SPDFMacChatMarkdownPassTotal;
// The allowance for the main thread's current pass: renders made before the main queue next runs share it, and the
// first render after that gets a fresh one. For a host that is asked for one message at a time and cannot tell where
// a conversation's layout pass begins or ends. Main thread only.
SPDFMacChatMarkdownAllowance* SPDFMacChatMarkdownCurrentPassAllowance(NSTimeInterval total);

@interface SPDFMacChatMarkdownOptions : NSObject <NSCopying>
@property(nonatomic) CGFloat width;
@property(nonatomic) BOOL dark;
@property(nonatomic) SPDFMacChatMarkdownLinks links;
@property(nonatomic) BOOL keepsWideBlocks;  // default YES
// Concrete colours for the bubble the text sits in; -setDark: resets them to the reader's chrome palette.
@property(nonatomic, strong) NSColor* textColor;
@property(nonatomic, strong) NSColor* secondaryTextColor;
@property(nonatomic, strong) NSColor* linkColor;
// Which message an image consent belongs to. Default: the Markdown itself.
@property(nonatomic, copy, nullable) NSString* messageKey;
@property(nonatomic, copy, nullable) SPDFMacChatMarkdownImageFetch fetchImage;
// A Load image finished (loaded or failed); a caller that can re-render does, so the image gets its own size.
@property(nonatomic, copy, nullable) void (^imageFinished)(void);
// A link clicked inside a drawn block (a citation in a table), first to linkHandler, else to openLink. Neither set:
// an https link shows the engine's menu, which names the address (and, when the cell's words show another site,
// "Goes to <host>, not <shown>") above Open in Browser; anything else is ignored.
@property(nonatomic, copy, nullable) SPDFMacChatMarkdownLinkHandler linkHandler;
@property(nonatomic, copy, nullable) void (^openLink)(NSURL* URL);
// A link written without a scheme ("docs/Report.pdf", "example.com"): the address it stands for, or nil to show its
// words as plain text. nil: such links are plain text.
@property(nonatomic, copy, nullable) NSURL* _Nullable (^bareLink)(NSString* destination);
// Where a code block's Copy writes. nil: the general pasteboard.
@property(nonatomic, strong, nullable) NSPasteboard* pasteboard;
// Shared across renders of one message, so a width change reuses diagram layouts. nil: a fresh one per render.
// (Whole laid-out blocks are also kept, for any message, when the width and colours are the same.)
@property(nonatomic, strong, nullable) SPDFMarkdownDiagramCache* diagramCache;
// Shared with other renders (one Friends conversation pass); nil: this render has its own 0.4 s only.
@property(nonatomic, strong, nullable) SPDFMacChatMarkdownAllowance* allowance;
@end

NSAttributedString* SPDFMacChatMarkdownRender(NSString* markdown, SPDFMacChatMarkdownOptions* options);
// The link policy: Friends allows https without credentials; the assistant also http, its document and Friends
// citations.
BOOL SPDFMacChatMarkdownLinkAllowed(NSURL* _Nullable URL, SPDFMacChatMarkdownLinks links);

// On a drawn block or image placeholder: what copying it gives (equal to SZFriendsMarkdownSourceAttributeName).
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMacChatMarkdownSourceAttribute;
// On a drawn block: its natural size as an NSValue, so a view can scroll one wider than `width` sideways.
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMacChatMarkdownBlockSizeAttribute;

// The text copying `range` gives: drawn blocks as their source (once each), other attachments dropped.
NSString* SPDFMacChatMarkdownCopyText(NSAttributedString* rendered, NSRange range);

// A colour as the light or dark appearance draws it, in concrete sRGB (the engine bakes colours into its text).
NSColor* SPDFMacChatConcreteColor(NSColor* color, BOOL dark);

// The 11 pt floor for diagram labels at chat scale, and the font size every chat diagram label reaches or exceeds.
FOUNDATION_EXPORT const CGFloat SPDFMacChatMarkdownMinimumDiagramLabelSize;

NS_ASSUME_NONNULL_END
