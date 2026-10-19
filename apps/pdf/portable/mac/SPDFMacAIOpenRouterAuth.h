#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacAISignInReturnWatch.h"
FOUNDATION_EXPORT NSString* SPDFMacAIPKCEChallenge(NSString* verifier);
@class SPDFMacAICredentials;
// A fresh, single-use session. Caller opens returned URL in the browser. Completion is main queue.
@interface SPDFMacAIOpenRouterAuth : NSObject <SPDFMacAIBrowserSignIn>
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration*)configuration credentials:(SPDFMacAICredentials*)credentials;
- (NSURL*)startWithCompletion:(void (^)(BOOL connected, NSError* error))completion error:(NSError**)error;
- (void)cancel;
// YES while the browser has not come back to this sign-in: no callback received, nothing
// exchanged, not finished. Returning to the app in this state means the sign-in (often
// a first sign-up) lost its way back.
- (BOOL)isAwaitingBrowser;
@end
