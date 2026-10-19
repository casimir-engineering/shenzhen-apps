#pragma once

#import "SPDFMacDelegatePrivate.h"

NSArray<ShenzhenMacDelegate*>* SPDFMacZoomSelfTestWindowControllers(void);

@interface ShenzhenMacDelegate (SPDFMacZoomSelfTestIntegration)
- (void)zoomSelfTestTimerFired:(NSTimer*)timer;
- (void)runZoomSelfTest;
@end
