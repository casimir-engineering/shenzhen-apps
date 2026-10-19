#import "SPDFMacCollectionStorePrivate.h"
@interface SPDFLiveRefreshProbeStore : SPDFMacCollectionStore
@property(nonatomic) dispatch_semaphore_t readStarted;
@property(nonatomic) dispatch_semaphore_t readRelease;
@end
@implementation SPDFLiveRefreshProbeStore
- (NSArray*)documents {
    dispatch_semaphore_t started, release;
    @synchronized(self) { started=self.readStarted; release=self.readRelease; self.readStarted=nil; self.readRelease=nil; }
    if (started) { dispatch_semaphore_signal(started); dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER); }
    return [super documents];
}
@end
static BOOL RefreshWait(BOOL (^condition)(void)) {
    NSDate* end=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!condition() && end.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    return condition();
}
static NSButton* CopyButton(NSView* view) {
    if ([view isKindOfClass:NSButton.class] && [[(NSButton*)view title] isEqual:@"Open collection copy"])
        return (NSButton*)view;
    for (NSView* child in view.subviews) { NSButton* found=CopyButton(child); if(found)return found; }
    return nil;
}
static void CheckCollectionLiveRefresh(void) {
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* root=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Collection"]];
    SPDFMacCollectionStore* reader=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    SPDFLiveRefreshProbeStore* helper=[[SPDFLiveRefreshProbeStore alloc] initWithRootURL:root];
    __block NSUInteger commits=0;
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:SPDFCollectionStoreDidChangeNotification
        object:reader queue:nil usingBlock:^(NSNotification* note) {
            (void)note; ++commits;
            // Notification is delivered after locks are released and durable data is readable.
            Expect(@"commit observers read committed history",reader.documents.count==1);
        }];
    [reader updateSettings:@{@"choice":@"enabled"} error:nil];
    Expect(@"settings and construction emit no document refresh",commits==0);
    NSString* path=[directory stringByAppendingPathComponent:@"Mail.pdf"];
    [PlainPDF() writeToFile:path atomically:YES];
    [reader transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)error;
        manifest[@"documents"][@"mail"]=[@{@"id":@"mail",@"path":path,@"title":@"Mail.pdf",
            @"status":@"Capture failed",@"versions":@[]} mutableCopy]; return YES;
    } error:nil];
    NSUInteger beforeFailure=commits;
    [reader transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)manifest;(void)error;return NO;
    } error:nil];
    Expect(@"failed transactions emit no refresh",commits==beforeFailure);
    SPDFMacCollectionWindow* manager=[[SPDFMacCollectionWindow alloc] initWithStore:helper open:^(NSString* path,BOOL archived) {
        (void)path;(void)archived;
    }];
    SPDFCollectionCompanionRuntime* runtime=[SPDFCollectionCompanionRuntime new];
    [runtime receive:@{@"kind":@"refresh"}];
    Expect(@"refresh never constructs the companion manager",[runtime valueForKey:@"manager"]==nil);
    [runtime setValue:manager forKey:@"manager"];
    [manager reload:nil];
    Expect(@"initial uncaptured Collection row loads",RefreshWait(^BOOL{return manager.hasLoadedResults && !manager.loadingResults;}));
    [manager.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    Expect(@"uncaptured row disables saved-copy action",!CopyButton([manager resultCellForRow:0]).enabled);
    [manager showDestination:@"Settings"];
    [manager.limitPicker selectItemAtIndex:1];
    [manager performSelector:@selector(changeLimitMode:) withObject:manager.limitPicker];
    manager.limitField.stringValue=@"77";
    [manager.window makeFirstResponder:manager.limitField];
    id responder=manager.window.firstResponder;
    dispatch_sync(manager.preferenceQueue,^{});
    NSDictionary* captured=[reader capturePath:path reason:@"Opened" error:nil];
    Expect(@"reader capture commits latest version",[captured[@"versions"] count]==1 && [captured[@"id"] isEqual:@"mail"]);
    Expect(@"different store instances do not silently refresh each other",!manager.rows.firstObject[@"version"][@"id"]);
    NSPipe* outgoing=[NSPipe pipe], *incoming=[NSPipe pipe];
    SPDFCollectionPipe* parent=[[SPDFCollectionPipe alloc] initWithReader:outgoing.fileHandleForReading writer:incoming.fileHandleForWriting];
    SPDFCollectionPipe* child=[[SPDFCollectionPipe alloc] initWithReader:incoming.fileHandleForReading writer:outgoing.fileHandleForWriting];
    __weak SPDFCollectionCompanionRuntime* weakRuntime=runtime;
    child.messageHandler=^(NSDictionary* message){[weakRuntime receive:message];};
    [parent start];[child start];
    [parent send:@{@"kind":@"refresh"}];
    Expect(@"pipe refresh updates visible row without reopening or activating",
        RefreshWait(^BOOL{return [manager.rows.firstObject[@"version"][@"id"] length]>0 && !manager.loadingResults;}));
    Expect(@"selection follows document when missing version becomes latest",
        manager.table.selectedRow==0 && [[manager selectedDocument][@"id"] isEqual:@"mail"]);
    Expect(@"saved-copy action becomes enabled",CopyButton([manager resultCellForRow:0]).enabled);
    Expect(@"refresh retains settings destination",[manager.destination isEqual:@"Settings"]);
    Expect(@"refresh retains pending settings input",[manager.limitField.stringValue isEqual:@"77"]);
    Expect(@"refresh retains first responder",manager.window.firstResponder==responder);
    NSUInteger generation=manager.generation;
    for(NSUInteger i=0;i<100;i++)[runtime receive:@{@"kind":@"refresh"}];
    Expect(@"refresh burst finishes",RefreshWait(^BOOL{return manager.generation>generation && !manager.loadingResults && !manager.storeRefreshPending;}));
    Expect(@"refresh burst coalesces into one reload",manager.generation==generation+1);
    generation=manager.generation;
    // Hold an actual store read in flight: commits must not start competing searches.
    dispatch_semaphore_t started=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0);
    @synchronized(helper) { helper.readStarted=started; helper.readRelease=release; }
    [manager reload:helper];
    __block BOOL began=NO;
    Expect(@"test has a real store read in flight",RefreshWait(^BOOL{if(!began)began=dispatch_semaphore_wait(started,DISPATCH_TIME_NOW)==0;return began;}));
    for(NSUInteger i=0;i<100;i++)[manager refreshFromStore];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
    Expect(@"in-flight refresh burst starts no competing search",manager.generation==generation+1 && manager.storeRefreshPending);
    dispatch_semaphore_signal(release);
    Expect(@"one trailing refresh drains pending changes",RefreshWait(^BOOL{return !manager.loadingResults && !manager.storeRefreshPending;}) &&
        manager.generation==generation+2);
    // Same-process fallback observes its own store and follows the next latest revision.
    [helper transaction:^BOOL(NSMutableDictionary* manifest,NSError** error) {
        (void)error; manifest[@"documents"][@"mail"][@"status"]=@"Protected again"; return YES;
    } error:nil];
    Expect(@"same-process manager refreshes committed store changes",
        RefreshWait(^BOOL{return [manager.rows.firstObject[@"document"][@"status"] isEqual:@"Protected again"] && !manager.loadingResults;}));
    dispatch_sync(manager.preferenceQueue,^{});
    generation=manager.generation;
    [helper updateSettings:@{@"managerQuery":@"persisted without reload"} error:nil];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Expect(@"manager preference writes never restart refresh",manager.generation==generation);
    Expect(@"live refresh never shows a window",!manager.window.visible);
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    [parent close];[child close];
    [manager.thumbnailQueue waitUntilAllOperationsAreFinished];
    dispatch_sync(manager.preferenceQueue,^{});
    [fm removeItemAtPath:directory error:nil];
}
