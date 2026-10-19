#import <Cocoa/Cocoa.h>

typedef void (^SPDFMacLinkActivationHandler)(NSInteger pageIndex, NSPoint pagePoint);

// Defers a single-click link action long enough for AppKit to report a possible
// second click. Generation checks make cancellation deterministic without a
// timer retaining either the document view or its reader.
@interface SPDFMacDelayedLinkActivation : NSObject
- (instancetype)init;
- (instancetype)initWithDelay:(NSTimeInterval)delay NS_DESIGNATED_INITIALIZER;
- (void)schedulePageIndex:(NSInteger)pageIndex
                pagePoint:(NSPoint)pagePoint
                  handler:(SPDFMacLinkActivationHandler)handler;
- (void)cancel;
@end
