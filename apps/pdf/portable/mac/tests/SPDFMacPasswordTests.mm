#import <Cocoa/Cocoa.h>
#import <objc/message.h>

#import "SPDFMacPassword.h"

static int failures;

#define CHECK(condition, message)                                                                                       \
    do {                                                                                                                \
        if (!(condition)) {                                                                                             \
            fprintf(stderr, "FAIL: %s\n", message);                                                                   \
            failures++;                                                                                                 \
        }                                                                                                               \
    } while (0)

static NSString* temporary_file(void) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString* path = [directory stringByAppendingPathComponent:@"source.pdf"];
    [@"first" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

static BOOL spin_until(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return condition();
}

static NSString* password_string(SPDFPasswordCredential* credential) {
    __block NSString* result = nil;
    [credential withUTF8Password:^(const char* password) {
      result = [NSString stringWithUTF8String:password ?: ""];
    }];
    return result;
}

static void submit_password(SPDFPasswordSheetController* controller, NSString* password) {
    NSSecureTextField* field = [controller valueForKey:@"passwordField"];
    field.stringValue = password;
    SEL selector = NSSelectorFromString(@"attemptUnlock:");
    ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, nil);
}

static void test_password_sheet_retry_success_and_cancel(void) {
    [NSApplication sharedApplication];
    NSWindow* parent = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 640, 480)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [parent orderFront:nil];

    __block NSInteger attempts = 0;
    __block BOOL cancelled = NO;
    __block NSString* firstPassword = nil;
    __block NSString* secondPassword = nil;
    SPDFPasswordSheetController* controller = [[SPDFPasswordSheetController alloc]
        initWithParentWindow:parent
                 displayName:@"encrypted.pdf"
              attemptHandler:^(SPDFPasswordCredential* credential, SPDFPasswordAttemptCompletion completion) {
                attempts++;
                if (attempts == 1) {
                    firstPassword = password_string(credential);
                    completion(SPDFPasswordAttemptIncorrect, nil);
                } else {
                    secondPassword = password_string(credential);
                    completion(SPDFPasswordAttemptSucceeded, nil);
                }
              }
               cancelHandler:^{ cancelled = YES; }];
    [controller begin];
    CHECK(parent.attachedSheet != nil, "password panel was not attached as a sheet");
    CHECK([parent.attachedSheet.title isEqualToString:@"Password Required"], "password sheet has wrong title");

    submit_password(controller, @"wrong-secret");
    CHECK(spin_until(^BOOL {
            NSTextField* status = [controller valueForKey:@"statusField"];
            return [status.stringValue isEqualToString:@"Incorrect password."];
          },
          1.0),
          "wrong-password result did not restore retry UI");
    NSSecureTextField* field = [controller valueForKey:@"passwordField"];
    NSButton* unlock = [controller valueForKey:@"unlockButton"];
    CHECK([firstPassword isEqualToString:@"wrong-secret"], "sheet did not pass the first password to its handler");
    CHECK(field.stringValue.length == 0, "secure field retained the submitted password");
    CHECK(field.enabled && unlock.enabled, "wrong password did not re-enable the secure controls");
    CHECK(parent.attachedSheet != nil, "wrong password dismissed the sheet instead of allowing retry");
    CHECK(!cancelled, "wrong password invoked cancel");

    submit_password(controller, @"right-secret");
    CHECK(spin_until(^BOOL { return parent.attachedSheet == nil; }, 1.0),
          "successful password did not dismiss the sheet");
    CHECK(attempts == 2, "password sheet did not perform exactly two attempts");
    CHECK([secondPassword isEqualToString:@"right-secret"], "sheet did not pass the retry password to its handler");
    CHECK(!cancelled, "successful password invoked cancel");

    __block NSInteger cancelCount = 0;
    SPDFPasswordSheetController* cancelledController = [[SPDFPasswordSheetController alloc]
        initWithParentWindow:parent
                 displayName:@"cancel.pdf"
              attemptHandler:^(__unused SPDFPasswordCredential* credential,
                               __unused SPDFPasswordAttemptCompletion completion) {
                CHECK(NO, "cancelled sheet attempted to unlock");
              }
               cancelHandler:^{ cancelCount++; }];
    [cancelledController begin];
    CHECK(parent.attachedSheet != nil, "cancel test sheet was not attached");
    [cancelledController cancel];
    [cancelledController cancel];
    CHECK(spin_until(^BOOL { return parent.attachedSheet == nil; }, 1.0), "cancel did not dismiss the sheet");
    CHECK(cancelCount == 1, "cancel handler did not run exactly once");
    [parent orderOut:nil];
}

int main(void) {
    @autoreleasepool {
        SPDFPasswordCredentialStore* store = SPDFPasswordCredentialStore.sharedStore;
        [store removeAllCredentials];
        NSString* path = temporary_file();
        NSString* sourceIdentity = [store sourceIdentityTokenForSourcePath:path];
        NSString* noCredentialToken = [store cacheTokenForSourcePath:path];
        CHECK([store credentialForSourcePath:path] == nil, "fresh source unexpectedly has a credential");

        SPDFPasswordCredential* credential = [[SPDFPasswordCredential alloc] initWithPassword:@"private-secret"];
        [store setCredential:credential forSourcePath:path];
        CHECK([store credentialForSourcePath:path] == credential, "stored credential was not returned");
        NSString* credentialToken = [store cacheTokenForSourcePath:path];
        CHECK(![credentialToken isEqualToString:noCredentialToken], "credential did not invalidate worker cache key");
        CHECK([[store sourceIdentityTokenForSourcePath:path] isEqualToString:sourceIdentity],
              "storing a credential changed the source identity token");

        [NSThread sleepForTimeInterval:0.01];
        [@"source identity changed" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CHECK(![[store sourceIdentityTokenForSourcePath:path] isEqualToString:sourceIdentity],
              "source mutation did not change the source identity token");
        CHECK([store credentialForSourcePath:path] == nil, "source mutation did not invalidate credential");
        CHECK(![[store cacheTokenForSourcePath:path] isEqualToString:credentialToken],
              "source mutation did not invalidate worker cache token");

        SPDFPasswordCredential* replacement = [[SPDFPasswordCredential alloc] initWithPassword:@"owner-secret"];
        [store setCredential:replacement forSourcePath:path];
        NSString* replacementToken = [store cacheTokenForSourcePath:path];
        NSString* replacementIdentity = [store sourceIdentityTokenForSourcePath:path];
        [store setCredential:credential forSourcePath:path];
        CHECK(![[store cacheTokenForSourcePath:path] isEqualToString:replacementToken],
              "credential replacement did not invalidate worker cache token");
        CHECK([[store sourceIdentityTokenForSourcePath:path] isEqualToString:replacementIdentity],
              "credential replacement changed the source identity token");

        [store invalidateCredentialForSourcePath:path];
        CHECK([store credentialForSourcePath:path] == nil, "explicit invalidation failed");
        [NSFileManager.defaultManager removeItemAtPath:path.stringByDeletingLastPathComponent error:nil];
        [store removeAllCredentials];

        test_password_sheet_retry_success_and_cancel();
    }
    if (failures) return 1;
    puts("SPDF mac password-store tests passed");
    return 0;
}
