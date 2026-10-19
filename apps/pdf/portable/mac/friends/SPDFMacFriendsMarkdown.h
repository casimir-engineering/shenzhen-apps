// Friend messages as Markdown: ShenzhenPDF's answer to the views' -friendsRenderMarkdown:width:appearance:
// (portable/friends/mac/SZFriendsHost.h § Optional Markdown rendering), drawn by the same renderer as AI chat
// (SPDFMacChatMarkdown.h) with Friends' rules: https links only, each showing where it goes and opening through
// Friends' own link menu, in tables too (SZFriendsShowLinkMenuInView); a remote image is a placeholder until the
// person clicks Load image on that message; tables, code and diagrams keep their natural size for the bubble to
// scroll sideways, and carry their Markdown for copying (SZFriendsMarkdownSourceAttributeName).
//
// Time. A conversation lays out all its messages at once on the main thread, so the renders of one pass (the views
// bracket it with -friendsBeginMarkdownPass and -friendsEndMarkdownPass) share one allowance of
// SPDFMacChatMarkdownPassTotal, 1 s, on top of each render's own 0.4 s. Once it is spent the host answers nil and
// the views show the message's plain text, so fifty hostile messages cost about a second, not fifty times 0.4 s. A
// render outside a pass (a bubble asking again after Load image) shares the main thread's current pass allowance.
// Laid-out tables, code and diagrams are kept: diagrams per message (SPDFMarkdownDiagramCache, reused across widths
// and appearances), tables and code by the renderer for the same width and colours, so reopening a conversation or
// switching the appearance back draws them again without laying them out or spending the allowance on it.

#import <AppKit/AppKit.h>
#import "SPDFMacChatMarkdown.h"
#import "SPDFMacFriendsHost.h"

NS_ASSUME_NONNULL_BEGIN

// The render behind the host method, with its inputs explicit so tests need no host. `appearance` picks light or
// dark; `theme` gives the bubble's text, secondary and link colours, resolved for that appearance; `allowance` is
// the pass's shared time (nil: this render's own 0.4 s only).
NSAttributedString* SPDFMacFriendsRenderMarkdown(NSString* markdown, CGFloat width, NSAppearance* appearance,
                                                 SZFriendsAppearance* theme,
                                                 SPDFMacChatMarkdownImageFetch _Nullable fetchImage,
                                                 SPDFMacChatMarkdownAllowance* _Nullable allowance);
// The options that render uses. A link clicked in a drawn table goes to the views' SZFriendsShowLinkMenuInView.
SPDFMacChatMarkdownOptions* SPDFMacFriendsMarkdownOptions(NSString* markdown, CGFloat width, NSAppearance* appearance,
                                                          SZFriendsAppearance* theme,
                                                          SPDFMacChatMarkdownImageFetch _Nullable fetchImage,
                                                          SPDFMacChatMarkdownAllowance* _Nullable allowance);

@interface SPDFMacFriendsHost (SPDFMacFriendsMarkdown)
// nil once the pass's allowance is spent: the views then show the message's plain text.
- (nullable NSAttributedString*)friendsRenderMarkdown:(NSString*)markdown
                                                width:(CGFloat)width
                                           appearance:(NSAppearance*)appearance;
- (void)friendsBeginMarkdownPass;
- (void)friendsEndMarkdownPass;
// The allowance renders share now: the open pass's, else the main thread's current one. Tests read and spend it.
@property(nonatomic, readonly) SPDFMacChatMarkdownAllowance* friendsMarkdownAllowance;
@end

NS_ASSUME_NONNULL_END
