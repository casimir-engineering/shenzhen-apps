#import "SPDFMacLaunchWorkIntegration.h"

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacSupport.h"
#import "SPDFMacViewportRenderPriority.h"

@interface ShenzhenMacDelegate (SPDFMacLaunchWorkIntegrationPrivate)
@property(nonatomic, readonly) SPDFMacLaunchWorkCoordinator* launchWorkCoordinator;
- (void)loadOutlineForCurrentDocumentAsync;
- (void)loadCommentsForCurrentDocumentAsync;
- (void)preloadInactiveTabsWithCompletion:(dispatch_block_t)completion;
@end

@implementation ShenzhenMacDelegate (SPDFMacLaunchWorkIntegration)

- (void)spdf_scheduleIdleNearbyPageRendersForGeneration:(NSUInteger)generation preferredPage:(NSInteger)preferredPage {
    NSString* path = [_path copy];
    if (!path.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_pageScrollView displayIfNeeded];
      // Painted: the rest of the viewport renders now, before any warm stage.
      if (generation == self->_renderGeneration) [self spdf_queueViewportPageRendersNow];
      [self.launchWorkCoordinator beginCycleAtStage:SPDFMacLaunchWarmStageActiveDocument
                                            context:@{
                                                @"generation" : @(generation),
                                                @"path" : path,
                                                @"savedFind" : @(-1),
                                                @"search" : @"",
                                                @"restoreSearch" : @NO,
                                                @"page" : @(preferredPage)
                                            }];
    });
}

- (void)spdf_scheduleIdlePostFirstPaintWorkForGeneration:(NSUInteger)generation
                                                    path:(NSString*)path
                                     savedFindMatchIndex:(NSInteger)savedFindMatchIndex
                                           restoreSearch:(BOOL)restoreSearch
                                     preferredRenderPage:(NSInteger)preferredRenderPage {
    if (!path.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_pageScrollView displayIfNeeded];
      if (generation == self->_renderGeneration && [self->_path isEqualToString:path])
          [self spdf_queueViewportPageRendersNow];
      [self.launchWorkCoordinator beginCycleAtStage:SPDFMacLaunchWarmStageMetadata
                                            context:@{
                                                @"generation" : @(generation),
                                                @"path" : path,
                                                @"savedFind" : @(savedFindMatchIndex),
                                                @"search" : [_searchField.stringValue copy] ?: @"",
                                                @"restoreSearch" : @(restoreSearch),
                                                @"page" : @(preferredRenderPage)
                                            }];
    });
}

- (void)runLaunchWarmStage:(SPDFMacLaunchWarmStage)stage
                generation:(NSUInteger)generation
                   context:(NSDictionary*)context {
    NSString* path = context[@"path"];
    if (!path.length || ![_path isEqualToString:path]) {
        [self.launchWorkCoordinator completeCycleForGeneration:generation];
        return;
    }
    spdf_launch_profile_log(@"idle warm stage=%ld generation=%lu", (long)stage, (unsigned long)generation);
    if (stage == SPDFMacLaunchWarmStageMetadata) {
        // An open that loaded the outline and comments before its first frame (at
        // launch, or while the window is not on screen yet) adopted them before its
        // own sidebar rebuild, so the sidebar and the comment overlay already show
        // them. Loading them again here only re-adopted the same lists and rebuilt
        // the sidebar twice more: 2 x ~20-27 ms on the main thread ~100 ms after
        // the open, on a 5-page schematic. A list not yet loaded -- a mid-session
        // open loads them in the background -- loads as before and rebuilds the
        // sidebar when it lands.
        SPDFDocumentTab* tab = [self selectedTab];
        BOOL adopted = tab && _activeMetadataTab == tab;
        if (!adopted || !tab.cachedOutlineLoaded || _outline.items != tab.cachedOutline.items ||
            _outline.count != tab.cachedOutline.count)
            [self loadOutlineForCurrentDocumentAsync];
        if (!adopted || !tab.cachedCommentsLoaded || _comments.items != tab.cachedComments.items ||
            _comments.count != tab.cachedComments.count)
            [self loadCommentsForCurrentDocumentAsync];
        return;
    }
    if ([context[@"generation"] unsignedIntegerValue] != _renderGeneration) {
        [self.launchWorkCoordinator completeCycleForGeneration:generation];
        return;
    }
    NSInteger preferredPage = [context[@"page"] integerValue];
    if (stage == SPDFMacLaunchWarmStageActiveDocument) {
        [self enqueueZoomSeedCachesForGeneration:_renderGeneration preferredPage:preferredPage includeWholeBase:YES];
        [self enqueueNearbyPageRendersForGeneration:_renderGeneration preferredPage:preferredPage];
        NSString* capturedSearch = context[@"search"];
        if ([context[@"restoreSearch"] boolValue] && capturedSearch.length > 0 &&
            [_searchField.stringValue isEqualToString:capturedSearch]) {
            _pendingFindPreferredMatchIndex = [context[@"savedFind"] integerValue];
            _pendingFindPreferredPage = -1;
            [self startFindForCurrentQueryResetSavedIndex:NO revealMatch:NO];
        }
        return;
    }
    if (stage == SPDFMacLaunchWarmStageInactiveTabs) {
        if (!spdf_mac_launch_can_start_inactive_work(_renderQueue.operationCount, _preloadQueue.operationCount,
                                                     _minimapQueue.operationCount, _zoomSeedRenderQueue.operationCount,
                                                     _cacheRenderQueue.operationCount,
                                                     _backgroundRenderQueue.operationCount)) {
            [self.launchWorkCoordinator beginCycleAtStage:SPDFMacLaunchWarmStageInactiveTabs context:context];
            return;
        }
        [self preloadInactiveTabsWithCompletion:^{
          [self.launchWorkCoordinator completeCycleForGeneration:generation];
        }];
    }
}

@end
