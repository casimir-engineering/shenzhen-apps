#import "SPDFMacAgentIntegration.h"
#import "SPDFMacAgentCommand.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import <sys/stat.h>
#import <objc/runtime.h>
#include <assert.h>

// Headless host contract. The real agent category drives these host methods;
// no NSApplication, window, document engine or installed app is launched.
static NSString* supportDirectory;
static NSInteger visiblePage, savedPage;
static BOOL markdown, loading;
static NSUInteger groupRequests;
static SPDFMacMarkdownSession* cachedSession;
NSString* spdf_mac_support_directory(void) { return supportDirectory; }
int spdf_page_count(spdf_document* doc) { (void)doc; return 8; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wobjc-property-implementation"
@implementation SPDFMacMarkdownSession
- (SPDFMacMarkdownSessionState)state { return loading ? SPDFMacMarkdownSessionLoading : SPDFMacMarkdownSessionReady; }
- (BOOL)isNavigationReady { return !loading; }
- (NSUInteger)pageCount { return 8; }
- (NSInteger)currentPageIndex { return visiblePage; }
@end

@implementation ShenzhenMacDelegate
- (instancetype)init {
    if ((self = [super init])) {
        _uiReady = YES;
        _searchField = [NSSearchField new];
        _findRegexCheckbox = [NSButton new];
        _findMatches = [NSMutableArray array];
    }
    return self;
}
- (NSDictionary*)performAgentGroupCommand:(NSDictionary*)command {
    assert([command[@"action"] isEqual:@"list-groups"]); groupRequests++;
    return @{@"groups":@[],@"tabs":@[]};
}
- (BOOL)isMarkdownActive { return markdown; }
- (SPDFMacMarkdownSession*)activeMarkdownSession { return cachedSession; }
- (void)openPaths:(NSArray<NSString*>*)paths {
    _path = paths.firstObject;
    _doc = markdown ? NULL : (spdf_document*)1;
    // This is the real cached-tab ordering: readiness precedes queued restore.
    dispatch_async(dispatch_get_main_queue(), ^{ visiblePage = 1; });
}
- (void)markdownGoToPage:(NSInteger)page { visiblePage = page; }
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve { (void)preserve; visiblePage = page; }
- (void)rememberActiveTabState { savedPage = visiblePage; }
- (void)savePersistentState {}
- (void)activateWindowForExternalOpen {}
- (void)startFindForCurrentQueryResetSavedIndex:(BOOL)reset revealMatch:(BOOL)reveal {
    (void)reset; assert(!reveal);
    _findSearchInProgress = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self->_findMatches addObjectsFromArray:@[@{@"page":@2, @"context":@"first quote"},
                                                  @{@"page":@4, @"context":@"target quote"}]];
        self->_findSearchInProgress = NO;
    });
}
- (void)jumpToFindMatchAtIndex:(NSInteger)index { visiblePage = [_findMatches[(NSUInteger)index][@"page"] integerValue]; }
@end
#pragma clang diagnostic pop

static NSString* writeRequest(NSDictionary* command) {
    NSString* path = [SPDFMacAgentRequestDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"spdf-command"]];
    NSData* data = [NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    assert([data writeToFile:path atomically:YES]);
    chmod(path.fileSystemRepresentation, 0600);
    return path;
}
static NSDictionary* response(NSString* path) {
    NSString* reply = [path stringByAppendingPathExtension:@"response"];
    NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:3];
    while (![NSFileManager.defaultManager fileExistsAtPath:reply] && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    NSData* data = [NSData dataWithContentsOfFile:reply];
    assert(data);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
int main(void) {
    @autoreleasepool {
        supportDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:SPDFMacAgentRequestDirectory() withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]);
        NSString* doc = [supportDirectory stringByAppendingPathComponent:@"fixture.md"];
        assert([@"# Fixture" writeToFile:doc atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        cachedSession = (SPDFMacMarkdownSession*)class_createInstance(SPDFMacMarkdownSession.class, 0);
        markdown = YES;
        visiblePage = savedPage = 0;
        ShenzhenMacDelegate* host = [ShenzhenMacDelegate new];
        NSString* request = writeRequest(@{@"action":@"open", @"path":doc, @"page":@6});
        [host acceptAgentCommandAtPath:request];
        NSDictionary* result = response(request);
        assert([result[@"page"] integerValue] == 6 && !result[@"error"]);
        assert(visiblePage == 5 && savedPage == 5); // queued cached restore cannot win

        loading = YES;
        NSString* delayed = writeRequest(@{@"action":@"open", @"path":doc, @"page":@3});
        [host acceptAgentCommandAtPath:delayed];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ loading = NO; });
        assert([response(delayed)[@"page"] integerValue] == 3 && savedPage == 2);

        NSString* invalid = writeRequest(@{@"action":@"open", @"path":doc, @"page":@99});
        [host acceptAgentCommandAtPath:invalid];
        assert(response(invalid)[@"error"]);

        markdown = NO;
        NSString* search = writeRequest(@{@"action":@"open", @"path":doc, @"query":@"quote", @"context":@"target"});
        [host acceptAgentCommandAtPath:search];
        result = response(search);
        assert([result[@"page"] integerValue] == 5 && [result[@"match"] integerValue] == 2 && savedPage == 4);

        loading = YES; markdown = YES;
        NSString* first = writeRequest(@{@"action":@"open", @"path":doc, @"page":@2});
        NSString* second = writeRequest(@{@"action":@"open", @"path":doc, @"page":@3});
        [host acceptAgentCommandAtPath:first];
        [host acceptAgentCommandAtPath:second];
        assert(response(second)[@"error"]); // no interleaved commands
        NSString* busyGroups=writeRequest(@{@"action":@"list-groups"});
        [host acceptAgentCommandAtPath:busyGroups];
        assert(response(busyGroups)[@"error"] && groupRequests==0);
        [NSFileManager.defaultManager removeItemAtPath:first error:nil];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        loading = NO;
        NSString* afterCancel = writeRequest(@{@"action":@"open", @"path":doc, @"page":@4});
        [host acceptAgentCommandAtPath:afterCancel];
        assert([response(afterCancel)[@"page"] integerValue] == 4);
        NSString* groups=writeRequest(@{@"action":@"list-groups"});
        [host acceptAgentCommandAtPath:groups];
        assert(response(groups)[@"groups"] && groupRequests==1 && savedPage==3);
        [NSFileManager.defaultManager removeItemAtPath:supportDirectory error:nil];
        puts("SPDFMacAgentNavigationTests passed");
    }
}
