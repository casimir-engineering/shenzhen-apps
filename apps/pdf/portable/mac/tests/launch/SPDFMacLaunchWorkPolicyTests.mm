#import <Foundation/Foundation.h>

#import "SPDFMacInactivePreload.h"
#import "SPDFMacLaunchWorkPolicy.h"

#define EXPECT(condition)                                             \
    do {                                                              \
        if (!(condition)) {                                           \
            NSLog(@"FAIL %s:%d: %s", __FILE__, __LINE__, #condition); \
            return 1;                                                 \
        }                                                             \
    } while (0)

static SPDFMacLaunchWorkPolicy* make_policy(void) {
    return [[SPDFMacLaunchWorkPolicy alloc] initWithVisibleStartDelay:0.05 inactiveIdleDelay:0.35 stageDelay:0.10];
}

static int test_visible_work_has_input_independent_deadlines(void) {
    SPDFMacLaunchWorkPolicy* policy = make_policy();
    NSUInteger generation = [policy beginCycleAtStage:SPDFMacLaunchWarmStageMetadata atTime:10.0];

    for (NSTimeInterval now = 10.01; now < 10.05; now += 0.01) {
        EXPECT(![policy noteUserInputAtTime:now]);
        EXPECT(policy.generation == generation);
    }
    EXPECT([policy takeReadyStageAtTime:10.049 expectedGeneration:generation] == SPDFMacLaunchWarmStageNone);
    EXPECT([policy takeReadyStageAtTime:10.05 expectedGeneration:generation] == SPDFMacLaunchWarmStageMetadata);

    for (NSTimeInterval now = 10.06; now < 10.15; now += 0.01) {
        EXPECT(![policy noteUserInputAtTime:now]);
        EXPECT(policy.generation == generation);
    }
    EXPECT([policy takeReadyStageAtTime:10.149 expectedGeneration:generation] == SPDFMacLaunchWarmStageNone);
    EXPECT([policy takeReadyStageAtTime:10.151 expectedGeneration:generation] == SPDFMacLaunchWarmStageActiveDocument);
    return 0;
}

static int test_only_inactive_work_is_idle_reset(void) {
    SPDFMacLaunchWorkPolicy* policy = make_policy();
    NSUInteger first = [policy beginCycleAtStage:SPDFMacLaunchWarmStageMetadata atTime:1.0];
    EXPECT([policy takeReadyStageAtTime:1.05 expectedGeneration:first] == SPDFMacLaunchWarmStageMetadata);
    EXPECT([policy takeReadyStageAtTime:1.151 expectedGeneration:first] == SPDFMacLaunchWarmStageActiveDocument);

    EXPECT([policy noteUserInputAtTime:1.20]);
    NSUInteger second = policy.generation;
    EXPECT(second != first);
    EXPECT([policy takeReadyStageAtTime:1.549 expectedGeneration:second] == SPDFMacLaunchWarmStageNone);
    EXPECT([policy noteUserInputAtTime:1.54]);
    NSUInteger third = policy.generation;
    EXPECT([policy takeReadyStageAtTime:1.889 expectedGeneration:third] == SPDFMacLaunchWarmStageNone);
    EXPECT([policy takeReadyStageAtTime:1.891 expectedGeneration:third] == SPDFMacLaunchWarmStageInactiveTabs);

    EXPECT([policy noteUserInputAtTime:2.0]);
    NSUInteger fourth = policy.generation;
    EXPECT([policy takeReadyStageAtTime:2.349 expectedGeneration:fourth] == SPDFMacLaunchWarmStageNone);
    EXPECT([policy takeReadyStageAtTime:2.351 expectedGeneration:fourth] == SPDFMacLaunchWarmStageInactiveTabs);
    return 0;
}

static int test_completion_disables_future_input_cancellation(void) {
    SPDFMacLaunchWorkPolicy* policy = make_policy();
    NSUInteger generation = [policy beginCycleAtStage:SPDFMacLaunchWarmStageInactiveTabs atTime:0];
    EXPECT([policy takeReadyStageAtTime:0.35 expectedGeneration:generation] == SPDFMacLaunchWarmStageInactiveTabs);
    [policy completeCycleForGeneration:generation];
    EXPECT(!policy.active);
    EXPECT(![policy noteUserInputAtTime:1]);
    return 0;
}

static int test_prerender_cancels_before_worker_open(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionOpenInForeground);
    EXPECT(![ownership workerMayBeginOpen]);
    EXPECT(![ownership workerMayBeginRender]);
    return 0;
}

static int test_prerender_foreground_owns_inflight_open(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    EXPECT([ownership workerMayBeginOpen]);
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult);
    EXPECT(![ownership workerMayBeginRender]);
    [ownership workerDidFinish];
    [ownership markConsumed];
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionUnavailable);
    return 0;
}

static int test_prerender_concurrent_claim_runs_one_open_and_no_stale_render(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    dispatch_group_t worker = dispatch_group_create();
    dispatch_semaphore_t openStarted = dispatch_semaphore_create(0);
    dispatch_semaphore_t foregroundClaimed = dispatch_semaphore_create(0);
    __block NSInteger openCount = 0;
    __block NSInteger renderCount = 0;
    dispatch_group_async(worker, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      if (![ownership workerMayBeginOpen]) return;
      openCount++;
      dispatch_semaphore_signal(openStarted);
      dispatch_semaphore_wait(foregroundClaimed, DISPATCH_TIME_FOREVER);
      if ([ownership workerMayBeginRender]) renderCount++;
      [ownership workerDidFinish];
    });

    EXPECT(dispatch_semaphore_wait(openStarted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult);
    dispatch_semaphore_signal(foregroundClaimed);
    EXPECT(dispatch_group_wait(worker, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    EXPECT(openCount == 1);
    EXPECT(renderCount == 0);
    return 0;
}

static int test_prerender_consumes_finished_result(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    EXPECT([ownership workerMayBeginOpen]);
    EXPECT([ownership workerMayBeginRender]);
    [ownership workerDidFinish];
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionConsumeFinishedResult);
    [ownership markConsumed];
    return 0;
}

static int test_prerender_late_claim_adopts_inflight_render(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    EXPECT([ownership workerMayBeginOpen]);
    EXPECT([ownership workerMayBeginRender]);
    // The render is already in flight: redoing the open and render in the
    // foreground would cost the same work again, so the claim owns this result.
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionWaitForOwnedResult);
    EXPECT(!ownership.abandoned);
    [ownership workerDidFinish];
    [ownership markConsumed];
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionUnavailable);
    return 0;
}

static int test_prerender_abandonment_stops_new_work(void) {
    SPDFMacLaunchPrerenderOwnership* ownership = [[SPDFMacLaunchPrerenderOwnership alloc] init];
    [ownership abandon];
    EXPECT(ownership.abandoned);
    EXPECT(![ownership workerMayBeginOpen]);
    EXPECT([ownership claimForForeground] == SPDFMacLaunchPrerenderForegroundActionUnavailable);
    return 0;
}

static int test_inactive_preload_foreground_claims_inflight_open(void) {
    SPDFMacInactivePreload* preload = [SPDFMacInactivePreload new];
    EXPECT([preload workerMayBeginOpen]);
    EXPECT([preload claimForForeground]);
    void* expected = (void*)0x1234;
    NSDictionary* expectedAttributes = @{@"size" : @42};
    EXPECT(![preload workerMayContinueWithDocument:expected attributes:expectedAttributes]);
    [preload workerFinishedWithPages:nil];
    NSDictionary* attributes = nil;
    EXPECT([preload takeForegroundDocumentWithAttributes:&attributes] == expected);
    EXPECT([attributes isEqualToDictionary:expectedAttributes]);
    return 0;
}

static int test_inactive_preload_finished_result_has_one_consumer(void) {
    SPDFMacInactivePreload* preload = [SPDFMacInactivePreload new];
    EXPECT([preload workerMayBeginOpen]);
    void* expected = (void*)0x5678;
    NSDictionary* expectedAttributes = @{@"size" : @84};
    NSArray* expectedPages = @[ @1, @2 ];
    EXPECT([preload workerMayContinueWithDocument:expected attributes:expectedAttributes]);
    [preload workerFinishedWithPages:expectedPages];
    EXPECT([preload claimForForeground]);
    EXPECT([preload takeBackgroundDocumentWithAttributes:nil pages:nil] == NULL);
    NSDictionary* attributes = nil;
    EXPECT([preload takeForegroundDocumentWithAttributes:&attributes] == expected);
    EXPECT([attributes isEqualToDictionary:expectedAttributes]);
    EXPECT(![preload claimForForeground]);
    return 0;
}

static int test_rejected_preload_drains_once_without_blocking(void) {
    for (NSInteger phase=0; phase<3; ++phase) {
        SPDFMacInactivePreload* preload=[SPDFMacInactivePreload new];
        void* expected=phase ? (void*)0x2345 : NULL;
        if (phase) EXPECT([preload workerMayBeginOpen]);
        if (phase==2) {
            EXPECT([preload workerMayContinueWithDocument:expected attributes:@{}]);
            [preload workerFinishedWithPages:nil];
        }
        EXPECT([preload claimForForeground]);
        dispatch_semaphore_t finished=dispatch_semaphore_create(0);
        __block void* disposed=NULL; __block BOOL onMain=YES;
        [preload discardForegroundDocumentWithHandler:^(void* document) {
            disposed=document; onMain=NSThread.isMainThread; dispatch_semaphore_signal(finished);
        }];
        if (phase==1) {
            EXPECT(dispatch_semaphore_wait(finished,DISPATCH_TIME_NOW)!=0);
            EXPECT([preload workerFinishedCancelledDocument:expected attributes:@{}]);
        }
        EXPECT(dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
        EXPECT(disposed==expected && !onMain);
        EXPECT([preload takeForegroundDocumentWithAttributes:nil]==NULL);
    }
    return 0;
}

static int test_adjacent_then_mru_then_distance_order(void) {
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    NSObject* d = [NSObject new];
    NSObject* e = [NSObject new];
    SPDFMacLaunchWorkPolicy* policy = make_policy();
    [policy recordActivationOfIdentifier:a];
    [policy recordActivationOfIdentifier:e];
    [policy recordActivationOfIdentifier:c];
    NSArray<NSNumber*>* order = [policy orderedInactiveIndexesForIdentifiers:@[ a, b, c, d, e ] selectedIndex:2];
    EXPECT(([order isEqualToArray:@[ @3, @1, @4, @0 ]]));
    return 0;
}

static int test_selected_tab_promotion_rebuilds_priority(void) {
    NSObject* a = [NSObject new];
    NSObject* b = [NSObject new];
    NSObject* c = [NSObject new];
    NSObject* d = [NSObject new];
    SPDFMacLaunchWorkPolicy* policy = make_policy();
    [policy recordActivationOfIdentifier:b];
    [policy recordActivationOfIdentifier:d];
    NSArray<NSNumber*>* order = [policy orderedInactiveIndexesForIdentifiers:@[ a, b, c, d ] selectedIndex:3];
    EXPECT(([order isEqualToArray:@[ @2, @1, @0 ]]));
    return 0;
}

static int test_file_identity_does_not_resolve_symlinks(void) {
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    EXPECT([fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSString* file = [root stringByAppendingPathComponent:@"document.pdf"];
    EXPECT([@"pdf" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    NSString* link = [root stringByAppendingPathComponent:@"alias.pdf"];
    EXPECT([fm createSymbolicLinkAtPath:link withDestinationPath:file error:nil]);
    NSDate* modified = [fm attributesOfItemAtPath:file error:nil][NSFileModificationDate];

    EXPECT(spdf_mac_launch_file_identity_matches(file, 3, modified, file, 3, modified));
    EXPECT(!spdf_mac_launch_file_identity_matches(file, 3, modified, link, 3, modified));
    EXPECT(![spdf_mac_normalized_launch_path(file) isEqualToString:spdf_mac_normalized_launch_path(link)]);
    EXPECT(!spdf_mac_launch_file_identity_matches(file, 3, modified, file, 4, modified));
    EXPECT(!spdf_mac_launch_file_identity_matches(file, 3, modified, file, 3, [modified dateByAddingTimeInterval:1]));
    [fm removeItemAtPath:root error:nil];
    return 0;
}

static int test_inactive_work_budget(void) {
    EXPECT(spdf_mac_launch_inactive_worker_limit() == 1);
    EXPECT(spdf_mac_launch_can_start_inactive_work(0, 0, 0, 0, 0, 0));
    for (NSUInteger index = 0; index < 6; ++index) {
        NSUInteger counts[6] = {0, 0, 0, 0, 0, 0};
        counts[index] = 1;
        EXPECT(
            !spdf_mac_launch_can_start_inactive_work(counts[0], counts[1], counts[2], counts[3], counts[4], counts[5]));
    }
    return 0;
}

static NSUInteger count_occurrences(NSString* source, NSString* needle) {
    NSUInteger count = 0;
    NSRange remaining = NSMakeRange(0, source.length);
    while (remaining.length > 0) {
        NSRange match = [source rangeOfString:needle options:0 range:remaining];
        if (match.location == NSNotFound) break;
        count++;
        NSUInteger next = NSMaxRange(match);
        remaining = NSMakeRange(next, source.length - next);
    }
    return count;
}

static NSString* source_slice(NSString* source, NSString* startMarker, NSString* endMarker) {
    NSRange start = [source rangeOfString:startMarker];
    if (start.location == NSNotFound) return nil;
    NSRange tail = NSMakeRange(NSMaxRange(start), source.length - NSMaxRange(start));
    NSRange end = [source rangeOfString:endMarker options:0 range:tail];
    if (end.location == NSNotFound) return nil;
    return [source substringWithRange:NSMakeRange(start.location, end.location - start.location)];
}

static int test_production_integration_contract(void) {
    NSString* testPath = @(__FILE__);
    if (!testPath.isAbsolutePath)
        testPath = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:testPath];
    NSString* macDirectory = [[testPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../.."];
    NSString* appSourcePath = [macDirectory stringByAppendingPathComponent:@"ShenzhenPDFMac.mm"];
    NSString* integrationSourcePath = [macDirectory stringByAppendingPathComponent:@"SPDFMacLaunchWorkIntegration.mm"];
    NSString* appSource = [NSString stringWithContentsOfFile:appSourcePath encoding:NSUTF8StringEncoding error:nil];
    NSString* integrationSource = [NSString stringWithContentsOfFile:integrationSourcePath
                                                            encoding:NSUTF8StringEncoding
                                                               error:nil];
    EXPECT(appSource != nil);
    EXPECT(integrationSource != nil);

    NSString* preload =
        source_slice(appSource, @"- (void)preloadInactiveTabsWithCompletion:(dispatch_block_t)completion {",
                     @"// Reload comments synchronously");
    EXPECT(preload != nil);
    EXPECT(count_occurrences(preload, @"openSpdfDocumentAtPath:") == 1);
    EXPECT([preload containsString:@"renderToken:token"]);
    EXPECT([preload containsString:@"for (NSInteger page = 0; page < pageCount; ++page)"]);
    EXPECT([preload containsString:@"weakOperation.cancelled"]);
    EXPECT([appSource containsString:@"NSQualityOfServiceBackground"]);
    EXPECT([integrationSource containsString:@"spdf_mac_launch_can_start_inactive_work"]);
    return 0;
}

int main(void) {
    @autoreleasepool {
        if (test_visible_work_has_input_independent_deadlines()) return 1;
        if (test_only_inactive_work_is_idle_reset()) return 1;
        if (test_completion_disables_future_input_cancellation()) return 1;
        if (test_prerender_cancels_before_worker_open()) return 1;
        if (test_prerender_foreground_owns_inflight_open()) return 1;
        if (test_prerender_concurrent_claim_runs_one_open_and_no_stale_render()) return 1;
        if (test_prerender_late_claim_adopts_inflight_render()) return 1;
        if (test_prerender_consumes_finished_result()) return 1;
        if (test_prerender_abandonment_stops_new_work()) return 1;
        if (test_inactive_preload_foreground_claims_inflight_open()) return 1;
        if (test_inactive_preload_finished_result_has_one_consumer()) return 1;
        if (test_rejected_preload_drains_once_without_blocking()) return 1;
        if (test_adjacent_then_mru_then_distance_order()) return 1;
        if (test_selected_tab_promotion_rebuilds_priority()) return 1;
        if (test_file_identity_does_not_resolve_symlinks()) return 1;
        if (test_inactive_work_budget()) return 1;
        if (test_production_integration_contract()) return 1;
        NSLog(@"SPDFMacLaunchWorkPolicyTests passed");
    }
    return 0;
}
