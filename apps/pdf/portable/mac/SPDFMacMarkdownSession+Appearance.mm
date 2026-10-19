#import "SPDFMacMarkdownSessionPrivate.h"

// The APPEARANCE half of the session: the reader's font scale, reading theme
// and "keep image colors" answer, and the render options they produce.
//
// Font scale and theme change what is RENDERED, so an active session rerenders
// in place; "keep image colors" only changes how the already-rendered pages are
// DRAWN, so it retargets the live plan and repaints instead. The paper
// orientation is the third rerendering kind and lives next door in
// SPDFMacMarkdownSession+Paper.mm; -renderTrailsPreferences below answers for
// all three.

@implementation SPDFMacMarkdownSession (Appearance)

CGFloat SPDFMacMarkdownClampFontScale(CGFloat scale) {
    return MAX((CGFloat)0.5, MIN((CGFloat)3.0, scale));
}

- (SPDFMarkdownRenderOptions*)renderOptionsForThemeVariant:(SPDFMarkdownThemeVariant)variant {
    SPDFMarkdownRenderOptions* options = [SPDFMarkdownRenderOptions defaultOptionsForThemeVariant:variant];
    options.fontScale = _fontScale;
    // The paper the pagination pass is about to use, so figures (diagrams) are
    // sized against the page they will actually land on. This is why turning the
    // paper is a RERENDER and not only a re-paginate.
    options.pageContentSize = self.currentPageConfiguration.printableRect.size;
    options.diagramCache = _diagramCache;  // one diagram-layout cache for the session
    [self applyRemoteImageState:options];  // already-fetched remote image bytes
    return options;
}

- (SPDFMarkdownRenderOptions*)renderOptionsForCurrentScale {
    return [self renderOptionsForThemeVariant:_themeVariant];
}

// The installed render trails the session preferences: a catch-up rerender is
// due (used by activation and the self-heal pass).
- (BOOL)renderTrailsPreferences {
    return _renderedFontScale != _fontScale || _renderedThemeVariant != _themeVariant ||
           _renderedOrientation != _pageOrientation;
}

@end
