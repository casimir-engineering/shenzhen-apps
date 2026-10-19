#import "SPDFMacAgentIntegration.h"
#import "SPDFMacAgentCommand.h"
#import "SPDFMacAgentGroups.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "markdown/SPDFMarkdownModel.h"
#import <objc/runtime.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

@interface ShenzhenMacDelegate (SPDFMacAgentHost)
- (void)rememberActiveTabState;
- (void)goToPage:(NSInteger)page preserveSinglePagePosition:(BOOL)preserve;
- (void)jumpToFindMatchAtIndex:(NSInteger)index;
@end

static char activeRequestKey;
static void respond(NSString* path, NSDictionary* result) {
    // CLI cancellation/removal ends the request; never create a late response.
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    [data writeToFile:[path stringByAppendingPathExtension:@"response"] options:NSDataWritingAtomic error:nil];
}

@implementation ShenzhenMacDelegate (SPDFMacAgentIntegration)
- (void)acceptAgentCommandAtPath:(NSString*)path {
    NSString* directory = SPDFMacAgentRequestDirectory();
    if (![path.stringByDeletingLastPathComponent isEqual:directory] ||
        ![[NSUUID alloc] initWithUUIDString:path.lastPathComponent.stringByDeletingPathExtension]) return;
    struct stat parent;
    if (lstat(directory.fileSystemRepresentation, &parent) != 0 || !S_ISDIR(parent.st_mode) ||
        parent.st_uid != getuid() || (parent.st_mode & 0077)) return;
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (descriptor < 0) return;
    struct stat info;
    BOOL valid = fstat(descriptor, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
                 !(info.st_mode & 0077) && info.st_size > 0 && info.st_size <= 65536;
    NSMutableData* data = valid ? [NSMutableData dataWithLength:(NSUInteger)info.st_size] : nil;
    ssize_t count = valid ? read(descriptor, data.mutableBytes, data.length) : -1;
    close(descriptor);
    if (!valid || count != (ssize_t)data.length) return;
    NSError* error = nil;
    NSDictionary* command = SPDFMacValidateAgentCommand(data, &error);
    if (!command || [command[@"action"] isEqual:@"inspect"]) { respond(path, @{@"error":error.localizedDescription ?: @"Inspection runs headlessly through the CLI."}); return; }
    if (objc_getAssociatedObject(self, &activeRequestKey)) { respond(path, @{@"error":@"Another agent navigation is in progress."}); return; }
    NSMutableDictionary* state = [@{@"path":path, @"command":command, @"deadline":[NSDate dateWithTimeIntervalSinceNow:25], @"stage":@0} mutableCopy];
    objc_setAssociatedObject(self, &activeRequestKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{ [self advanceAgentNavigation:state]; });
}

- (void)finishAgentNavigation:(NSMutableDictionary*)state result:(NSDictionary*)result {
    respond(state[@"path"], result);
    objc_setAssociatedObject(self, &activeRequestKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)advanceAgentNavigation:(NSMutableDictionary*)state {
    if (objc_getAssociatedObject(self, &activeRequestKey) != state) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:state[@"path"]] || [state[@"deadline"] timeIntervalSinceNow] <= 0) {
        [self finishAgentNavigation:state result:@{@"error":@"Navigation timed out or was cancelled."}]; return;
    }
    NSDictionary* command = state[@"command"];
    NSInteger stage = [state[@"stage"] integerValue];
    if (_uiReady && stage == 0 && ![command[@"action"] isEqual:@"open"]) {
        [self finishAgentNavigation:state result:[self performAgentGroupCommand:command]]; return;
    }
    if (_uiReady && stage == 0) {
        BOOL directory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:command[@"path"] isDirectory:&directory] || directory) {
            [self finishAgentNavigation:state result:@{@"error":@"Document does not exist."}]; return;
        }
        [self openPaths:@[command[@"path"]]];
        state[@"stage"] = @1;
        // Cached Markdown installs defer viewport restoration to the main queue.
        // Let that finish before applying the requested reading position.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self advanceAgentNavigation:state]; });
        return;
    }
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? [self activeMarkdownSession] : nil;
    if (stage > 0 && session.state == SPDFMacMarkdownSessionFailed) {
        [self finishAgentNavigation:state result:@{@"error":@"Markdown failed to load. Check the document and its paper configuration."}]; return;
    }
    BOOL ready = [_path.stringByStandardizingPath isEqual:command[@"path"]] && (session ? session.isNavigationReady : _doc != NULL);
    if (stage > 0 && ![_path.stringByStandardizingPath isEqual:command[@"path"]]) {
        [self finishAgentNavigation:state result:@{@"error":@"Active document changed during navigation."}]; return;
    }
    if (ready && stage == 1) {
        NSInteger pageCount = session ? session.pageCount : spdf_page_count(_doc);
        NSInteger page = command[@"page"] ? [command[@"page"] integerValue] - 1 : -1;
        if (page >= pageCount) { [self finishAgentNavigation:state result:@{@"error":@"Page is outside the document."}]; return; }
        if (page >= 0) {
            if (session) [self markdownGoToPage:page];
            else [self goToPage:page preserveSinglePagePosition:NO];
        }
        if ([command[@"query"] length]) {
            _searchField.stringValue = command[@"query"];
            _findRegexCheckbox.state = NSControlStateValueOff;
            [self startFindForCurrentQueryResetSavedIndex:YES revealMatch:NO];
            state[@"stage"] = @2;
        } else { [self completeAgentNavigation:state page:page >= 0 ? page : (session ? session.currentPageIndex : _pageIndex) match:-1]; return; }
    } else if (ready && stage == 2 && !_findSearchInProgress) {
        if (![_searchField.stringValue isEqual:command[@"query"]]) { [self finishAgentNavigation:state result:@{@"error":@"Search changed during navigation."}]; return; }
        NSMutableArray* candidates = [NSMutableArray array];
        if (session) {
            for (SPDFMarkdownSearchMatch* match in session.searchMatches) {
                [candidates addObject:@{@"page":@([session pageIndexForRange:match.range] + 1), @"context":match.context ?: @""}];
            }
        } else {
            for (NSDictionary* match in _findMatches) [candidates addObject:@{@"page":@([match[@"page"] integerValue] + 1), @"context":match[@"context"] ?: @""}];
        }
        NSError* error = nil;
        NSInteger index = SPDFMacAgentChooseMatch(candidates, command, &error);
        if (index < 0) { [self finishAgentNavigation:state result:@{@"error":error.localizedDescription}]; return; }
        if (session) [session goToSearchMatchAtIndex:index];
        else [self jumpToFindMatchAtIndex:index];
        [self completeAgentNavigation:state page:[candidates[(NSUInteger)index][@"page"] integerValue] - 1 match:index]; return;
    }
    // Only explicit in-flight commands schedule work, bounded by their deadline.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self advanceAgentNavigation:state]; });
}

- (void)completeAgentNavigation:(NSMutableDictionary*)state page:(NSInteger)page match:(NSInteger)match {
    [self rememberActiveTabState];
    [self savePersistentState];
    [self activateWindowForExternalOpen];
    NSMutableDictionary* result = [@{@"path":_path ?: @"", @"page":@(page + 1), @"opened":@YES} mutableCopy];
    if (match >= 0) result[@"match"] = @(match + 1);
    [self finishAgentNavigation:state result:result];
}
@end
