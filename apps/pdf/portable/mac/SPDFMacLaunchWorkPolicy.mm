#import "SPDFMacLaunchWorkPolicy.h"

@interface SPDFMacLaunchWorkPolicy ()
@property(nonatomic) BOOL active;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) SPDFMacLaunchWarmStage nextStage;
@property(nonatomic) NSTimeInterval readyAt;
@property(nonatomic) NSTimeInterval visibleStartDelay;
@property(nonatomic) NSTimeInterval inactiveIdleDelay;
@property(nonatomic) NSTimeInterval stageDelay;
@property(nonatomic) BOOL inactiveWorkRunning;
@property(nonatomic, strong) NSMutableArray* activationHistory;
@end

@implementation SPDFMacLaunchWorkPolicy

- (instancetype)initWithVisibleStartDelay:(NSTimeInterval)visibleStartDelay
                        inactiveIdleDelay:(NSTimeInterval)inactiveIdleDelay
                               stageDelay:(NSTimeInterval)stageDelay {
    self = [super init];
    if (self) {
        _visibleStartDelay = MAX(0.0, visibleStartDelay);
        _inactiveIdleDelay = MAX(0.0, inactiveIdleDelay);
        _stageDelay = MAX(0.0, stageDelay);
        _activationHistory = [NSMutableArray array];
    }
    return self;
}

- (NSUInteger)beginCycleAtStage:(SPDFMacLaunchWarmStage)stage atTime:(NSTimeInterval)now {
    _generation++;
    _active = stage != SPDFMacLaunchWarmStageNone;
    _nextStage = stage;
    _inactiveWorkRunning = NO;
    _readyAt = now + (stage == SPDFMacLaunchWarmStageInactiveTabs ? _inactiveIdleDelay : _visibleStartDelay);
    return _generation;
}

- (BOOL)noteUserInputAtTime:(NSTimeInterval)now {
    if (!_active) return NO;
    if (_nextStage != SPDFMacLaunchWarmStageInactiveTabs && !_inactiveWorkRunning) return NO;
    _generation++;
    _nextStage = SPDFMacLaunchWarmStageInactiveTabs;
    _inactiveWorkRunning = NO;
    _readyAt = now + _inactiveIdleDelay;
    return YES;
}

- (NSTimeInterval)delayUntilReadyAtTime:(NSTimeInterval)now {
    if (!_active || _nextStage == SPDFMacLaunchWarmStageNone) return -1.0;
    return MAX(0.0, _readyAt - now);
}

- (SPDFMacLaunchWarmStage)takeReadyStageAtTime:(NSTimeInterval)now expectedGeneration:(NSUInteger)generation {
    if (!_active || generation != _generation || _nextStage == SPDFMacLaunchWarmStageNone || now < _readyAt)
        return SPDFMacLaunchWarmStageNone;
    SPDFMacLaunchWarmStage result = _nextStage;
    if (result == SPDFMacLaunchWarmStageInactiveTabs) {
        _nextStage = SPDFMacLaunchWarmStageNone;
        _inactiveWorkRunning = YES;
    } else if (result == SPDFMacLaunchWarmStageActiveDocument) {
        _nextStage = SPDFMacLaunchWarmStageInactiveTabs;
        _readyAt = now + _inactiveIdleDelay;
    } else {
        _nextStage = SPDFMacLaunchWarmStageActiveDocument;
        _readyAt = now + _stageDelay;
    }
    return result;
}

- (void)completeCycleForGeneration:(NSUInteger)generation {
    if (generation != _generation) return;
    _generation++;
    _active = NO;
    _nextStage = SPDFMacLaunchWarmStageNone;
    _inactiveWorkRunning = NO;
}

- (void)recordActivationOfIdentifier:(id)identifier {
    if (!identifier) return;
    NSUInteger index = [_activationHistory indexOfObjectIdenticalTo:identifier];
    if (index != NSNotFound) [_activationHistory removeObjectAtIndex:index];
    [_activationHistory insertObject:identifier atIndex:0];
}

- (NSArray<NSNumber*>*)orderedInactiveIndexesForIdentifiers:(NSArray*)identifiers
                                              selectedIndex:(NSInteger)selectedIndex {
    if (selectedIndex < 0 || selectedIndex >= (NSInteger)identifiers.count) return @[];
    NSMutableArray<NSNumber*>* result = [NSMutableArray array];
    NSMutableIndexSet* added = [NSMutableIndexSet indexSetWithIndex:(NSUInteger)selectedIndex];
    void (^appendIndex)(NSInteger) = ^(NSInteger index) {
      if (index < 0 || index >= (NSInteger)identifiers.count || [added containsIndex:(NSUInteger)index]) return;
      [added addIndex:(NSUInteger)index];
      [result addObject:@(index)];
    };

    appendIndex(selectedIndex + 1);
    appendIndex(selectedIndex - 1);

    NSMutableArray* survivingHistory = [NSMutableArray array];
    for (id identifier in _activationHistory) {
        NSUInteger index = [identifiers indexOfObjectIdenticalTo:identifier];
        if (index == NSNotFound) continue;
        [survivingHistory addObject:identifier];
        appendIndex((NSInteger)index);
    }
    _activationHistory = survivingHistory;

    for (NSInteger distance = 2; result.count + 1 < identifiers.count; ++distance) {
        appendIndex(selectedIndex + distance);
        appendIndex(selectedIndex - distance);
    }
    return result;
}

@end

typedef NS_ENUM(NSInteger, SPDFMacLaunchPrerenderState) {
    SPDFMacLaunchPrerenderStatePreparing = 0,
    SPDFMacLaunchPrerenderStateOpening,
    SPDFMacLaunchPrerenderStateRendering,
    SPDFMacLaunchPrerenderStateFinished,
    SPDFMacLaunchPrerenderStateCancelled,
    SPDFMacLaunchPrerenderStateConsumed,
};

@interface SPDFMacLaunchPrerenderOwnership ()
@property(nonatomic) SPDFMacLaunchPrerenderState state;
@property(nonatomic, getter=isAbandoned) BOOL abandoned;
@property(nonatomic) BOOL foregroundClaimed;
@end

@implementation SPDFMacLaunchPrerenderOwnership

- (BOOL)isAbandoned {
    @synchronized(self) {
        return _abandoned;
    }
}

- (BOOL)workerMayBeginOpen {
    @synchronized(self) {
        if (_state != SPDFMacLaunchPrerenderStatePreparing || _abandoned) return NO;
        _state = SPDFMacLaunchPrerenderStateOpening;
        return YES;
    }
}

- (BOOL)workerMayBeginRender {
    @synchronized(self) {
        if (_state != SPDFMacLaunchPrerenderStateOpening || _foregroundClaimed || _abandoned) return NO;
        _state = SPDFMacLaunchPrerenderStateRendering;
        return YES;
    }
}

- (void)workerDidFinish {
    @synchronized(self) {
        if (_state == SPDFMacLaunchPrerenderStatePreparing || _state == SPDFMacLaunchPrerenderStateOpening ||
            _state == SPDFMacLaunchPrerenderStateRendering)
            _state = SPDFMacLaunchPrerenderStateFinished;
    }
}

- (SPDFMacLaunchPrerenderForegroundAction)claimForForeground {
    @synchronized(self) {
        if (_abandoned || _state == SPDFMacLaunchPrerenderStateCancelled ||
            _state == SPDFMacLaunchPrerenderStateConsumed)
            return SPDFMacLaunchPrerenderForegroundActionUnavailable;
        if (_state == SPDFMacLaunchPrerenderStatePreparing) {
            _state = SPDFMacLaunchPrerenderStateCancelled;
            return SPDFMacLaunchPrerenderForegroundActionOpenInForeground;
        }
        _foregroundClaimed = YES;
        // Opening: wait for the open; workerMayBeginRender then refuses, so the
        // wait never includes a speculative render that has not started.
        // Rendering: the render is already in flight. Abandoning it made the
        // foreground redo the same open and render synchronously -- measured as
        // a 120 ms duplicate of a render that was 2 ms from done, hit on every
        // launch once the pre-paint main thread got faster than the worker. The
        // wait is bounded by that render's remaining time, and the result is
        // validated on adoption (identity, zoom, scale, theme) like any other.
        if (_state == SPDFMacLaunchPrerenderStateOpening || _state == SPDFMacLaunchPrerenderStateRendering)
            return SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult;
        return SPDFMacLaunchPrerenderForegroundActionConsumeFinishedResult;
    }
}

- (void)markConsumed {
    @synchronized(self) {
        if (_state == SPDFMacLaunchPrerenderStateFinished) _state = SPDFMacLaunchPrerenderStateConsumed;
    }
}

- (void)abandon {
    @synchronized(self) {
        _abandoned = YES;
        if (_state == SPDFMacLaunchPrerenderStatePreparing) _state = SPDFMacLaunchPrerenderStateCancelled;
    }
}

@end

@interface SPDFMacLaunchWorkCoordinator ()
@property(nonatomic, strong) SPDFMacLaunchWorkPolicy* policy;
@property(nonatomic, copy) SPDFMacLaunchWarmStageHandler stageHandler;
@property(nonatomic, copy) dispatch_block_t interruptionHandler;
@property(nonatomic, strong) id context;
@property(nonatomic, strong) id eventMonitor;
@end

@implementation SPDFMacLaunchWorkCoordinator

- (instancetype)initWithVisibleStartDelay:(NSTimeInterval)visibleStartDelay
                        inactiveIdleDelay:(NSTimeInterval)inactiveIdleDelay
                               stageDelay:(NSTimeInterval)stageDelay {
    self = [super init];
    if (self) {
        _policy = [[SPDFMacLaunchWorkPolicy alloc] initWithVisibleStartDelay:visibleStartDelay
                                                           inactiveIdleDelay:inactiveIdleDelay
                                                                  stageDelay:stageDelay];
    }
    return self;
}

- (NSTimeInterval)now {
    return NSProcessInfo.processInfo.systemUptime;
}

- (void)activateWithStageHandler:(SPDFMacLaunchWarmStageHandler)stageHandler
             interruptionHandler:(dispatch_block_t)interruptionHandler {
    _stageHandler = [stageHandler copy];
    _interruptionHandler = [interruptionHandler copy];
    if (_eventMonitor) return;
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                       NSEventMaskOtherMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
                       NSEventMaskOtherMouseDragged | NSEventMaskScrollWheel | NSEventMaskMagnify | NSEventMaskSwipe |
                       NSEventMaskRotate | NSEventMaskGesture;
    __weak __typeof(self) weakSelf = self;
    _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                                          handler:^NSEvent*(NSEvent* event) {
                                                            __strong __typeof(weakSelf) self = weakSelf;
                                                            if (!self || ![self.policy noteUserInputAtTime:self.now])
                                                                return event;
                                                            if (self.interruptionHandler) self.interruptionHandler();
                                                            [self armNextStage];
                                                            return event;
                                                          }];
}

- (void)beginCycleAtStage:(SPDFMacLaunchWarmStage)stage context:(id)context {
    _context = context;
    [_policy beginCycleAtStage:stage atTime:self.now];
    [self armNextStage];
}

- (void)armNextStage {
    NSUInteger generation = _policy.generation;
    NSTimeInterval delay = [_policy delayUntilReadyAtTime:self.now];
    if (delay < 0.0) return;
    __weak __typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong __typeof(weakSelf) self = weakSelf;
      if (!self) return;
      SPDFMacLaunchWarmStage stage = [self.policy takeReadyStageAtTime:self.now expectedGeneration:generation];
      if (stage == SPDFMacLaunchWarmStageNone) return;
      if (self.stageHandler) self.stageHandler(stage, generation, self.context);
      [self armNextStage];
    });
}

- (void)completeCycleForGeneration:(NSUInteger)generation {
    [_policy completeCycleForGeneration:generation];
    if (!_policy.active) _context = nil;
}

- (void)recordActivationOfIdentifier:(id)identifier {
    [_policy recordActivationOfIdentifier:identifier];
}

- (NSArray<NSNumber*>*)orderedInactiveIndexesForIdentifiers:(NSArray*)identifiers
                                              selectedIndex:(NSInteger)selectedIndex {
    return [_policy orderedInactiveIndexesForIdentifiers:identifiers selectedIndex:selectedIndex];
}

- (void)stop {
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
    _eventMonitor = nil;
    _stageHandler = nil;
    _interruptionHandler = nil;
    _context = nil;
}

- (void)dealloc {
    [self stop];
}

@end

NSString* spdf_mac_normalized_launch_path(NSString* path) {
    if (path.length == 0) return nil;
    NSString* absolute = path.stringByExpandingTildeInPath;
    if (!absolute.isAbsolutePath)
        absolute = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:absolute];
    return absolute.stringByStandardizingPath;
}

BOOL spdf_mac_launch_file_identity_matches(NSString* firstPath, unsigned long long firstSize,
                                           NSDate* firstModificationDate, NSString* secondPath,
                                           unsigned long long secondSize, NSDate* secondModificationDate) {
    NSString* firstNormalized = spdf_mac_normalized_launch_path(firstPath);
    NSString* secondNormalized = spdf_mac_normalized_launch_path(secondPath);
    return firstNormalized.length > 0 && secondNormalized.length > 0 &&
           [firstNormalized isEqualToString:secondNormalized] && firstSize == secondSize && firstModificationDate &&
           secondModificationDate && [firstModificationDate isEqualToDate:secondModificationDate];
}

NSInteger spdf_mac_launch_inactive_worker_limit(void) {
    return 1;
}

BOOL spdf_mac_launch_can_start_inactive_work(NSUInteger renderOperationCount, NSUInteger metadataOperationCount,
                                             NSUInteger minimapOperationCount, NSUInteger zoomSeedOperationCount,
                                             NSUInteger cacheOperationCount, NSUInteger backgroundOperationCount) {
    return renderOperationCount == 0 && metadataOperationCount == 0 && minimapOperationCount == 0 &&
           zoomSeedOperationCount == 0 && cacheOperationCount == 0 && backgroundOperationCount == 0;
}
