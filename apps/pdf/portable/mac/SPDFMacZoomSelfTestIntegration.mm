#import "SPDFMacZoomSelfTestIntegration.h"

#import "SPDFMacSupport.h"

#include <math.h>

@implementation ShenzhenMacDelegate (SPDFMacZoomSelfTestIntegration)

- (void)zoomSelfTestTimerFired:(NSTimer*)timer {
    (void)timer;
    [self runZoomSelfTest];
}

// Synthetic live-zoom gesture driver for profiling (SPDF_ZOOM_SELFTEST=1).
// Page-navigation stress: rapid page changes while renders are in flight.
- (void)runZoomSelfTestNavigationSteps:(NSInteger)steps forward:(BOOL)forward {
    if (steps <= 0) {
        if (forward) {
            [self runZoomSelfTestNavigationSteps:14 forward:NO];
        } else {
            spdf_zoom_profile_log(@"SELFTEST navigation done");
            spdf_zoom_profile_log(@"SELFTEST done");
        }
        return;
    }
    double t0 = spdf_zoom_profile_now_ms();
    if (forward)
        [self nextPage:nil];
    else
        [self previousPage:nil];
    double elapsed = spdf_zoom_profile_now_ms() - t0;
    if (elapsed > 8.0) spdf_zoom_profile_log(@"SELFTEST pageNav %@ took %.1fms", forward ? @"next" : @"prev", elapsed);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self runZoomSelfTestNavigationSteps:steps - 1 forward:forward];
    });
}

// Continuous-scroll stress (profiling only): emulates trackpad scrolling the
// way SPDFScrollView's scrollPreciseTrackpadEventWithDamping does (clipview
// scrollToPoint + reflectScrolledClipView + documentScrollPositionChanged) in
// small steps every 8ms, so renders/crops/adoptions fire DURING active
// scrolling. Records an input-latency histogram (gap between when a step was
// scheduled to fire and when the main thread actually ran it) -- the proxy for
// "missed inputs".
- (void)runZoomSelfTestScrollPhaseNamed:(NSString*)name
                                  steps:(NSInteger)totalSteps
                             zoomAtStep:(NSInteger)zoomStep
                             completion:(void (^)(void))completion {
    NSClipView* clipView = _pageScrollView.contentView;
    double startY = clipView.bounds.origin.y;
    double maxY = MAX(0.0, NSHeight(_pageView.bounds) - NSHeight(clipView.bounds));
    double avgPageHeight = _renderedPages.count > 0 ? NSHeight(_pageView.bounds) / (double)_renderedPages.count : 800.0;
    double span = MIN(10.0 * avgPageHeight, MAX(0.0, maxY - startY));
    double stepPts = MAX(2.0, span / (double)MAX(1, totalSteps));
    spdf_zoom_profile_log(@"SELFTEST %@ start zoom=%.3f page=%ld steps=%ld step=%.1fpt startY=%.0f maxY=%.0f", name,
                          _zoom, (long)_pageIndex, (long)totalSteps, stepPts, startY, maxY);
    NSPoint zoomWindowPoint =
        [_pageScrollView convertPoint:NSMakePoint(NSMidX(_pageScrollView.bounds), NSMidY(_pageScrollView.bounds))
                               toView:nil];
    __block NSInteger remaining = totalSteps;
    __block double expectedFire = 0.0;
    __block long bucketLt8 = 0, bucket8_16 = 0, bucket16_33 = 0, bucket33_100 = 0, bucketGt100 = 0;
    __block double maxLatency = 0.0, sumLatency = 0.0;
    __weak __typeof__(self) weakSelf = self;
    __block void (^step)(void) = nil;
    void (^stepImpl)(void) = ^{
      __strong __typeof__(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      double now = spdf_zoom_profile_now_ms();
      double latency = expectedFire > 0.0 ? now - expectedFire : 0.0;
      if (latency < 8.0)
          bucketLt8++;
      else if (latency < 16.0)
          bucket8_16++;
      else if (latency < 33.0)
          bucket16_33++;
      else if (latency < 100.0)
          bucket33_100++;
      else
          bucketGt100++;
      if (latency > maxLatency) maxLatency = latency;
      sumLatency += MAX(0.0, latency);
      if (latency > 33.0) spdf_zoom_profile_log(@"SELFTEST %@ stepLatency %.0fms", name, latency);

      NSInteger stepIndex = totalSteps - remaining;
      remaining--;
      if (zoomStep >= 0 && stepIndex == zoomStep)
          [strongSelf beginLiveZoomByFactor:1.08 centeredAtWindowPoint:zoomWindowPoint];
      if (zoomStep >= 0 && stepIndex == zoomStep + 60)
          [strongSelf beginLiveZoomByFactor:1.0 / 1.08 centeredAtWindowPoint:zoomWindowPoint];

      // Mirror the user-scroll entry path exactly.
      NSClipView* clip = strongSelf->_pageScrollView.contentView;
      double maxYNow = MAX(0.0, NSHeight(strongSelf->_pageView.bounds) - NSHeight(clip.bounds));
      NSPoint origin = clip.bounds.origin;
      origin.y = MIN(maxYNow, origin.y + stepPts);
      [clip scrollToPoint:origin];
      [strongSelf->_pageScrollView reflectScrolledClipView:clip];
      [strongSelf documentScrollPositionChanged];

      if (remaining <= 0) {
          long total = bucketLt8 + bucket8_16 + bucket16_33 + bucket33_100 + bucketGt100;
          spdf_zoom_profile_log(@"SELFTEST %@ histogram steps=%ld lt8=%ld b8_16=%ld b16_33=%ld b33_100=%ld "
                                @"gt100=%ld max=%.0fms avg=%.1fms endPage=%ld endZoom=%.3f",
                                name, total, bucketLt8, bucket8_16, bucket16_33, bucket33_100, bucketGt100, maxLatency,
                                total > 0 ? sumLatency / (double)total : 0.0, (long)strongSelf->_pageIndex,
                                strongSelf->_zoom);
          step = nil;
          if (completion) completion();
          return;
      }
      expectedFire = spdf_zoom_profile_now_ms() + 8.0;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.008 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                     step);
    };
    step = [stepImpl copy];
    step();
}

// Settle at a zoom where pages need 16-31MB renders, jump near the top of the
// document, then run a pure continuous-scroll phase and a mixed
// scroll+live-zoom phase before handing off to the navigation stress.
- (void)runZoomSelfTestScrollStress {
    double targetZoom = 1.7;
    double factor = targetZoom / MAX(0.0001, (double)_zoom);
    NSPoint windowPoint =
        [_pageScrollView convertPoint:NSMakePoint(NSMidX(_pageScrollView.bounds), NSMidY(_pageScrollView.bounds))
                               toView:nil];
    spdf_zoom_profile_log(@"SELFTEST scroll setup zoom=%.3f->%.3f", _zoom, targetZoom);
    if (fabs(factor - 1.0) > 0.001) [self beginLiveZoomByFactor:factor centeredAtWindowPoint:windowPoint];
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      __strong __typeof__(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      NSPoint topOrigin = strongSelf->_pageScrollView.contentView.bounds.origin;
      topOrigin.y = 0.0;
      [strongSelf scrollDocumentClipViewToOrigin:topOrigin notify:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong __typeof__(self) innerSelf = weakSelf;
        if (!innerSelf) return;
        [innerSelf
            runZoomSelfTestScrollPhaseNamed:@"scrollA"
                                      steps:500
                                 zoomAtStep:-1
                                 completion:^{
                                   __strong __typeof__(self) midSelf = weakSelf;
                                   if (!midSelf) return;
                                   [midSelf
                                       runZoomSelfTestScrollPhaseNamed:@"scrollB-mixed"
                                                                 steps:375
                                                            zoomAtStep:187
                                                            completion:^{
                                                              __strong __typeof__(self) highSelf = weakSelf;
                                                              if (!highSelf) return;
                                                              // High-zoom phase: beyond the full-page render cap the
                                                              // viewport crop machinery maintains the visible region
                                                              // while scrolling.
                                                              double highTarget = 5.0;
                                                              double highFactor =
                                                                  highTarget / MAX(0.0001, (double)highSelf->_zoom);
                                                              NSPoint highPoint = [highSelf->_pageScrollView
                                                                  convertPoint:NSMakePoint(
                                                                                   NSMidX(highSelf->_pageScrollView
                                                                                              .bounds),
                                                                                   NSMidY(highSelf->_pageScrollView
                                                                                              .bounds))
                                                                        toView:nil];
                                                              [highSelf beginLiveZoomByFactor:highFactor
                                                                        centeredAtWindowPoint:highPoint];
                                                              dispatch_after(
                                                                  dispatch_time(DISPATCH_TIME_NOW,
                                                                                (int64_t)(1.0 * NSEC_PER_SEC)),
                                                                  dispatch_get_main_queue(), ^{
                                                                    __strong __typeof__(self) hsSelf = weakSelf;
                                                                    if (!hsSelf) return;
                                                                    [hsSelf
                                                                        runZoomSelfTestScrollPhaseNamed:
                                                                            @"scrollC-highzoom"
                                                                                                  steps:500
                                                                                             zoomAtStep:-1
                                                                                             completion:^{
                                                                                               __strong __typeof__(self)
                                                                                                   navSelf = weakSelf;
                                                                                               if (!navSelf) return;
                                                                                               spdf_zoom_profile_log(
                                                                                                   @"SELFTEST "
                                                                                                   @"navigation start "
                                                                                                   @"zoom=%.3f "
                                                                                                   @"page=%ld",
                                                                                                   navSelf->_zoom,
                                                                                                   (long)navSelf
                                                                                                       ->_pageIndex);
                                                                                               [navSelf
                                                                                                   runZoomSelfTestNavigationSteps:
                                                                                                       14
                                                                                                                          forward:
                                                                                                                              YES];
                                                                                             }];
                                                                  });
                                                            }];
                                 }];
      });
    });
}

- (void)runZoomSelfTestPhases:(NSArray<NSDictionary*>*)phases index:(NSUInteger)index {
    if (index >= phases.count) {
        [self runZoomSelfTestScrollStress];
        return;
    }
    NSDictionary* phase = phases[index];
    NSInteger count = [phase[@"count"] integerValue];
    double factor = [phase[@"factor"] doubleValue];
    double settle = [phase[@"settle"] doubleValue];
    spdf_zoom_profile_log(@"SELFTEST phase %lu start factor=%.3f count=%ld zoom=%.3f", (unsigned long)index, factor,
                          (long)count, _zoom);
    NSPoint windowPoint =
        [_pageScrollView convertPoint:NSMakePoint(NSMidX(_pageScrollView.bounds), NSMidY(_pageScrollView.bounds))
                               toView:nil];
    __block NSInteger remaining = count;
    __weak __typeof__(self) weakSelf = self;
    __block void (^step)(void) = nil;
    void (^stepImpl)(void) = ^{
      __strong __typeof__(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      if (remaining <= 0) {
          void (^continueBlock)(void) = ^{
            [weakSelf runZoomSelfTestPhases:phases index:index + 1];
          };
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settle * NSEC_PER_SEC)), dispatch_get_main_queue(),
                         continueBlock);
          step = nil;
          return;
      }
      remaining--;
      [strongSelf beginLiveZoomByFactor:factor centeredAtWindowPoint:windowPoint];
      [strongSelf->_pageView displayIfNeeded];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.008 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                     step);
    };
    step = [stepImpl copy];
    step();
}

- (void)runZoomSelfTest {
    if (!_doc) {
        for (ShenzhenMacDelegate* controller in SPDFMacZoomSelfTestWindowControllers()) {
            if (controller != self && controller->_doc) {
                [controller runZoomSelfTest];
                return;
            }
        }
        static NSInteger retries = 0;
        spdf_zoom_profile_log(@"SELFTEST no document yet (retry %ld)", (long)retries);
        if (retries++ < 10) {
            NSTimer* timer = [NSTimer timerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(zoomSelfTestTimerFired:)
                                                   userInfo:nil
                                                    repeats:NO];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        }
        return;
    }
    NSArray<NSDictionary*>* phases = @[
        @{@"count" : @60, @"factor" : @1.05, @"settle" : @2.5}, // zoom to max
        @{@"count" : @6, @"factor" : @0.97, @"settle" : @2.5},  // first unzoom events from fully zoomed in
        @{@"count" : @40, @"factor" : @0.95, @"settle" : @2.5}, // long unzoom
        @{@"count" : @12, @"factor" : @1.06, @"settle" : @2.5}, // zoom back in
        @{@"count" : @6, @"factor" : @0.97, @"settle" : @2.5},  // short unzoom again
    ];
    spdf_zoom_profile_log(@"SELFTEST begin zoom=%.3f", _zoom);
    [self runZoomSelfTestPhases:phases index:0];
}

@end
