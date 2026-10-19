#pragma once
#import <Foundation/Foundation.h>

@protocol SPDFMacAIBrowserSignIn <NSObject>
- (BOOL)isAwaitingBrowser;
@end

// A first-time sign-up on OpenRouter can end on its own pages without ever
// returning to the app. When the reader comes back to the app and stays for
// `delay` seconds while the sign-in has still received nothing, `lostWayBack`
// runs on the main queue. A brief visit (leaving again within `delay`) is
// ignored. The sign-in is held weakly; -stop (or releasing the watch) ends it.
@interface SPDFMacAISignInReturnWatch : NSObject
- (instancetype)initWithSignIn:(id<SPDFMacAIBrowserSignIn>)signIn
                         delay:(NSTimeInterval)delay
                   lostWayBack:(void (^)(void))lostWayBack;
- (void)stop;
@end
