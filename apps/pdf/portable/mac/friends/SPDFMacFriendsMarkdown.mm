#import "SPDFMacFriendsMarkdown.h"

#import <objc/runtime.h>
#import "markdown/SPDFMarkdownDiagram.h"

static const void* kPassAllowanceKey = &kPassAllowanceKey;

// One diagram cache per message, so a bubble asking again at another width re-lays out only its diagrams' boxes,
// and a theme change reuses them outright (a layout carries colour roles, not colours). At the same width and
// colours the renderer's own kept blocks answer first, tables and code included (SPDFMacChatMarkdown.h).
static SPDFMarkdownDiagramCache* DiagramCacheForMessage(NSString* markdown) {
    static NSCache<NSString*, SPDFMarkdownDiagramCache*>* caches;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      caches = [NSCache new];
      caches.countLimit = 64;
    });
    SPDFMarkdownDiagramCache* cache = [caches objectForKey:markdown];
    if (!cache) {
        cache = [SPDFMarkdownDiagramCache new];
        [caches setObject:cache forKey:markdown];
    }
    return cache;
}

SPDFMacChatMarkdownOptions* SPDFMacFriendsMarkdownOptions(NSString* markdown, CGFloat width, NSAppearance* appearance,
                                                          SZFriendsAppearance* theme,
                                                          SPDFMacChatMarkdownImageFetch fetchImage,
                                                          SPDFMacChatMarkdownAllowance* allowance) {
    BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
        isEqualToString:NSAppearanceNameDarkAqua];
    SPDFMacChatMarkdownOptions* options = [SPDFMacChatMarkdownOptions new];
    options.width = width;
    options.dark = dark;
    options.links = SPDFMacChatMarkdownLinksFriends;
    options.keepsWideBlocks = YES;
    options.textColor = SPDFMacChatConcreteColor(theme.primaryTextColor, dark);
    options.secondaryTextColor = SPDFMacChatConcreteColor(theme.secondaryTextColor, dark);
    options.linkColor = SPDFMacChatConcreteColor(theme.accentColor, dark);
    // A Load image click holds for this message's text. An identical message shows the image already in memory, so
    // its sender learns nothing new: nothing is fetched again.
    options.messageKey = markdown;
    options.fetchImage = fetchImage;
    options.diagramCache = DiagramCacheForMessage(markdown);
    options.allowance = allowance;
    // A link in a drawn table opens through Friends' own link menu, like every other link in a friend's message: the
    // same words for the person, and the Friends context opens it, not the engine's menu and NSWorkspace.
    options.linkHandler = ^(NSURL* URL, NSString* shownText, NSView* view, NSPoint point) {
        SZFriendsShowLinkMenuInView(view, URL, shownText, point);
    };
    return options;
}

NSAttributedString* SPDFMacFriendsRenderMarkdown(NSString* markdown, CGFloat width, NSAppearance* appearance,
                                                 SZFriendsAppearance* theme, SPDFMacChatMarkdownImageFetch fetchImage,
                                                 SPDFMacChatMarkdownAllowance* allowance) {
    return SPDFMacChatMarkdownRender(markdown, SPDFMacFriendsMarkdownOptions(markdown, width, appearance, theme,
                                                                             fetchImage, allowance));
}

@implementation SPDFMacFriendsHost (SPDFMacFriendsMarkdown)
- (SPDFMacChatMarkdownAllowance*)friendsMarkdownAllowance {
    return objc_getAssociatedObject(self, kPassAllowanceKey)
        ?: SPDFMacChatMarkdownCurrentPassAllowance(SPDFMacChatMarkdownPassTotal);
}

- (NSAttributedString*)friendsRenderMarkdown:(NSString*)markdown width:(CGFloat)width
                                  appearance:(NSAppearance*)appearance {
    SPDFMacChatMarkdownAllowance* allowance = self.friendsMarkdownAllowance;
    // Spent: the views show the plain text they already have, which costs nothing here (SZFriendsHost.h).
    if (allowance.spent) return nil;
    return SPDFMacFriendsRenderMarkdown(markdown ?: @"", width, appearance, [self friendsAppearance], nil, allowance);
}

// The views open a pass for every layout of a conversation's messages and close it before returning to the run
// loop; passes never nest, so a begin simply starts a fresh allowance.
- (void)friendsBeginMarkdownPass {
    SPDFMacChatMarkdownAllowance* allowance =
        [[SPDFMacChatMarkdownAllowance alloc] initWithTotal:SPDFMacChatMarkdownPassTotal];
    objc_setAssociatedObject(self, kPassAllowanceKey, allowance, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)friendsEndMarkdownPass {
    objc_setAssociatedObject(self, kPassAllowanceKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end
