#pragma once
// Whether a request is still getting somewhere (SPDFMacAIChatSession.mm). A long task runs as long as its steps make
// progress, under a high ceiling (SPDFMacAIRequestBudget defaultRequestBudget); what ends one early is a loop: the
// same call failing again and again, or step after step that does nothing new. The first time, the model is told what
// is happening and changes approach; only if it keeps looping does the request stop, with an answer saying what was
// done and what is left, and Continue. Pure: no I/O, no timers.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SPDFMacAIProgressVerdict) {
    SPDFMacAIProgressGoing,  // keep going
    SPDFMacAIProgressNudge,  // looping: tell the model (nudgeNote) and keep going
    SPDFMacAIProgressStop,   // still looping after being told: stop with a partial answer and Continue
};

// The same failing call this many times is a loop.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIProgressRepeatedFailures;
// This many steps in a row with nothing new is a loop.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIProgressStalledSteps;

// A call's identity: its tool and its arguments, keys sorted, so the same call twice has the same signature.
NSString* SPDFMacAIProgressSignature(NSString* name, NSDictionary* _Nullable arguments);

@interface SPDFMacAIProgressGuard : NSObject
// One call of the current step and what it returned. A result with "error" (or "cancelled") failed; one with
// "changed" or "undoable" changed something, after which reading the same thing again is new.
- (void)recordCall:(NSString*)name arguments:(nullable NSDictionary*)arguments result:(nullable NSDictionary*)result;
// The step's calls are all recorded: the verdict on the request so far.
- (SPDFMacAIProgressVerdict)endStep;
// After Nudge or Stop: what the model is told, naming the call that keeps failing and its error when there is one.
@property(nonatomic, readonly, copy, nullable) NSString* note;
@property(nonatomic, readonly) NSUInteger succeededCalls;
@property(nonatomic, readonly) NSUInteger failedCalls;
@property(nonatomic, readonly) NSUInteger steps;
@end

NS_ASSUME_NONNULL_END
