#import <AppKit/AppKit.h>
#import "SPDFMacAISignInReturnWatch.h"
// Coming back to the app during a browser sign-in. The app's activation is
// simulated by posting the notifications; a stand-in plays the sign-in.
@interface StandInSignIn : NSObject <SPDFMacAIBrowserSignIn>
@property(nonatomic) BOOL awaiting;
@end
@implementation StandInSignIn
- (BOOL)isAwaitingBrowser { return self.awaiting; }
@end
static void Settle(NSTimeInterval seconds) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
static void Post(NSNotificationName name) { [NSNotificationCenter.defaultCenter postNotificationName:name object:nil]; }
static void CheckSignInReturnWatch(void) {
    StandInSignIn* signIn=[StandInSignIn new]; signIn.awaiting=YES;
    __block NSInteger resets=0;
    SPDFMacAISignInReturnWatch* watch=[[SPDFMacAISignInReturnWatch alloc] initWithSignIn:signIn delay:.1
        lostWayBack:^{ resets++; }];
    // Posting runs the observers at once, so no settle between the posts: a slow runner's run loop can overrun one.
    Post(NSApplicationDidBecomeActiveNotification);
    Post(NSApplicationDidResignActiveNotification); Settle(.25);
    Check(resets==0,"a brief look back at the app while signing in changes nothing");
    Post(NSApplicationDidBecomeActiveNotification);
    Check(resets==0,"nothing changes right away on coming back");
    Settle(.25);
    Check(resets==1,"staying in the app with nothing received puts the connection back to idle");
    signIn.awaiting=NO;
    Post(NSApplicationDidBecomeActiveNotification); Settle(.25);
    Check(resets==1,"a sign-in that already came back is left alone");
    signIn.awaiting=YES; [watch stop];
    Post(NSApplicationDidBecomeActiveNotification); Settle(.25);
    Check(resets==1,"a finished or cancelled sign-in no longer watches the app");
    __weak SPDFMacAISignInReturnWatch* released=nil;
    @autoreleasepool {
        SPDFMacAISignInReturnWatch* dropped=[[SPDFMacAISignInReturnWatch alloc] initWithSignIn:signIn delay:.05
            lostWayBack:^{ resets++; }];
        released=dropped; Post(NSApplicationDidBecomeActiveNotification);
    }
    Settle(.2);
    Check(!released && resets==1,"nothing keeps a dropped watch alive or lets it fire");
    __weak StandInSignIn* gone=nil;
    @autoreleasepool {
        StandInSignIn* temporary=[StandInSignIn new]; temporary.awaiting=YES; gone=temporary;
        watch=[[SPDFMacAISignInReturnWatch alloc] initWithSignIn:temporary delay:.05 lostWayBack:^{ resets++; }];
    }
    Check(!gone,"the watch does not keep the sign-in alive");
    [watch stop];
}
