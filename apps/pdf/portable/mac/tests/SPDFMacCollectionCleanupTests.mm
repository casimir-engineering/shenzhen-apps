#import <Foundation/Foundation.h>
#import "SPDFMacCollectionStorePrivate.h"
#import <sys/stat.h>
static int failures;
static void Check(BOOL pass,NSString* name) { if (!pass) { ++failures; fprintf(stderr,"FAIL %s\n",name.UTF8String); } }
static void Put(NSURL* URL,NSData* bytes) {
    [NSFileManager.defaultManager createDirectoryAtURL:URL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    Check([bytes writeToURL:URL atomically:YES],@"fixture written");
}
static NSData* Bytes(NSString* value) { return [value dataUsingEncoding:NSUTF8StringEncoding]; }
static NSMutableDictionary* Version(NSURL* root,NSString* ID,NSString* hash,NSInteger date,BOOL keep) {
    Put([[root URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:hash],Bytes(@"0123456789"));
    NSString* index=[ID stringByAppendingString:@".json"];
    Put([[root URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:index],Bytes(@"{}"));
    return [@{@"id":ID,@"hash":hash,@"size":@10,@"indexFile":index,@"capturedAt":@(date),@"keep":@(keep),@"assets":@[]} mutableCopy];
}
static NSMutableDictionary* Doc(NSString* ID,NSInteger opens,NSInteger last,NSArray* versions) {
    return [@{@"id":ID,@"title":ID,@"path":[@"/original/" stringByAppendingString:ID],
        @"openCount":@(opens),@"lastOpenedAt":@(last),@"versions":[versions mutableCopy],
        @"latestVersionID":versions.lastObject[@"id"],@"capturedAt":versions.lastObject[@"capturedAt"]} mutableCopy];
}
static void Save(NSURL* root,NSDictionary* docs) {
    Put([root URLByAppendingPathComponent:@"manifest.json"],[NSJSONSerialization dataWithJSONObject:
        @{@"format":@1,@"settings":@{@"choice":@"enabled"},@"documents":docs} options:0 error:nil]);
}
static NSString* IDs(NSDictionary* plan) { return [[plan[@"removals"] valueForKey:@"versionID"] componentsJoinedByString:@","]; }
static void Wait(BOOL (^done)(void)) {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:8];
    while (!done() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(done(),@"async capture completed");
}
static NSDictionary* OpenCapture(SPDFMacCollectionStore* store,NSString* path,NSString* documentID,NSUInteger count) {
    __block NSDictionary* result=nil;
    [store capturePath:path reason:@"Explicit opened" continuingDocumentID:documentID userOpenCount:count
          completion:^(NSDictionary* doc,NSError* error,BOOL recorded) {
              result=@{@"document":doc ?: @{},@"recorded":@(recorded),@"error":error ?: NSNull.null};
              Check(NSThread.isMainThread,@"counted completion is on main queue");
          }];
    Wait(^BOOL { return result!=nil; }); return result;
}
@interface CountRetryCollectionStore : SPDFMacCollectionStore
@property NSString* changeBeforeCommitPath;
@property NSString* changeAfterCommitPath;
@property BOOL failAfterCommit;
@property BOOL forceFailure;
@end
@implementation CountRetryCollectionStore
- (NSDictionary*)capturePath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID error:(NSError**)error {
    if (self.forceFailure) { if(error)*error=SPDFCollectionError(4,@"Injected permanent retry failure"); return nil; }
    return [super capturePath:path reason:reason continuingDocumentID:documentID error:error];
}
- (void)recordFingerprints:(NSMutableDictionary*)doc source:(NSDictionary*)source dependencies:(NSDictionary*)dependencies {
    if (self.changeBeforeCommitPath) {
        [@"changed before commit" writeToFile:self.changeBeforeCommitPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        self.changeBeforeCommitPath=nil;
    }
    [super recordFingerprints:doc source:source dependencies:dependencies];
}
- (BOOL)transaction:(BOOL (^)(NSMutableDictionary*,NSError**))body error:(NSError**)error {
    BOOL ok=[super transaction:body error:error];
    if (ok && self.changeAfterCommitPath) {
        [@"changed after commit" writeToFile:self.changeAfterCommitPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
        self.changeAfterCommitPath=nil;
        if (self.failAfterCommit) self.forceFailure=YES;
    }
    return ok;
}
@end
@interface FailingCollectionStore : SPDFMacCollectionStore
@property BOOL failInstall;
@property BOOL failCommit;
@end
@implementation FailingCollectionStore
- (BOOL)transaction:(BOOL (^)(NSMutableDictionary*, NSError**))body error:(NSError**)error {
    if (!self.failCommit) return [super transaction:body error:error];
    self.failCommit=NO;
    return [super transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        if (!body(manifest,failure)) return NO;
        if (failure) *failure=SPDFCollectionError(99,@"Injected manifest commit failure");
        return NO;
    } error:error];
}
- (BOOL)installBytes:(NSData*)data hash:(NSString*)hash error:(NSError**)error {
    if (self.failInstall) { if(error)*error=SPDFCollectionError(99,@"Injected write failure"); return NO; }
    return [super installBytes:data hash:hash error:error];
}
@end
#import "SPDFMacCollectionCapacityChecks.h"
int main(void) { @autoreleasepool {
    NSURL* sandbox=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    NSURL* root=[sandbox URLByAppendingPathComponent:@"Collection"];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    Check([[store settings][@"storageMode"] isEqual:@"dynamic"] && store.isStorageLimited,@"default dynamic storage");
    CapacityChecks(sandbox);
    [store previewStorageLimit:1]; [store recordUserOpenForDocumentID:@"absent" error:nil]; [store storageUsedBytes];
    Check(![NSFileManager.defaultManager fileExistsAtPath:root.path],@"unused previews, counters and reads create nothing");
    NSMutableDictionary* a=Doc(@"a",0,1,@[Version(root,@"a1",@"a1",1,NO),Version(root,@"a2",@"a2",2,NO),Version(root,@"a3",@"a3",3,NO)]);
    NSMutableDictionary* b=Doc(@"b",1,1,@[Version(root,@"b1",@"b1",1,NO),Version(root,@"b2",@"b2",2,NO)]);
    Save(root,@{@"a":a,@"b":b});
    Check(store.storageUsedBytes==60,@"objects and indexes count exact bytes");
    NSDictionary* first=[store previewStorageLimit:48];
    Check([IDs(first) isEqual:@"a1"],@"oldest version of least opened first");
    Check([IDs([store previewStorageLimit:24]) isEqual:@"a1,a2,b1"],@"all old versions removed before final copies");
    Check([IDs([store previewStorageLimit:12]) isEqual:@"a1,a2,b1,a3"],@"last copies follow same least opened order");
    Check([store versionsForDocumentID:@"a"].count==3 && store.storageUsedBytes==60,@"preview is read only");
    SPDFMacCollectionStore* second=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    [second recordUserOpenForDocumentID:@"a" error:nil];
    NSError* stale=nil;
    Check(![store applyStorageLimit:48 reviewedPlan:first error:&stale] && stale.code==20,@"another window invalidates reviewed cleanup");
    Check([store versionsForDocumentID:@"a"].count==3,@"stale cleanup leaves histories untouched");
    Check([IDs([store previewStorageLimit:48]) isEqual:@"b1"],@"oldest last open breaks count ties");
    [second recordUserOpenForDocumentID:@"a" error:nil];
    Check([IDs([store previewStorageLimit:48]) isEqual:@"b1"],@"fewer opens outranks recency");
    NSDictionary* revised=[store previewStorageLimit:48];
    Check([store applyStorageLimit:48 reviewedPlan:revised error:nil],@"reviewed cap applies");
    Check(store.storageUsedBytes==48 && [store versionsForDocumentID:@"b"].count==1,@"pruned references and bytes agree");
    Check(![NSFileManager.defaultManager fileExistsAtPath:[[root URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:@"b1"].path],@"unreferenced objects collected after commit");
    Check(![NSFileManager.defaultManager fileExistsAtPath:[[root URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:@"b1.json"].path],@"unreferenced indexes collected");
    Check([second.settings[@"storageLimitBytes"] unsignedLongLongValue]==48,@"cap visible to another instance");
    [store setKeep:YES versionID:@"a1" documentID:@"a" error:nil];
    NSDictionary* blocked=[store previewStorageLimit:1];
    Check(![blocked[@"canApply"] boolValue] && ![store applyStorageLimit:1 reviewedPlan:blocked error:nil],@"protected capacity fails before deleting anything");
    Check([store versionsForDocumentID:@"a"].count==3 && [store versionsForDocumentID:@"b"].count==1,@"any kept version protects entire history on failure");
    Check([IDs([store previewStorageLimit:36]) isEqual:@"b2"],@"kept history older versions never evicted");
    NSDictionary* unlimited=[store previewStorageLimit:0];
    Check([IDs(unlimited) isEqual:@""] && [store applyStorageLimit:0 reviewedPlan:unlimited error:nil],@"unlimited keeps every version");
    // Shared document bytes, shared asset bytes and individual text indexes.
    NSURL* shared=[sandbox URLByAppendingPathComponent:@"Shared"];
    NSMutableDictionary* s1=Version(shared,@"s1",@"same",1,NO);
    NSMutableDictionary* s2=Version(shared,@"s2",@"same",2,NO);
    Put([[shared URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:@"asset"],Bytes(@"asset"));
    s1[@"assets"]=@[@{@"hash":@"asset",@"size":@5}]; s2[@"assets"]=s1[@"assets"];
    Save(shared,@{@"s":Doc(@"s",0,0,@[s1,s2])});
    SPDFMacCollectionStore* sharedStore=[[SPDFMacCollectionStore alloc] initWithRootURL:shared];
    Check(sharedStore.storageUsedBytes==19,@"shared objects and assets only count once");
    NSDictionary* sharedPlan=[sharedStore previewStorageLimit:17];
    Check([sharedPlan[@"reclaimedBytes"] unsignedLongLongValue]==2 && [IDs(sharedPlan) isEqual:@"s1"],@"shared blob retained while unique index freed");
    Check([sharedStore applyStorageLimit:17 reviewedPlan:sharedPlan error:nil] && sharedStore.storageUsedBytes==17,@"shared retained byte accounting stays exact");
    Check([NSFileManager.defaultManager fileExistsAtPath:[[shared URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:@"asset"].path],@"shared asset survives cleanup");
    // Exercise real capture, including an incoming revision sharing an older blob.
    NSURL* live=[sandbox URLByAppendingPathComponent:@"Live"];
    FailingCollectionStore* capture=[[FailingCollectionStore alloc] initWithRootURL:live];
    [capture updateSettings:@{@"choice":@"enabled"} error:nil];
    NSURL* source=[sandbox URLByAppendingPathComponent:@"original.txt"];
    Put(source,Bytes(@"one original\n"));
    NSDictionary* captured=[capture capturePath:source.path reason:@"Opened" error:nil]; NSString* documentID=captured[@"id"];
    Check(captured!=nil,@"capture fixture");
    unsigned long long oneSize=capture.storageUsedBytes;
    Put(source,Bytes(@"two revision\n"));
    Check([capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil]!=nil,@"second capture");
    NSString* originalHash=[capture versionsForDocumentID:documentID].firstObject[@"hash"];
    // Direct setting simulates a restored older configuration; new captures still enforce it.
    [capture updateSettings:@{@"storageLimitBytes":@(oneSize)} error:nil];
    Put(source,Bytes(@"one original\n"));
    Check([capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil]!=nil,@"capture prunes old versions to fit");
    Check([capture versionsForDocumentID:documentID].count==1 && capture.storageUsedBytes==oneSize,@"incoming version survives both cleanup stages");
    Check([[capture versionsForDocumentID:documentID].lastObject[@"hash"] isEqual:originalHash],@"incoming deduplicated blob never deleted");
    Check([[NSData dataWithContentsOfURL:source] isEqual:Bytes(@"one original\n")],@"original source never modified by cleanup");
    NSArray* before=[capture versionsForDocumentID:documentID];
    Put(source,Bytes(@"A revision far larger than the tiny retained cap. This revision cannot fit. This revision cannot fit.\n"));
    Check(![capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil],@"oversized incoming snapshot blocked");
    Check([[capture versionsForDocumentID:documentID] isEqual:before],@"impossible capture never destructively prunes");
    Check([capture materializeVersionID:before.lastObject[@"id"] documentID:documentID error:nil]!=nil,@"old protected bytes remain readable after capacity failure");
    Put(source,Bytes(@"two revision\n"));
    capture.failCommit=YES;
    Check(![capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil],@"failed transaction after cleanup planning propagates");
    Check([[capture versionsForDocumentID:documentID] isEqual:before] && capture.storageUsedBytes==oneSize,
          @"cleanup plan never deletes files before successful manifest commit");
    capture.failInstall=YES;
    Check(![capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil],@"injected object write failure propagates");
    Check([[capture versionsForDocumentID:documentID] isEqual:before],@"IO failure never prunes earlier versions");
    [NSFileManager.defaultManager removeItemAtURL:source error:nil];
    Check(![capture capturePath:source.path reason:@"Saved" continuingDocumentID:documentID error:nil] &&
          [[capture versionsForDocumentID:documentID] isEqual:before],@"unavailable source retains all earlier versions");
    // Independent store locks serialize counters without dropping increments.
    __block int openFailures=0;
    dispatch_apply(20,dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^(size_t i) {
        SPDFMacCollectionStore* instance=[[SPDFMacCollectionStore alloc] initWithRootURL:live];
        if (![instance recordUserOpenForDocumentID:documentID error:nil]) @synchronized(capture) { ++openFailures; }
        (void)i;
    });
    NSDictionary* opened=nil; for(NSDictionary* row in capture.documents) if([row[@"id"] isEqual:documentID])opened=row;
    Check(openFailures==0 && [opened[@"openCount"] unsignedIntegerValue]==20,@"multi-instance explicit open counts persist without lost updates");
    // The incoming explicit open participates in the eviction ordering itself.
    NSURL* rankedRoot=[sandbox URLByAppendingPathComponent:@"OpenRank"];
    SPDFMacCollectionStore* rankedStore=[[SPDFMacCollectionStore alloc] initWithRootURL:rankedRoot];
    [rankedStore updateSettings:@{@"choice":@"enabled"} error:nil];
    NSString* pathA=[[sandbox URLByAppendingPathComponent:@"A.txt"] path];
    NSString* pathB=[[sandbox URLByAppendingPathComponent:@"B.txt"] path];
    [@"aaaaaaaaaa" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* docA=[rankedStore capturePath:pathA reason:@"Imported" error:nil];
    [@"bbbbbbbbbb" writeToFile:pathB atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* docB=[rankedStore capturePath:pathB reason:@"Imported" error:nil];
    [@"cccccccccc" writeToFile:pathB atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [rankedStore capturePath:pathB reason:@"Saved" continuingDocumentID:docB[@"id"] error:nil];
    [rankedStore recordUserOpenForDocumentID:docB[@"id"] error:nil];
    unsigned long long rankedLimit=rankedStore.storageUsedBytes;
    [rankedStore applyStorageLimit:rankedLimit reviewedPlan:[rankedStore previewStorageLimit:rankedLimit] error:nil];
    [@"dddddddddd" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* counted=OpenCapture(rankedStore,pathA,nil,1);
    Check([counted[@"recorded"] boolValue] && [counted[@"document"] count],@"explicit count commits with capture");
    Check([rankedStore versionsForDocumentID:docA[@"id"]].count==2 &&
          [rankedStore versionsForDocumentID:docB[@"id"]].count==1,@"opening A updates priority before pruning B's older version");
    counted=OpenCapture(rankedStore,pathA,nil,2);
    Check([counted[@"recorded"] boolValue] && [[rankedStore documentForPath:pathA][@"openCount"] unsignedIntegerValue]==3,
          @"fingerprint fast reuse counts batched opens exactly once");
    Check([rankedStore versionsForDocumentID:docA[@"id"]].count==2,@"counting reuse creates no revision");
    [rankedStore setExcluded:YES documentID:docA[@"id"] error:nil];
    counted=OpenCapture(rankedStore,pathA,nil,4);
    Check([counted[@"recorded"] boolValue] && ![counted[@"document"] count],@"excluded capture records successful reading before completion");
    if (![counted[@"recorded"] boolValue]) [rankedStore recordUserOpenCount:4 forDocumentID:docA[@"id"] error:nil];
    Check([[rankedStore documentForPath:pathA][@"openCount"] unsignedIntegerValue]==7,@"excluded worker fallback counts once without a new version");
    // A rollback may retry with the count; a committed capture may retry without it.
    CountRetryCollectionStore* retryStore=[[CountRetryCollectionStore alloc] initWithRootURL:[sandbox URLByAppendingPathComponent:@"CountRetries"]];
    [retryStore updateSettings:@{@"choice":@"enabled"} error:nil];
    [@"base retry" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* retryDoc=[retryStore capturePath:pathA reason:@"Imported" error:nil];
    [@"new retry" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    retryStore.changeBeforeCommitPath=pathA;
    counted=OpenCapture(retryStore,pathA,retryDoc[@"id"],1);
    Check([counted[@"recorded"] boolValue] && [[retryStore documentForPath:pathA][@"openCount"] unsignedIntegerValue]==1 &&
          [retryStore versionsForDocumentID:retryDoc[@"id"]].count==2,@"precommit failure rolls count back before automatic retry");
    [@"second retry" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    retryStore.changeAfterCommitPath=pathA;
    counted=OpenCapture(retryStore,pathA,retryDoc[@"id"],1);
    Check([counted[@"recorded"] boolValue] && [[retryStore documentForPath:pathA][@"openCount"] unsignedIntegerValue]==2 &&
          [retryStore versionsForDocumentID:retryDoc[@"id"]].count==4,@"postcommit retry retains exactly-once count metadata");
    [@"third retry" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    retryStore.changeAfterCommitPath=pathA; retryStore.failAfterCommit=YES;
    counted=OpenCapture(retryStore,pathA,retryDoc[@"id"],2);
    Check([counted[@"recorded"] boolValue] && ![counted[@"document"] count] && counted[@"error"]!=NSNull.null &&
          [[retryStore documentForPath:pathA][@"openCount"] unsignedIntegerValue]==4,
          @"completion reports committed count even when subsequent retry permanently fails");
    // A newer generation cannot discard an earlier explicit-open event.
    SPDFMacCollectionStore* queued=[[SPDFMacCollectionStore alloc] initWithRootURL:[sandbox URLByAppendingPathComponent:@"QueuedOpens"]];
    [queued updateSettings:@{@"choice":@"enabled"} error:nil];
    queued.captureQueue=[NSOperationQueue new]; queued.captureQueue.maxConcurrentOperationCount=1; queued.captureQueue.suspended=YES;
    __block NSUInteger completions=0;
    for (NSNumber* count in @[@1,@2])
        [queued capturePath:pathA reason:@"Explicit opened" continuingDocumentID:nil userOpenCount:count.unsignedIntegerValue
                completion:^(NSDictionary* row,NSError* error,BOOL recorded) {
                    Check(row && !error && recorded,@"superseded explicit request retains its count"); ++completions;
                }];
    [queued capturePath:pathA reason:@"Background" completion:^(NSDictionary* row,NSError* error) {
        (void)row;(void)error; ++completions;
    }];
    queued.captureQueue.suspended=NO;
    Wait(^BOOL { return completions==3; });
    Check([[queued documentForPath:pathA][@"openCount"] unsignedIntegerValue]==3 && queued.documents.count==1,
          @"separate superseded counted requests aggregate exactly once");
    queued.captureQueue.suspended=YES; completions=0;
    [queued capturePath:pathA reason:@"Explicit opened" continuingDocumentID:nil userOpenCount:2
        completion:^(NSDictionary* row,NSError* error,BOOL recorded) {
            (void)error; Check(!row && recorded,@"stale explicit job honors edit protection epoch but records reading");
            if (!recorded) [queued recordUserOpenCount:2 forDocumentID:[queued documentForPath:pathA][@"id"] error:nil];
            ++completions;
        }];
    [queued ensureProtectedPath:pathA reason:@"Edit gate" error:nil];
    queued.captureQueue.suspended=NO;
    Wait(^BOOL { return completions==1; });
    Check([[queued documentForPath:pathA][@"openCount"] unsignedIntegerValue]==5 && queued.documents.count==1,
          @"epoch cancellation records reading exactly once without splitting history");
    // Busy main thread: excluded A must count before the queued B watcher prunes.
    SPDFMacCollectionStore* excludedQueue=[[SPDFMacCollectionStore alloc] initWithRootURL:[sandbox URLByAppendingPathComponent:@"ExcludedOrdering"]];
    [excludedQueue updateSettings:@{@"choice":@"enabled"} error:nil];
    [@"aaaaaaaaaa" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* excludedA=[excludedQueue capturePath:pathA reason:@"Imported" error:nil];
    [@"bbbbbbbbbb" writeToFile:pathB atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* watchedB=[excludedQueue capturePath:pathB reason:@"Imported" error:nil];
    [@"cccccccccc" writeToFile:pathA atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [excludedQueue capturePath:pathA reason:@"Saved" continuingDocumentID:excludedA[@"id"] error:nil];
    [excludedQueue recordUserOpenForDocumentID:watchedB[@"id"] error:nil];
    unsigned long long excludedCap=excludedQueue.storageUsedBytes;
    [excludedQueue applyStorageLimit:excludedCap reviewedPlan:[excludedQueue previewStorageLimit:excludedCap] error:nil];
    [excludedQueue setExcluded:YES documentID:excludedA[@"id"] error:nil];
    completions=0;
    [excludedQueue capturePath:pathA reason:@"Explicit opened" continuingDocumentID:nil userOpenCount:1
        completion:^(NSDictionary* row,NSError* error,BOOL recorded) {
            (void)row;(void)error; Check(recorded,@"excluded open was counted on worker while main was busy");
            if (!recorded) [excludedQueue recordUserOpenCount:1 forDocumentID:excludedA[@"id"] error:nil];
            ++completions;
        }];
    [@"dddddddddd" writeToFile:pathB atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [excludedQueue capturePath:pathB reason:@"Observed save" continuingDocumentID:watchedB[@"id"]
        completion:^(NSDictionary* row,NSError* error) { Check(row && !error,@"watcher capture succeeds after excluded open"); ++completions; }];
    [excludedQueue.captureQueue waitUntilAllOperationsAreFinished];
    Check(completions==0 && [excludedQueue versionsForDocumentID:excludedA[@"id"]].count==2 &&
          [excludedQueue versionsForDocumentID:watchedB[@"id"]].count==1,
          @"excluded open updates eviction priority before callbacks or next worker cleanup");
    Wait(^BOOL { return completions==2; });
    Check([[excludedQueue documentForPath:pathA][@"openCount"] unsignedIntegerValue]==1,
          @"delayed main completion never double-counts excluded reading");
    SPDFMacCollectionStore* unused=[[SPDFMacCollectionStore alloc] initWithRootURL:[sandbox URLByAppendingPathComponent:@"UnusedCounted"]];
    counted=OpenCapture(unused,pathA,nil,3);
    [unused recordUserOpenCount:3 forDocumentID:@"absent" error:nil];
    Check(![counted[@"recorded"] boolValue] && !unused.captureQueue &&
          ![NSFileManager.defaultManager fileExistsAtPath:unused.rootURL.path],@"disabled counted opens allocate no queue or storage");
    [NSFileManager.defaultManager removeItemAtURL:sandbox error:nil];
    fprintf(stderr,"Collection cleanup: %s\n",failures ? "FAILED" : "passed"); return failures ? 1 : 0;
} }
