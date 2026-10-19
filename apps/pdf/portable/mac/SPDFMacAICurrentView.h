#pragma once
#import <Cocoa/Cocoa.h>
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolsReader.h"
// Main-thread snapshot of an explicit viewport. Bounded, no window activation or navigation.
NSBitmapImageRep* SPDFAICaptureViewport(NSView* view, NSRect rect);
@interface ShenzhenMacDelegate (AICurrentView)
- (NSDictionary*)aiCurrentViewSnapshot;
@end
@interface SPDFMacAITools (AICurrentView)
- (void)performCurrentViewWithCompletion:(void (^)(NSDictionary*))completion;
@end
