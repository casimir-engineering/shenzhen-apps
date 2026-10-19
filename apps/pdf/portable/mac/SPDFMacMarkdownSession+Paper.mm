#import "SPDFMacMarkdownSourceRevision.h"
#import "SPDFMacSearchFileCache.h"
#import "SPDFMacMarkdownSessionPrivate.h"

// The PAPER half of the session: which sheet the document is laid out on.
//
// A Markdown document has no pages of its own — it is text that we choose to
// pour onto A4. So "rotate" here cannot mean what it means for a PDF, where the
// rendered pixels of a fixed page really do turn. It means TURNING THE PAPER:
// the sheet becomes A4 landscape, the printable rect keeps the same four
// margins, and the document re-flows onto wider, shorter pages with every glyph
// still upright and readable.
//
// Because the orientation travels on the pagination plan (via the single
// SPDFMacMarkdownPlanForRendition seam), the screen, print, Save as PDF, Copy
// Page and Copy Page Image paths all follow it without knowing it exists — they
// already read their paper size off plan.configuration.

@implementation SPDFMacMarkdownSession (Paper)

// Mirrors applyThemeVariant: exactly: an active session re-paginates in place
// preserving its viewport, an inactive one adopts the paper and catches up on
// activation (renderTrailsPreferences).
//
// The one difference is the viewport. A font-scale or theme rerender keeps the
// live scroll ORIGIN, because the canvas keeps roughly the same shape. Turning
// the paper re-flows the whole document onto a different number of differently
// shaped pages, so an absolute Y offset points at unrelated content afterwards.
// The top of the viewport is therefore remembered as an attributed LOCATION and
// the install lands on whichever page now holds it (see
// -installRenderedDocument:paginationPlan:interactiveString:preserveCurrentState:).
- (void)applyPageOrientation:(SPDFMarkdownPageOrientation)orientation {
    if (orientation == _pageOrientation) return;
    SPDFMarkdownPageConfiguration* paper = SPDFMarkdownPageConfigurationByOrienting(self.currentPageConfiguration, orientation);
    if (NSWidth(paper.printableRect) < 72 || NSHeight(paper.printableRect) < 72) {
        if (self.statusHandler) self.statusHandler(@"The paper margins do not fit this orientation.");
        return;
    }
    _pageOrientation = orientation;
    if (!_active || !self.document) return;
    _pendingReanchorLocation = self.visibleAttributedLocation;
    [self rerenderDocumentWithStatus:orientation == SPDFMarkdownPageOrientationLandscape
                                         ? @"Text pages are now landscape."
                                         : @"Text pages are now portrait."];
}

@end

@implementation SPDFMacMarkdownSession (PaperConfiguration)
- (SPDFMarkdownPageConfiguration*)currentPageConfiguration {
    SPDFMarkdownPageConfiguration* authored = self.document.authoredPageConfiguration;
    return authored ? SPDFMarkdownPageConfigurationByOrienting(authored, _pageOrientation)
        : [SPDFMarkdownPageConfiguration A4ConfigurationForOrientation:_pageOrientation];
}
@end

SPDFMarkdownDocument* SPDFMacMarkdownLoadDocument(NSURL* URL, SPDFMarkdownRenderOptions* options,
    SPDFMarkdownPageOrientation orientation, NSDictionary* previousFrontMatter,
    SPDFMarkdownPageConfiguration** configuration, NSError** error) {
    NSString* sourceRevision=SPDFSearchFileStamp(URL.path);
    SPDFMarkdownDocumentModel* model = [[SPDFMarkdownParser new] loadURL:URL error:error];
    if (model && [sourceRevision isEqual:SPDFSearchFileStamp(URL.path)])
        SPDFMacMarkdownSetSourceRevision(model,sourceRevision);
    if (!model) return nil;
    SPDFMarkdownPageConfiguration* fallback = [SPDFMarkdownPageConfiguration A4ConfigurationForOrientation:orientation];
    SPDFMarkdownPageConfiguration* paper = SPDFMarkdownPageConfigurationForFrontMatter(model.frontMatter, fallback, error);
    if (!paper) return nil;
    // A reload preserves the reader's rotation unless the source orientation
    // changed. An explicit source edit takes effect immediately on reload.
    if (previousFrontMatter && [previousFrontMatter[@"paper-orientation"] ?: @""
            isEqual:model.frontMatter[@"paper-orientation"] ?: @""])
        paper = SPDFMarkdownPageConfigurationByOrienting(paper, orientation);
    // Extremely asymmetric author margins may fit only one orientation.
    if (NSWidth(paper.printableRect) < 72 || NSHeight(paper.printableRect) < 72) {
        if (error) *error = [NSError errorWithDomain:SPDFMarkdownErrorDomain code:SPDFMarkdownErrorParseFailed
            userInfo:@{NSLocalizedDescriptionKey:@"The paper margins do not fit this orientation."}];
        return nil;
    }
    SPDFMarkdownRenderOptions* fitted = options;
    if (!NSEqualSizes(options.pageContentSize, paper.printableRect.size)) {
        fitted = [options copy];
        fitted.pageContentSize = paper.printableRect.size;
    }
    if (configuration) *configuration = paper;
    return [[SPDFMarkdownDocument alloc] initWithModel:model options:fitted];
}
