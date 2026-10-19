#import "SPDFMacMarkdownSessionPrivate.h"

// The EXPORT half of the session: Save as PDF, Print, Copy Page and Copy Page
// Image always produce the LIGHT rendition, whatever the reader is showing —
// the same rule the PDF side already follows, because an exported file leaves
// the app and dark paper baked into it would be wrong everywhere it lands.
//
// While the session is LIGHT the export accessors return the live plan and
// string themselves: the identical objects, so the common path pays nothing
// at all. Only a DARK session ever builds anything here, and then once, on the
// first export, cached on the identity of the installed renderedDocument (any
// rerender installs a new one, which invalidates the cache for free).

@implementation SPDFMacMarkdownSession (Export)

NSSize SPDFMacMarkdownPageContentSize(SPDFMarkdownPageOrientation orientation) {
    return [SPDFMarkdownPageConfiguration A4ConfigurationForOrientation:orientation].printableRect.size;
}

// Paginates a rendition exactly the way the live screen pass does, so an
// export plan and the on-screen plan differ in palette and nothing else.
SPDFMarkdownPaginationPlan* SPDFMacMarkdownPlanForRendition(SPDFMarkdownRenderedDocument* rendered,
                                                            SPDFMarkdownThemeVariant variant,
                                                            BOOL preservesImageColors,
                                                            SPDFMarkdownPageOrientation orientation) {
    return SPDFMacMarkdownPlanForConfiguration(rendered, variant, preservesImageColors,
        [SPDFMarkdownPageConfiguration A4ConfigurationForOrientation:orientation]);
}

SPDFMarkdownPaginationPlan* SPDFMacMarkdownPlanForConfiguration(SPDFMarkdownRenderedDocument* rendered,
    SPDFMarkdownThemeVariant variant, BOOL preservesImageColors, SPDFMarkdownPageConfiguration* paper) {
    SPDFMarkdownPaginator* paginator = [SPDFMarkdownPaginator new];
    SPDFMarkdownPageConfiguration* configuration = [paper copy];
    configuration.includesCodeLanguageControlSpacing = YES;
    configuration.themeVariant = variant;
    configuration.preservesImageColors = preservesImageColors;
    NSArray* items = [paginator measureRenderedDocument:rendered
                                         containerWidth:NSWidth(configuration.printableRect)];
    return [paginator paginateItems:items configuration:configuration];
}

// Builds (once) and caches the light export rendition. Never reached while the
// session is light: -exportPaginationPlan returns the live plan before this.
- (void)ensureLightExportRendition {
    SPDFMarkdownRenderedDocument* source = self.renderedDocument;
    if (!source || !self.document) return;
    // Orientation is independent of theme, so the cached light rendition is
    // only reusable while its paper still matches the session's.
    if (_exportPlan && _exportRenditionSource == source &&
        _exportPlan.configuration.orientation == _pageOrientation)
        return;
    SPDFMarkdownRenderOptions* options = [self renderOptionsForThemeVariant:SPDFMarkdownThemeVariantLight];
    SPDFMarkdownRenderedDocument* rendered =
        [self.document renderedDocumentWithOptions:options languageOverrides:[_languageOverrides copy]];
    if (!rendered) return;
    // Light never recolors, so the flag is immaterial here; stated, not inferred.
    _exportPlan = SPDFMacMarkdownPlanForConfiguration(rendered, SPDFMarkdownThemeVariantLight, YES, self.currentPageConfiguration);
    _exportAttributedString = rendered.attributedString;
    _exportRenditionSource = source;
}

- (SPDFMarkdownPaginationPlan*)exportPaginationPlan {
    if (self.themeVariant == SPDFMarkdownThemeVariantLight) return _paginationPlan;
    [self ensureLightExportRendition];
    return _exportPlan ?: _paginationPlan;
}

- (NSAttributedString*)exportAttributedString {
    if (self.themeVariant == SPDFMarkdownThemeVariantLight) return self.renderedDocument.attributedString;
    [self ensureLightExportRendition];
    return _exportAttributedString ?: self.renderedDocument.attributedString;
}

@end
