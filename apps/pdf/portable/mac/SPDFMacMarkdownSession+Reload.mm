#import "SPDFMacMarkdownSessionPrivate.h"

#import "SPDFMacMarkdownView.h"

// Re-reading the document after its file changed on disk.
//
// The obvious implementation -- drop the session and run the delegate's normal
// load path again -- is what auto-reload originally did, and it blanks the
// window: the session is torn down, the placeholder is shown, a new session is
// built, and the document reappears. On a file being edited and saved
// repeatedly that reads as the whole screen flashing.
//
// So a reload is really a RERENDER whose source happens to be the file rather
// than the model already in memory. It follows
// -rerenderDocumentWithStatus: exactly (theme, font scale and paper
// orientation all take that path): render off the main thread, then install
// with preserveCurrentState:YES so the existing view keeps drawing the last
// good content until the new pages are ready to swap in underneath the
// reader's viewport.

@implementation SPDFMacMarkdownSession (Reload)

- (void)reloadFromDiskWithStatus:(NSString*)status {
    if (!_active || !self.documentURL) return;
    [_renderToken cancel];
    _renderToken = nil;
    _renderGeneration++;
    _reloadInFlight = YES;
    NSUInteger renderGeneration = _renderGeneration;
    NSURL* URL = self.documentURL;
    SPDFMarkdownRenderOptions* renderOptions = [self renderOptionsForCurrentScale];
    SPDFMarkdownPageOrientation orientation = _pageOrientation;
    NSDictionary* previousFrontMatter = self.document.model.frontMatter;
    CGFloat fontScale = _fontScale;
    SPDFMarkdownThemeVariant themeVariant = _themeVariant;
    BOOL preservesImageColors = _preservesImageColors;
    dispatch_queue_t workQueue = _workQueue ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak SPDFMacMarkdownSession* weakSelf = self;
    dispatch_async(workQueue, ^{
      NSError* error = nil;
      SPDFMarkdownPageConfiguration* paper = nil;
      SPDFMarkdownDocument* document = SPDFMacMarkdownLoadDocument(URL, renderOptions, orientation,
          previousFrontMatter, &paper, &error);
      // A failed read (deleted, or caught mid-write by an editor that truncates
      // before writing) keeps the last good render on screen. The watcher's
      // missing-file handling owns a document that is really gone.
      SPDFMarkdownPaginationPlan* plan = document ?
          SPDFMacMarkdownPlanForConfiguration(document.renderedDocument, themeVariant, preservesImageColors, paper) : nil;
      NSAttributedString* interactive = document ? SPDFMacMarkdownInteractiveString(document.model, document.renderedDocument) : nil;
      dispatch_async(dispatch_get_main_queue(), ^{
        SPDFMacMarkdownSession* mainSelf = weakSelf;
        if (!mainSelf || !mainSelf->_active || renderGeneration != mainSelf->_renderGeneration) return;
        mainSelf->_reloadInFlight = NO;
        if (!document || !plan || !interactive) return;
        mainSelf->_renderToken = nil;
        mainSelf.document = document;
        mainSelf.renderedDocument = document.renderedDocument;
        mainSelf->_paginationPlan = plan;
        mainSelf->_interactiveString = interactive;
        mainSelf->_renderedFontScale = fontScale;
        mainSelf->_renderedThemeVariant = themeVariant;
        mainSelf->_renderedOrientation = paper.orientation;
        if (mainSelf->_pageOrientation == orientation) mainSelf->_pageOrientation = paper.orientation;
        [mainSelf installRenderedDocument:document.renderedDocument
                           paginationPlan:plan
                        interactiveString:interactive
                     preserveCurrentState:YES];
        // The text changed under the query, so match ranges would be stale.
        // reveal:NO keeps the preserved viewport instead of scrolling to a hit.
        if (mainSelf->_activeSearchQuery.length)
            [mainSelf searchForQuery:mainSelf->_activeSearchQuery
                               regex:mainSelf->_activeSearchRegex
                      preferredIndex:mainSelf->_currentMatchIndex
                       jumpToNearest:NO
                              reveal:NO];
        if (status.length && mainSelf.statusHandler) mainSelf.statusHandler(status);
      });
    });
}

@end
