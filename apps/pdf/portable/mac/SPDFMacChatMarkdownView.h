#pragma once
// One AI chat message: its Markdown rendered by SPDFMacChatMarkdown.h in a selectable text view drawn as a bubble.
// A table, code block or diagram wider than the bubble scrolls sideways inside it; the transcript still scrolls
// vertically over it. The message re-renders when its width or appearance changes, and when an image it was asked
// to load arrives. Copy gives drawn blocks as their source (a code block's code, a table's Markdown).
#import <Cocoa/Cocoa.h>
#import "SPDFMacChatMarkdown.h"

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacChatMarkdownView : NSTextView
// Rendered at once for a bubble `width` wide (text insets included). `options` gives links, fetching and colours;
// its width and darkness follow the view. The bubble's text inset is 10 by 8 pt.
- (instancetype)initWithMarkdown:(NSString*)markdown width:(CGFloat)width options:(SPDFMacChatMarkdownOptions*)options;
// The same with another text inset, NSZeroSize for text flush with the view's edges (an activity card's body under
// its title), rendered once with it.
- (instancetype)initWithMarkdown:(NSString*)markdown
                           width:(CGFloat)width
                         options:(SPDFMacChatMarkdownOptions*)options
                       textInset:(NSSize)inset;
@property(nonatomic, copy, readonly) NSString* markdown;
// The bubble's height constraint, kept to the rendered text (text insets included). Activated by the owner.
@property(nonatomic, strong, readonly) NSLayoutConstraint* contentHeight;
// One sideways-scrolling strip per block wider than the bubble.
@property(nonatomic, copy, readonly) NSArray<NSScrollView*>* wideBlocks;
// Renders again now for the current width and appearance.
- (void)renderNow;
@end

NS_ASSUME_NONNULL_END
