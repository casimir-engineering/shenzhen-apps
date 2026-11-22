// The outline and comments of the active PDF, read after its first paint (moved out of ShenzhenPDFMac.mm).
//
// They used to load with one document open each on the preload queue, one after the other, at the moment people start
// scrolling. Both now come from a single open: on a 1691-page manual that is ~41 ms less CPU after the first frame,
// and 1-6 ms on typical files. A list the tab already holds (cached, or adopted from the launch prerender) is not read
// again.
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacDocumentMetadataReader)
- (NSString*)activeWorkingPath;
- (spdf_document*)openSpdfDocumentAtPath:(NSString*)path
                              sourcePath:(NSString*)sourcePath
                                  status:(spdf_open_status*)status
                                   error:(char*)err
                             errorLength:(size_t)errLen;
- (void)rebuildSidebar;
@end

@implementation ShenzhenMacDelegate (SPDFMacDocumentMetadataLoading)

- (void)loadCommentsForCurrentDocumentAsync {
    [self loadDocumentMetadataAsyncOutline:NO comments:YES];
}

- (void)loadOutlineForCurrentDocumentAsync {
    [self loadDocumentMetadataAsyncOutline:YES comments:NO];
}

- (void)loadDocumentMetadataAsyncOutline:(BOOL)wantOutline comments:(BOOL)wantComments {
    if (!_doc || !_path.length) return;
    SPDFDocumentTab* tab = [self selectedTab];
    BOOL needOutline = wantOutline && !tab.cachedOutlineLoaded;
    BOOL needComments = wantComments && !tab.cachedCommentsLoaded;
    if ((wantOutline && !needOutline) || (wantComments && !needComments)) {
        [self adoptCachedMetadataForTab:tab];
        [self rebuildSidebar];
        if (wantComments && !needComments) [_pageView setNeedsDisplay:YES];
    }
    if (!needOutline && !needComments) return;

    NSString* workingPath = [self activeWorkingPath]; // temp copy for read-only source
    NSString* standardizedPath = [_path.stringByStandardizingPath copy];
    NSUInteger generation = _renderGeneration;
    [_preloadQueue addOperationWithBlock:^{
      @autoreleasepool {
          __block spdf_outline outline;
          __block spdf_comments comments;
          memset(&outline, 0, sizeof(outline));
          memset(&comments, 0, sizeof(comments));
          char err[1024];
          spdf_document* doc = [self openSpdfDocumentAtPath:workingPath
                                                 sourcePath:standardizedPath
                                                     status:NULL
                                                      error:err
                                                errorLength:sizeof(err)];
          BOOL outlineOK = needOutline && doc && spdf_load_outline(doc, &outline, err, sizeof(err));
          BOOL commentsOK = needComments && doc && spdf_load_comments(doc, &comments, err, sizeof(err));
          if (doc) spdf_close(doc);

          [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            SPDFDocumentTab* currentTab = [self selectedTab];
            if (generation != self->_renderGeneration || !self->_doc ||
                ![self->_path.stringByStandardizingPath isEqualToString:standardizedPath] || currentTab != tab) {
                spdf_free_outline(&outline);
                spdf_free_comments(&comments);
                return;
            }
            if (needOutline) {
                if (!outlineOK) {
                    spdf_free_outline(&outline);
                    memset(&outline, 0, sizeof(outline));
                }
                [tab replaceCachedOutline:outline loaded:YES];
            }
            if (needComments) {
                if (!commentsOK) {
                    spdf_free_comments(&comments);
                    memset(&comments, 0, sizeof(comments));
                }
                [tab replaceCachedComments:comments loaded:YES];
            }
            [self adoptCachedMetadataForTab:tab];
            [self rebuildSidebar];
            if (needComments) [self->_pageView setNeedsDisplay:YES];
          }];
      }
    }];
}

@end
