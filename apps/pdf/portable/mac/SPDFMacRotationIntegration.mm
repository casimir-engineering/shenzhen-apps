#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacImageRotationIntegration.h"
#import "SPDFMacCollectionIntegration.h"
@interface ShenzhenMacDelegate (RotationPrivate)
- (BOOL)ensureActivePDFCanBeModifiedForOperation:(NSString*)operation;
- (NSInteger)currentPageIndexFromCounterForMutation;
- (void)cancelDocumentTransientInteraction;
- (void)clearPageFieldFocus;
- (void)cancelCacheRenderOperations;
- (void)showError:(NSString*)message detail:(NSString*)detail;
@end
@implementation ShenzhenMacDelegate (Rotation)
- (void)rotateCurrentPageByDegrees:(int)degrees {
    if ([self rotateActiveImageByDegrees:degrees]) return;
    if (!_doc || !_path.length || ![_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        if (![self rotateMarkdownPaperByDegrees:degrees]) NSBeep();
        return;
    }
    if (![self ensureActivePDFCanBeModifiedForOperation:@"rotating the page"]) return;

    [self cancelDocumentTransientInteraction];
    NSInteger pageIndex = [self currentPageIndexFromCounterForMutation];
    _pageIndex = pageIndex;
    _pageView.currentPageIndex = pageIndex;
    [self clearPageFieldFocus];
    char err[1024];
    BOOL ok = spdf_rotate_page(_doc, (int)pageIndex, degrees, err, sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self discardCachedRuntimeForTab:[self selectedTab]];
        [self loadSelectedTab];
        [self showError:@"Could not rotate page" detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }

    [_renderQueue cancelAllOperations];
    [self cancelCacheRenderOperations];
    [_minimapQueue cancelAllOperations];
    [_queuedRenderPages removeAllObjects];
    [_queuedRenderOperations removeAllObjects];
    [_queuedMinimapThumbnailPages removeAllObjects];
    _renderGeneration++;
    if (_selectedTabIndex >= 0 && _selectedTabIndex < (NSInteger)_tabs.count) {
        SPDFDocumentTab* tab = _tabs[(NSUInteger)_selectedTabIndex];
        tab.pageIndex = pageIndex;
        tab.scrollOrigin = NSZeroPoint;
        tab.hasScrollOrigin = NO;
        [self discardCachedRuntimeForTab:tab];
    }
    _pageIndex = pageIndex;
    [self loadSelectedTab];
    _statusLabel.stringValue = degrees > 0 ? @"Page rotated clockwise." : @"Page rotated anticlockwise.";
}

- (void)rotateClockwise:(id)sender {
    (void)sender;
    [self rotateCurrentPageByDegrees:90];
}

- (void)rotateAnticlockwise:(id)sender {
    (void)sender;
    [self rotateCurrentPageByDegrees:-90];
}

@end
