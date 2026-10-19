#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacLaunchWarmStage) {
    SPDFMacLaunchWarmStageNone = 0,
    SPDFMacLaunchWarmStageMetadata,
    SPDFMacLaunchWarmStageActiveDocument,
    SPDFMacLaunchWarmStageInactiveTabs,
};

// Pure, clock-injected policy. It owns no timers, queues, or application state.
@interface SPDFMacLaunchWorkPolicy : NSObject

- (instancetype)initWithVisibleStartDelay:(NSTimeInterval)visibleStartDelay
                        inactiveIdleDelay:(NSTimeInterval)inactiveIdleDelay
                               stageDelay:(NSTimeInterval)stageDelay;

@property(nonatomic, readonly, getter=isActive) BOOL active;
@property(nonatomic, readonly) NSUInteger generation;

- (NSUInteger)beginCycleAtStage:(SPDFMacLaunchWarmStage)stage atTime:(NSTimeInterval)now;
- (BOOL)noteUserInputAtTime:(NSTimeInterval)now;
- (NSTimeInterval)delayUntilReadyAtTime:(NSTimeInterval)now;
- (SPDFMacLaunchWarmStage)takeReadyStageAtTime:(NSTimeInterval)now expectedGeneration:(NSUInteger)generation;
- (void)completeCycleForGeneration:(NSUInteger)generation;

- (void)recordActivationOfIdentifier:(id)identifier;
- (NSArray<NSNumber*>*)orderedInactiveIndexesForIdentifiers:(NSArray*)identifiers
                                              selectedIndex:(NSInteger)selectedIndex;

@end

typedef NS_ENUM(NSInteger, SPDFMacLaunchPrerenderForegroundAction) {
    SPDFMacLaunchPrerenderForegroundActionUnavailable = 0,
    SPDFMacLaunchPrerenderForegroundActionOpenInForeground,
    SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult,
    SPDFMacLaunchPrerenderForegroundActionConsumeFinishedResult,
};

// Thread-safe ownership policy for the launch-only speculative document open.
// The foreground either cancels before the worker claims the open or takes
// ownership of the one in-flight result. It never starts a competing open.
@interface SPDFMacLaunchPrerenderOwnership : NSObject

@property(nonatomic, readonly, getter=isAbandoned) BOOL abandoned;

- (BOOL)workerMayBeginOpen;
- (BOOL)workerMayBeginRender;
- (void)workerDidFinish;
- (SPDFMacLaunchPrerenderForegroundAction)claimForForeground;
- (void)markConsumed;
- (void)abandon;

@end

typedef void (^SPDFMacLaunchWarmStageHandler)(SPDFMacLaunchWarmStage stage, NSUInteger generation, id context);

// Thin AppKit timer/event adapter around SPDFMacLaunchWorkPolicy. Its local
// event monitor observes and returns events unchanged.
@interface SPDFMacLaunchWorkCoordinator : NSObject

- (instancetype)initWithVisibleStartDelay:(NSTimeInterval)visibleStartDelay
                        inactiveIdleDelay:(NSTimeInterval)inactiveIdleDelay
                               stageDelay:(NSTimeInterval)stageDelay;
- (void)activateWithStageHandler:(SPDFMacLaunchWarmStageHandler)stageHandler
             interruptionHandler:(dispatch_block_t)interruptionHandler;
- (void)beginCycleAtStage:(SPDFMacLaunchWarmStage)stage context:(id)context;
- (void)completeCycleForGeneration:(NSUInteger)generation;
- (void)recordActivationOfIdentifier:(id)identifier;
- (NSArray<NSNumber*>*)orderedInactiveIndexesForIdentifiers:(NSArray*)identifiers
                                              selectedIndex:(NSInteger)selectedIndex;
- (void)stop;

@end

NSString* _Nullable spdf_mac_normalized_launch_path(NSString* _Nullable path);
BOOL spdf_mac_launch_file_identity_matches(NSString* _Nullable firstPath, unsigned long long firstSize,
                                           NSDate* _Nullable firstModificationDate, NSString* _Nullable secondPath,
                                           unsigned long long secondSize, NSDate* _Nullable secondModificationDate);
NSInteger spdf_mac_launch_inactive_worker_limit(void);
BOOL spdf_mac_launch_can_start_inactive_work(NSUInteger renderOperationCount, NSUInteger metadataOperationCount,
                                             NSUInteger minimapOperationCount, NSUInteger zoomSeedOperationCount,
                                             NSUInteger cacheOperationCount, NSUInteger backgroundOperationCount);

NS_ASSUME_NONNULL_END
