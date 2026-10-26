#import "SPDFMacViewportRenderPriority.h"
#import "SPDFMacTabHoverPreviewIntegration.h"

@interface ShenzhenMacDelegate (SPDFMacViewportRenderPriorityAccess)
- (void)enqueuePageRendersForGeneration:(NSUInteger)generation
                            pageIndexes:(NSArray<NSNumber*>*)pageIndexes
                          preferredPage:(NSInteger)preferredPage
                      forceHighPriority:(BOOL)forceHighPriority;
- (void)updateControls;
- (void)selectCurrentSidebarRow;
- (BOOL)isMarkdownActive;
@end

@implementation ShenzhenMacDelegate (SPDFMacViewportRenderPriority)

- (NSArray<NSNumber*>*)visibleDocumentPageIndexesWithExtraRadius:(NSInteger)radius
                                                   preferredPage:(NSInteger*)preferredPageOut {
    NSInteger preferredPage = -1;
    if (!_pageScrollView || !_pageView || _renderedPages.count == 0) {
        if (preferredPageOut) *preferredPageOut = preferredPage;
        return @[];
    }

    NSRect visibleRect = _pageScrollView.contentView.bounds;
    preferredPage = [_pageView pageIndexForVisibleRect:visibleRect];
    preferredPage = MAX(0, MIN(preferredPage, (NSInteger)_renderedPages.count - 1));

    NSMutableOrderedSet<NSNumber*>* indexes = [NSMutableOrderedSet orderedSet];
    if (_presentationMode) {
        [indexes addObject:@(preferredPage)];
    } else {
        for (NSInteger i = 0; i < (NSInteger)_renderedPages.count; ++i) {
            NSRect pageRect = [_pageView rectForPageAtIndex:i];
            if (!NSIsEmptyRect(NSIntersectionRect(visibleRect, pageRect))) [indexes addObject:@(i)];
        }
        if (indexes.count == 0) [indexes addObject:@(preferredPage)];
    }

    if (radius > 0) {
        NSArray<NSNumber*>* visible = indexes.array;
        for (NSNumber* number in visible) {
            NSInteger center = number.integerValue;
            NSInteger first = MAX(0, center - radius);
            NSInteger last = MIN((NSInteger)_renderedPages.count - 1, center + radius);
            for (NSInteger i = first; i <= last; ++i) [indexes addObject:@(i)];
        }
    }

    if (preferredPageOut) *preferredPageOut = preferredPage;
    return indexes.array;
}

- (void)queueVisibleDocumentPageRendersForCurrentViewportForceHighPriority:(BOOL)forceHighPriority {
    if (!_doc || !_path.length || _renderedPages.count == 0) return;
    NSInteger preferredPage = -1;
    NSArray<NSNumber*>* pageIndexes = [self visibleDocumentPageIndexesWithExtraRadius:1 preferredPage:&preferredPage];
    if (pageIndexes.count == 0) return;
    [self enqueuePageRendersForGeneration:_renderGeneration
                              pageIndexes:pageIndexes
                            preferredPage:preferredPage
                        forceHighPriority:forceHighPriority];
}

- (void)syncCurrentPageFromVisibleViewportQueueRenders:(BOOL)queueRenders forceHighPriority:(BOOL)forceHighPriority {
    if (!_pageScrollView || !_pageView || _renderedPages.count == 0) return;
    NSInteger visiblePage = [_pageView pageIndexForVisibleRect:_pageScrollView.contentView.bounds];
    visiblePage = MAX(0, MIN(visiblePage, (NSInteger)_renderedPages.count - 1));
    if (visiblePage != _pageIndex) {
        _pageIndex = visiblePage;
        _pageView.currentPageIndex = _pageIndex;
        [self clearPageFieldFocus];
        [self updateControls];
        [self selectCurrentSidebarRow];
    }
    if (queueRenders) [self queueVisibleDocumentPageRendersForCurrentViewportForceHighPriority:forceHighPriority];
}

- (void)spdf_queueViewportPageRendersNow {
    if (!_doc || !_path.length || _renderedPages.count == 0 || _liveZooming || [self isMarkdownActive]) return;
    NSInteger preferredPage = -1;
    NSArray<NSNumber*>* visible = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferredPage];
    if (visible.count == 0) return;
    // The page the viewport is centred on claims the first free render slot.
    NSMutableArray<NSNumber*>* viewport = [NSMutableArray arrayWithCapacity:visible.count];
    if ([visible containsObject:@(preferredPage)]) [viewport addObject:@(preferredPage)];
    for (NSNumber* number in visible)
        if (number.integerValue != preferredPage) [viewport addObject:number];

    NSArray<NSOperation*>* waitingOnBackground = _backgroundRenderQueue.operations;
    for (NSNumber* number in _queuedRenderOperations.allKeys) {
        NSOperation* waiting = _queuedRenderOperations[number];
        if (waiting.isExecuting) continue; // one that started finishes where it is
        BOOL onBackground = [waitingOnBackground containsObject:waiting];
        if ([viewport containsObject:number]) {
            // An operation cannot change queues, and the enqueue below would only
            // raise the priority of one waiting on the one-wide background queue,
            // still behind whatever that queue is running. Withdraw it so it is
            // re-enqueued on the render queue.
            if (!onBackground) continue;
            [waiting cancel];
            [_queuedRenderOperations removeObjectForKey:number];
            [_queuedRenderPages removeObject:number];
        } else if (!onBackground && waiting.queuePriority > NSOperationQueuePriorityNormal) {
            // Still waiting for a render slot on behalf of an earlier viewport:
            // paging with key repeat leaves one per press. It still runs, after
            // this viewport rather than ahead of it.
            waiting.queuePriority = NSOperationQueuePriorityNormal;
        }
    }
    [self enqueuePageRendersForGeneration:_renderGeneration
                              pageIndexes:viewport
                            preferredPage:preferredPage
                        forceHighPriority:YES];
    // The page the tab shows now: its hover thumbnail follows once it settles.
    [self spdf_noteTabHoverPreviewSourcesChanged];
}

- (void)spdf_forgetQueuedRenderOperation:(NSOperation*)operation page:(NSNumber*)page {
    NSOperation* queued = _queuedRenderOperations[page];
    if (queued && queued != operation) return; // a replacement owns the entry now
    [_queuedRenderOperations removeObjectForKey:page];
    [_queuedRenderPages removeObject:page];
}

@end
