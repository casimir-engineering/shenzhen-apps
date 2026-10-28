#pragma once
// The AI chat panel's own controls, shared by SPDFMacAIChatView and its activity rows (SPDFMacAIChatActivityView):
// the flat chat button, the action pill, wrapping labels, the framed image, the self-measuring message text view,
// the composer and its bordered scroll view, a card's literal text and a step's list of links; and, for editing an
// earlier question, the speaker row with its Edit button and the marker where earlier messages were summarized.
#import <Cocoa/Cocoa.h>
#import "SPDFMacGroupActionButton.h"
@interface SPDFChatButton : SPDFGroupActionButton
// Shown only while the pointer is over its message, or while it has keyboard focus.
@property(nonatomic) BOOL revealOnHover;
- (void)setRevealed:(BOOL)revealed;
@end
@interface SPDFChatMessageView : NSTextView
@property(nonatomic) NSLayoutConstraint* contentHeight;
@property(nonatomic) BOOL measurementScheduled;
@property(nonatomic) CGFloat measuredWidth;
// Measures the text again now, after an edit changed it.
- (void)remeasure;
@end
// Mouse entered and exited events over all of `owner`, while its window is key.
NSTrackingArea* SPDFChatHoverArea(NSView* owner);
// A speaker label row that can carry an Edit button on its trailing edge.
@interface SPDFChatRoleRow : NSView
@property(nonatomic, readonly) NSTextField* label;
@property(nonatomic, readonly) SPDFChatButton* editButton;
- (instancetype)initWithLabel:(NSTextField*)label editButton:(SPDFChatButton*)button;
@end
// A message's place among the others, not counting summary markers. A summary inserts its marker
// before later messages and never removes or reorders them, so a message keeps its place.
NSUInteger SPDFChatMessagePlace(NSArray<NSDictionary*>* messages, NSUInteger index);
// Where the question being edited is now: your message at that place with the original text, else NSNotFound.
NSUInteger SPDFChatEditedMessageIndex(NSArray<NSDictionary*>* messages, NSUInteger place, NSString* original);
// The short transcript line shown where earlier messages were summarized.
NSTextField* SPDFChatSummaryMarker(void);
// The composer's height: three lines when short; it grows with its text up to about eight lines, then scrolls.
static const CGFloat SPDFChatComposerHeight=68, SPDFChatComposerMaximumHeight=148;
@interface SPDFChatInputScrollView : NSScrollView
- (void)updateBorder;
- (BOOL)composerFocused;
// The height that shows all of its text at its present width, kept between the composer's usual and maximum heights.
- (CGFloat)fittingHeight;
@end
@interface SPDFChatComposer : NSTextView
// After the text changes; after the width it wraps at changes, once that layout pass is over, so the field's height
// constraint can change.
@property(nonatomic, copy) void (^fit)(void);
@property(nonatomic, copy) void (^submit)(void);
@property(nonatomic, copy) void (^undoAction)(void);
@property(nonatomic, copy) void (^redoAction)(void);
@property(nonatomic, copy) void (^closeAction)(void);
@end
@interface SPDFChatFlippedView : NSView @end
// A chat button: 28 pt tall, its title or symbol drawn by SPDFChatButton, `identifier` sent to `target` as the action.
NSButton* SPDFChatMakeButton(NSString* title, NSString* identifier, id target, SEL action);
// A square symbol button `side` points wide (a disclosure chevron on a compact row).
NSButton* SPDFChatMakeSymbolButton(NSString* symbol, NSString* identifier, id target, SEL action, CGFloat side);
// An action on an activity row, drawn like the chat Markdown's Copy and Load image so it reads as a button and not
// as text: a bordered 22 pt pill with a hover fill. `primary` fills it with the accent colour, for the one action a
// card waits for (Install, Try Again).
@interface SPDFChatPillButton : SPDFChatButton
@property(nonatomic) BOOL primary;
@property(nonatomic) BOOL hovered;
@end
SPDFChatPillButton* SPDFChatMakePill(NSString* title, NSString* identifier, id target, SEL action, BOOL primary);
// A label that never asks its row for more width than it has: single-line ones truncate at the tail, wrapping ones
// (`wraps`) re-wrap whenever their width changes. `width` is the first width to wrap at.
NSTextField* SPDFChatLabel(NSString* text, CGFloat size, NSFontWeight weight, NSColor* color, BOOL wraps,
                           CGFloat width);
// A picture with a 1 pt hairline frame, so a white chart still has an edge on the white panel.
@interface SPDFChatFramedImageView : NSImageView @end
// Text saying something failed: red with at least 4.5:1 contrast on the chat's background in light and dark
// (systemRed is about 3.6:1 on white at 12 pt).
NSColor* SPDFChatFailureColor(void);
// The exact text of a card the person approves before it leaves the Mac (SPDFMacAIActivityBodyStyleLiteral): plain
// 13 pt text on the message tint, wrapped (a word longer than the line breaks too), never Markdown, and each
// character that draws nothing shown as a "‹U+200B›" marker in the secondary colour. `marked` says whether any was.
SPDFChatMessageView* SPDFChatLiteralTextView(NSString* text, CGFloat width, BOOL* marked);
// The pages a step links to, one row each: the title (or the bare address) as a link that truncates, then its host,
// which stays whole because it says which site the page is on. `links` are {url: NSURL, title?, host, insecure?};
// the host shows only beside a title. An insecure (http) row is never a link: its title in plain text and the host,
// with "Not a secure page" on its own line under them. Clicks reach `delegate`'s -textView:clickedOnLink:atIndex:.
NSStackView* SPDFChatLinkList(NSArray<NSDictionary*>* links, CGFloat width, id<NSTextViewDelegate> delegate);
// What the chat's heading says under "Working…" while the assistant runs `tool` ("Searching the web…"), in the
// person's words; nil for a tool it has no words for, so no identifier ever shows.
NSString* SPDFChatRunningToolText(NSString* tool);
