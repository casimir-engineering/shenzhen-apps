#import "SPDFMacMarkdownSessionPrivate.h"

#import <objc/runtime.h>

// The highlights live on the session, not the paged view, because every rerender builds a new paged view
// (SPDFMacMarkdownSession+ViewSwap.mm hands them on).
@implementation SPDFMacMarkdownSession (Comments)
static char kCommentHighlightsKey;

- (NSArray<NSDictionary*>*)commentHighlights {
    return objc_getAssociatedObject(self, &kCommentHighlightsKey);
}

- (void)setCommentHighlights:(NSArray<NSDictionary*>*)highlights {
    objc_setAssociatedObject(self, &kCommentHighlightsKey, [highlights copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    _pagedView.commentHighlights = highlights;
}
@end
