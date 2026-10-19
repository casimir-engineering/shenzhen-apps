// Scripted runner and environment for SPDFMacAIPythonTests, plus contexts and an activity that saves images into a
// throwaway folder. Every call is counted, so a check proves what reached them.
#pragma once
#import "SPDFPythonSandboxTestSupport.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIPythonResults.h"
#import "SPDFMacAIPythonToolProvider.h"
#import "SPDFMacAIRequestContext.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAIToolRegistry.h"

@interface FakeRunner : NSObject <SPDFMacAIPythonRunning>
@property NSMutableArray<NSDictionary*>* requests;
@property NSMutableArray<SPDFMacAIPythonRunCompletion>* pending;
@property(copy) NSDictionary* reply; // answered on the next main-queue turn when set; held in `pending` otherwise
@property NSUInteger stops;
@end
@implementation FakeRunner
- (instancetype)init {
    if ((self = [super init])) { _requests = [NSMutableArray array]; _pending = [NSMutableArray array]; }
    return self;
}
- (dispatch_block_t)runRequest:(NSDictionary*)request completion:(SPDFMacAIPythonRunCompletion)completion {
    [self.requests addObject:request];
    NSDictionary* reply = self.reply;
    if (reply) dispatch_async(dispatch_get_main_queue(), ^{ completion(reply); });
    else [self.pending addObject:completion];
    __weak FakeRunner* weakSelf = self;
    return ^{ weakSelf.stops++; };
}
@end

@interface FakeEnvironment : NSObject <SPDFMacAIPythonEnvironment>
@property(nonatomic, getter=isInstalled) BOOL installed; // each read counted in `checks`
@property NSUInteger checks;
@property(nonatomic, getter=isInstalling) BOOL installing;
@property(nonatomic, copy) NSString* interpreterPath;
@property NSUInteger installs, forgets;
@property(copy) void (^progress)(NSString*);
@property(copy) void (^completion)(NSString*);
@end
@implementation FakeEnvironment
@synthesize installed = _installed;
- (BOOL)isInstalled { self.checks++; return _installed; }
- (void)installWithProgress:(void (^)(NSString*))progress completion:(void (^)(NSString*))completion {
    self.installs++;
    self.installing = YES;
    self.progress = progress;
    self.completion = completion;
}
- (void)forgetInstallation { self.forgets++; self.installed = NO; }
@end

static NSString* gImages;

static SPDFMacAIChatActivity* FakeActivity(void) {
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    activity.anchor = ^NSUInteger { return 0; };
    activity.saveImage = ^NSDictionary*(NSDictionary* image) {
        NSString* saved = [gImages stringByAppendingPathComponent:
            [NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"png"]];
        if (![NSFileManager.defaultManager copyItemAtPath:image[@"path"] toPath:saved error:nil]) return nil;
        return @{@"path" : saved, @"caption" : image[@"caption"]};
    };
    return activity;
}

static SPDFMacAISettingsSnapshot* FakeSettings(BOOL python) {
    NSURL* url = [NSURL fileURLWithPath:[gImages stringByAppendingPathComponent:@"ai-settings.yaml"]];
    SPDFMacAISettings* settings = [[SPDFMacAISettings alloc] initWithURL:url];
    settings.aiPythonEnabled = python;
    return settings.snapshot;
}

static SPDFMacAIRequestContext* FakeContext(id<SPDFMacAIActivityReporting> activity, BOOL python, NSArray* chips) {
    return [[SPDFMacAIRequestContext alloc] initWithText:@"Plot the deliveries" chips:chips
                                                  origin:SPDFMacAIRequestOriginChat friendConversation:nil
                                                settings:FakeSettings(python) budget:nil activity:activity];
}

// Calls the provider and returns its result once the completion has run (on the main queue).
static NSDictionary* FakeCall(id<SPDFMacAIToolProvider> provider, NSDictionary* arguments,
                              SPDFMacAIRequestContext* context) {
    __block NSDictionary* result = nil;
    [provider performTool:SPDFMacAIPythonToolName arguments:arguments context:context
               completion:^(NSDictionary* answer) { result = answer; }];
    SandboxWait(^BOOL { return result != nil; });
    return result;
}

static NSArray<NSDictionary*>* FakeEntries(SPDFMacAIChatActivity* activity, NSString* kind) {
    return [activity.entries filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"%K == %@", SPDFMacAIActivityKindKey, kind]];
}

static NSString* FakeBase64(NSString* text) {
    return [[text dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
}

// A 2×2 PNG, as the helper returns one: base64 in "data".
static NSString* FakePNG(void) {
    static const uint8_t png[] = {
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x08, 0x02, 0x00, 0x00, 0x00, 0xfd, 0xd4, 0x9a, 0x73, 0x00, 0x00, 0x00,
        0x12, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x9f, 0x81, 0x81, 0x01, 0x00, 0x0c,
        0x0f, 0x02, 0x7f, 0x8d, 0x6a, 0x2b, 0x2b, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60,
        0x82};
    return [[NSData dataWithBytes:png length:sizeof png] base64EncodedStringWithOptions:0];
}
