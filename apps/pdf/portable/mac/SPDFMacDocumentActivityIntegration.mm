#import "SPDFMacDocumentActivityIntegration.h"
#import "SPDFMacDocumentActivity.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacCollectionStore.h"
#import <objc/runtime.h>

// Seconds a tab must stay in front to count as viewed, between stamps of a long view, and without input before the
// person counts as away.
static const NSTimeInterval kViewThreshold = 2.0, kViewHeartbeat = 60.0, kIdleLimit = 60.0;
static char kTrackerKey, kTabOpenedKey;

@interface SPDFMacActivityTracker : NSObject
@property(nonatomic, strong) SPDFMacDocumentViewClock* clock;
@property(nonatomic, strong) NSMutableArray* observers;
@property(nonatomic) BOOL screensAsleep, sessionInactive;
@property(nonatomic) NSTimeInterval scheduledDeadline;
@end
@implementation SPDFMacActivityTracker
@end

static NSTimeInterval Now(void) { return NSDate.date.timeIntervalSince1970; }
static NSTimeInterval IdleSeconds(void) {
    double idle = CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
    return isfinite(idle) && idle >= 0 ? idle : 0;
}
static void Record(NSArray<NSDictionary*>* stamps) {
    for (NSDictionary* stamp in stamps)
        [SPDFMacDocumentActivityStore.sharedStore recordViewedPath:stamp[@"path"] at:[stamp[@"at"] doubleValue]];
}

@implementation ShenzhenMacDelegate (SPDFMacDocumentActivity)

- (void)activityStartTracking {
    if (objc_getAssociatedObject(self, &kTrackerKey)) return;
    SPDFMacActivityTracker* tracker = [SPDFMacActivityTracker new];
    tracker.clock = [[SPDFMacDocumentViewClock alloc] initWithThreshold:kViewThreshold heartbeat:kViewHeartbeat
                                                              idleLimit:kIdleLimit];
    tracker.observers = [NSMutableArray array];
    objc_setAssociatedObject(self, &kTrackerKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacActivityTracker* weakTracker = tracker;
    void (^observe)(NSNotificationCenter*, NSNotificationName, id, void (^)(void)) =
        ^(NSNotificationCenter* center, NSNotificationName name, id object, void (^change)(void)) {
            [tracker.observers addObject:[center addObserverForName:name object:object queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                    (void)note;
                    if (change) change();
                    [weakSelf activityViewMayHaveChanged];
                }]];
        };
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[ NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification,
                                       NSApplicationDidHideNotification, NSApplicationDidUnhideNotification ])
        observe(center, name, nil, nil);
    for (NSNotificationName name in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                                       NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification,
                                       NSWindowDidMiniaturizeNotification, NSWindowDidDeminiaturizeNotification,
                                       NSWindowDidChangeOcclusionStateNotification, NSWindowWillCloseNotification ])
        observe(center, name, _window, nil);
    NSNotificationCenter* workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    observe(workspace, NSWorkspaceScreensDidSleepNotification, nil, ^{ weakTracker.screensAsleep = YES; });
    observe(workspace, NSWorkspaceScreensDidWakeNotification, nil, ^{ weakTracker.screensAsleep = NO; });
    observe(workspace, NSWorkspaceSessionDidResignActiveNotification, nil, ^{ weakTracker.sessionInactive = YES; });
    observe(workspace, NSWorkspaceSessionDidBecomeActiveNotification, nil, ^{ weakTracker.sessionInactive = NO; });
    // Quitting ends the view in front, and what is unsaved is written before the process goes.
    [tracker.observers addObject:[center addObserverForName:NSApplicationWillTerminateNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification* note) {
            (void)note;
            Record([weakTracker.clock showPath:nil at:Now() idle:IdleSeconds()]);
            [SPDFMacDocumentActivityStore.sharedStore flushNow];
        }]];
    SPDFMacDocumentActivityStore* store = SPDFMacDocumentActivityStore.sharedStore;
    if (!store.backfillSources) store.backfillSources = ^NSDictionary* {
        // Collection is only read here, on the activity queue, the first time this profile is backfilled.
        SPDFMacCollectionStore* collection = SPDFMacCollectionStore.defaultStore;
        NSMutableArray* rows = [NSMutableArray array];
        for (NSDictionary* document in [collection documents]) {
            NSMutableDictionary* row = [document mutableCopy];
            row[@"editablePaths"] = [collection editablePathsForDocument:document];
            [rows addObject:row];
        }
        return @{@"collection" : rows};
    };
    [store start];
    [self activityViewMayHaveChanged];
}

- (void)activityTabDidLoad:(SPDFDocumentTab*)tab {
    if (tab.path.length && !objc_getAssociatedObject(tab, &kTabOpenedKey)) {
        objc_setAssociatedObject(tab, &kTabOpenedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [SPDFMacDocumentActivityStore.sharedStore recordOpenedPath:tab.path at:Now()];
    }
    [self activityViewMayHaveChanged];
}

- (void)activityDidOpenPaths:(NSArray<NSString*>*)paths {
    NSTimeInterval now = Now();
    for (NSString* path in paths)
        if ([path isKindOfClass:NSString.class]) [SPDFMacDocumentActivityStore.sharedStore recordOpenedPath:path at:now];
}

- (void)activityDocumentWillClose {
    if (!objc_getAssociatedObject(self, &kTrackerKey)) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf activityViewMayHaveChanged]; });
}

- (NSString*)activityViewedPath:(SPDFMacActivityTracker*)tracker {
    SPDFDocumentTab* tab = [self selectedTab];
    SPDFDocumentViewingState state = {
        .appActive = NSApp.isActive && !NSApp.isHidden,
        .keyOrMain = _window.isKeyWindow || _window.isMainWindow,
        .visible = _window.isVisible,
        .miniaturized = _window.isMiniaturized,
        .occluded = !(_window.occlusionState & NSWindowOcclusionStateVisible),
        .screensAsleep = tracker.screensAsleep,
        .sessionInactive = tracker.sessionInactive,
        .hasDocument = tab.path.length > 0 && !tab.missingFile,
    };
    return SPDFDocumentViewingStateIsViewing(state) ? tab.path : nil;
}

- (void)activityViewMayHaveChanged {
    SPDFMacActivityTracker* tracker = objc_getAssociatedObject(self, &kTrackerKey);
    if (!tracker) return;
    Record([tracker.clock showPath:[self activityViewedPath:tracker] at:Now() idle:IdleSeconds()]);
    [self activityScheduleTick:tracker];
}

// One wake-up at a time, only while a tab is in front: at 2 s, then once a minute.
- (void)activityScheduleTick:(SPDFMacActivityTracker*)tracker {
    NSTimeInterval deadline = tracker.clock.deadline;
    if (!deadline || deadline == tracker.scheduledDeadline) return;
    tracker.scheduledDeadline = deadline;
    __weak ShenzhenMacDelegate* weakSelf = self;
    __weak SPDFMacActivityTracker* weakTracker = tracker;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(0.0, deadline - Now()) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        SPDFMacActivityTracker* owner = weakTracker;
        if (!owner || owner.scheduledDeadline != deadline || !weakSelf) return;
        owner.scheduledDeadline = 0;
        // What is in front may have changed without a notification (a sheet, a hidden app): ask again first.
        Record([owner.clock showPath:[weakSelf activityViewedPath:owner] at:Now() idle:IdleSeconds()]);
        Record([owner.clock tickAt:Now() idle:IdleSeconds()]);
        [weakSelf activityScheduleTick:owner];
    });
}

- (void)aiWorkspaceContextWithArguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion {
    NSString* since = arguments[@"notViewedSince"];
    if (since && isnan(SPDFDocumentActivityParseTime(since, NSTimeZone.localTimeZone))) {
        completion(@{@"error" : @"notViewedSince must be a date (2026-10-19) or an ISO 8601 date and time."});
        return;
    }
    NSArray* paths = [self aiDocumentPaths];
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SPDFMacDocumentActivityStore* store = SPDFMacDocumentActivityStore.sharedStore;
        NSDictionary* activity = @{@"entries" : [store entriesForPaths:paths], @"recordedSince" : @([store recordedSince])};
        dispatch_async(dispatch_get_main_queue(), ^{
            ShenzhenMacDelegate* owner = weakSelf;
            completion(owner ? [owner aiWorkspaceContextWithArguments:arguments activity:activity]
                             : @{@"error" : @"Reader window is closed."});
        });
    });
}

@end
