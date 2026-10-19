#import "SPDFMacUnsavedImageClose.h"
#import "SPDFMacTabGroupIntegration.h"
static void Check(BOOL value, NSString* message) { if (!value) { NSLog(@"FAIL: %@", message); exit(1); } }
@implementation ShenzhenMacDelegate
@end
@interface CloseHost : ShenzhenMacDelegate
@property NSMutableArray<NSNumber*>* answers;
@property NSMutableArray<SPDFDocumentTab*>* testTabs;
@property NSUInteger prompts, saves, closes;
@property NSMutableArray* saveWaiters;
@property SPDFDocumentTab* savingTab;
@end
@implementation CloseHost
- (NSMutableDictionary*)sidebarWorkspaceState { return nil; }
- (NSMutableArray*)testTabs { return _tabs; }
- (void)setTestTabs:(NSMutableArray*)tabs { _tabs = tabs; }
- (NSModalResponse)promptToCloseUnsavedImage:(SPDFDocumentTab*)tab {
    (void)tab; self.prompts++;
    Check(self.answers.count > 0, @"no unplanned repeat prompt");
    NSInteger answer = self.answers.firstObject.integerValue; [self.answers removeObjectAtIndex:0]; return answer;
}
- (BOOL)waitForPendingImageSave:(void (^)(BOOL))completion {
    if (!self.saveWaiters) return NO;
    if (completion) [self.saveWaiters addObject:[completion copy]];
    return YES;
}
- (void)saveImageTab:(SPDFDocumentTab*)tab completion:(void (^)(BOOL))completion {
    if ([self waitForPendingImageSave:completion]) return;
    self.saves++; self.savingTab = tab; self.saveWaiters = [NSMutableArray array];
    if (completion) [self.saveWaiters addObject:[completion copy]];
}
- (void)finishSave:(BOOL)success {
    if (success) self.savingTab.path = @"/saved/image.png";
    NSArray* callbacks = [self.saveWaiters copy]; self.saveWaiters = nil;
    for (void (^callback)(BOOL) in callbacks) callback(success);
}
- (void)closeTabAtIndex:(NSInteger)index { [self closeTabAtIndex:index preferMostRecentActive:NO]; }
- (void)closeTabAtIndex:(NSInteger)index preferMostRecentActive:(BOOL)recent {
    if ([self deferClosingUnsavedImageAtIndex:index preferMostRecentActive:recent]) return;
    self.closes++; [self->_tabs removeObjectAtIndex:index];
}
@end
@interface CloseApplication : NSApplication
@property CloseHost* host;
@property NSUInteger requests;
@end
@implementation CloseApplication
- (void)terminate:(id)sender {
    (void)sender;
    if (![self.host deferUnsavedImageTermination]) self.requests++;
}
@end
static void Drain(void) {
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
}
static SPDFDocumentTab* Pasted(NSString* root) {
    SPDFDocumentTab* tab = [SPDFDocumentTab new];
    tab.path = [[root stringByAppendingPathComponent:@"Pasted Images"] stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Pasted Image %@.png", NSUUID.UUID.UUIDString]];
    return tab;
}
int main() { @autoreleasepool {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    setenv("SPDF_STATE_DIR", root.fileSystemRepresentation, 1);
    CloseHost* host = [CloseHost new]; host.answers = [NSMutableArray array];
    SPDFDocumentTab* tab = Pasted(root); host.testTabs = [@[tab] mutableCopy];
    [host.answers addObject:@(NSAlertThirdButtonReturn)];
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    Check(host.closes == 0 && host.testTabs.count == 1, @"Cancel preserves tab");
    [host.answers addObject:@(NSAlertFirstButtonReturn)];
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    Check(host.saves == 1 && host.closes == 0, @"save waits and duplicate close does not duplicate save");
    [host finishSave:NO];
    Check(host.testTabs.count == 1, @"save cancel or failure keeps tab open");
    [host.answers addObject:@(NSAlertFirstButtonReturn)];
    [host closeTabAtIndex:0 preferMostRecentActive:YES];
    SPDFDocumentTab* other = [SPDFDocumentTab new]; other.path = @"/saved/other.png";
    [host.testTabs insertObject:other atIndex:0];
    [host finishSave:YES];
    Check(host.closes == 1 && host.testTabs.count == 1 && host.testTabs[0] == other, @"save closes original identity after reorder");
    SPDFDocumentTab* discard = Pasted(root); [host.testTabs addObject:discard];
    [host.answers addObject:@(NSAlertSecondButtonReturn)];
    [host closeTabAtIndex:1 preferMostRecentActive:NO];
    Check(host.closes == 2 && host.testTabs.count == 1, @"Don't Save closes without saving or reprompting");
    Check(![host deferUnsavedImageTermination], @"ordinary saved image quits without warning");
    CloseApplication* app = [CloseApplication sharedApplication]; app.host = host;
    [host.testTabs addObject:Pasted(root)];
    [host.answers addObject:@(NSAlertThirdButtonReturn)];
    Check([host deferUnsavedImageTermination], @"quit defers with unsaved image");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    Check(app.requests == 0, @"cancel stops termination");
    [host.answers addObject:@(NSAlertSecondButtonReturn)];
    Check([host deferUnsavedImageTermination], @"quit can be tried again after cancel");
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
    Check(app.requests == 1, @"approved quit retries exactly once");
    // Quit must inspect live tabs again when its asynchronous save finishes.
    host.testTabs = [@[Pasted(root)] mutableCopy];
    NSUInteger requests = app.requests, prompts = host.prompts;
    [host.answers addObjectsFromArray:@[@(NSAlertFirstButtonReturn), @(NSAlertThirdButtonReturn)]];
    Check([host deferUnsavedImageTermination], @"quit awaits first image save"); Drain();
    SPDFDocumentTab* newPaste = Pasted(root); [host.testTabs addObject:newPaste];
    [host finishSave:YES];
    Check(app.requests == requests && host.prompts == prompts + 2 && newPaste.unsavedPastedImage,
        @"newly pasted tab receives its own warning and Cancel prevents quit");

    // Cmd-W then Cmd-Q joins the existing close flow, including its failure.
    host.testTabs = [@[Pasted(root)] mutableCopy]; prompts = host.prompts;
    [host.answers addObject:@(NSAlertFirstButtonReturn)];
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    Check([host deferUnsavedImageTermination], @"quit queues behind pending close save"); Drain();
    Check(host.prompts == prompts + 1 && app.requests == requests, @"quit never duplicates close save prompt");
    [host finishSave:NO]; Drain();
    Check(host.testTabs.count == 1 && app.requests == requests, @"failed close save cancels queued quit");
    [host.answers addObject:@(NSAlertFirstButtonReturn)];
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    Check([host deferUnsavedImageTermination], @"quit can queue after prior save failure");
    [host finishSave:YES]; Drain();
    Check(host.testTabs.count == 0 && app.requests == ++requests, @"successful close save retries quit once");

    // A regular Save As is already exporting before either close or quit starts.
    SPDFDocumentTab* manual = Pasted(root); host.testTabs = [@[manual] mutableCopy];
    [host saveImageTab:manual completion:nil]; prompts = host.prompts;
    [host closeTabAtIndex:0 preferMostRecentActive:NO];
    Check(host.prompts == prompts && host.testTabs.count == 1, @"close waits for manual Save As without prompting");
    [host finishSave:NO];
    Check(host.testTabs.count == 1 && manual.unsavedPastedImage, @"manual Save As failure preserves pending close tab");
    [host saveImageTab:manual completion:nil];
    [host closeTabAtIndex:0 preferMostRecentActive:NO]; [host finishSave:YES];
    Check(host.testTabs.count == 0 && host.prompts == prompts, @"successful manual Save As allows close without warning");
    manual = Pasted(root); host.testTabs = [@[manual] mutableCopy];
    [host saveImageTab:manual completion:nil];
    Check([host deferUnsavedImageTermination], @"quit waits for manual Save As"); Drain();
    Check(app.requests == requests && host.prompts == prompts, @"pending manual export cannot be terminated or reprompted");
    [host finishSave:NO];
    Check(app.requests == requests, @"failed manual export cancels quit");
    [host saveImageTab:manual completion:nil];
    Check([host deferUnsavedImageTermination], @"quit retries after manual export failure"); Drain();
    [host finishSave:YES];
    Check(app.requests == ++requests && host.prompts == prompts, @"successful manual export completes queued quit");
    [host saveImageTab:manual completion:nil]; // already-saved source still has an active export
    Check([host deferUnsavedImageTermination], @"quit waits even when exporting an ordinary saved image"); Drain();
    Check(app.requests == requests, @"ordinary image export stays alive until completion");
    [host finishSave:YES]; Check(app.requests == ++requests, @"ordinary image export completion allows quit");

    // Exercise production closeTabGroup: with its captured membership action.
    SPDFTabGroup* group = [SPDFTabGroup groupWithColor:@"Blue"];
    SPDFDocumentTab* batchImage = Pasted(root); other.group = group; batchImage.group = group;
    host.testTabs = [@[other, batchImage] mutableCopy];
    [host.answers addObject:@(NSAlertThirdButtonReturn)];
    [host closeTabGroup:group];
    Check(host.testTabs.count == 2, @"Cancel leaves every group member open");
    [host.answers addObject:@(NSAlertFirstButtonReturn)];
    [host closeTabGroup:group];
    newPaste = Pasted(root); newPaste.group = group; [host.testTabs addObject:newPaste];
    [host finishSave:YES];
    Check(host.testTabs.count == 1 && host.testTabs[0] == newPaste,
        @"production group close preserves a newly added unapproved member");

    // Don't Save approval cannot carry over when that same tab changes source.
    SPDFDocumentTab* accepted = Pasted(root); SPDFDocumentTab* saving = Pasted(root);
    host.testTabs = [@[accepted, saving] mutableCopy]; prompts = host.prompts;
    [host.answers addObjectsFromArray:@[@(NSAlertSecondButtonReturn), @(NSAlertFirstButtonReturn), @(NSAlertThirdButtonReturn)]];
    Check([host deferUnsavedImageTermination], @"quit begins multi-image approval"); Drain();
    accepted.path = Pasted(root).path; [host finishSave:YES];
    Check(host.prompts == prompts + 3 && app.requests == requests,
        @"changed source invalidates prior Don't Save approval");
    Check(host.answers.count == 0, @"every scripted answer was consumed");
    Check(![NSFileManager.defaultManager fileExistsAtPath:root], @"close policy creates no storage");
    NSLog(@"Unsaved image close tests passed");
} return 0; }
