#import "SPDFMacCollectionImport.h"
@interface SPDFImportTestStore : SPDFMacCollectionStore
@property NSMutableSet* denied;
@property BOOL statDenied;
@property BOOL failStorage;
@property BOOL failRelease;
@end
@implementation SPDFImportTestStore
- (BOOL)hasImportCopy:(NSString*)path {
    NSDictionary* context=NSThread.currentThread.threadDictionary[[NSString stringWithFormat:@"SPDFCollectionCapture.%p",self]];
    return [context[@"path"] isEqual:SPDFCollectionPath(path)] && context[@"userOpenState"][@"authorizedCopy"]!=nil;
}
- (NSDictionary*)captureLockedPath:(NSString*)path reason:(NSString*)reason continuingDocumentID:(NSString*)documentID
                         manifest:(NSMutableDictionary*)manifest error:(NSError**)error {
    if (self.statDenied && [self.denied containsObject:path] && ![self hasImportCopy:path]) {
        if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EACCES userInfo:nil]; return nil;
    }
    return [super captureLockedPath:path reason:reason continuingDocumentID:documentID manifest:manifest error:error];
}
- (NSData*)readCaptureBytesForPath:(NSString*)path error:(NSError**)error {
    if ([self.denied containsObject:path] && ![self hasImportCopy:path]) {
        if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:nil]; return nil;
    }
    return [super readCaptureBytesForPath:path error:error];
}
- (BOOL)installBytes:(NSData*)bytes hash:(NSString*)hash error:(NSError**)error {
    if (self.failStorage) { if(error)*error=SPDFCollectionError(EIO,@"Collection could not durably save the revision."); return NO; }
    return [super installBytes:bytes hash:hash error:error];
}
- (BOOL)transaction:(BOOL (^)(NSMutableDictionary*,NSError**))body error:(NSError**)error {
    return [super transaction:^BOOL(NSMutableDictionary* m,NSError** failure) {
        BOOL leased=m[@"settings"][@"initialImportOwner"]!=nil;
        BOOL result=body(m,failure);
        if (self.failRelease && leased && !m[@"settings"][@"initialImportOwner"]) {
            if(failure)*failure=SPDFCollectionError(EIO,@"Injected lease-release storage failure"); return NO;
        }
        return result;
    } error:error];
}
@end
static void AwaitImport(BOOL (^condition)(void)) {
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:8];
    while(!condition() && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"import asynchronous step completes",condition());
}
static SPDFImportTestStore* ImportStore(NSString* sandbox,NSString* name) {
    SPDFImportTestStore* store=[[SPDFImportTestStore alloc] initWithRootURL:
        [NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:name]]];
    store.denied=[NSMutableSet set];
    Expect(@"constructing initial-import store creates no queue or folder",!store.captureQueue &&
        ![NSFileManager.defaultManager fileExistsAtPath:store.rootURL.path]);
    [store updateSettings:@{@"choice":@"enabled"} error:nil]; return store;
}
static NSString* ImportSource(NSString* sandbox,NSString* name) {
    NSString* path=[sandbox stringByAppendingPathComponent:name];
    [@"Collection import fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; return path;
}
static void CheckCollectionInitialImport(void) {
    NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* denied=ImportSource(sandbox,@"Safari.pdf"), *readable=ImportSource(sandbox,@"Readable.txt");
    SPDFImportTestStore* store=ImportStore(sandbox,@"GrantStore"); [store.denied addObject:denied];
    [store capturePath:denied reason:@"Previous failed import" error:nil];
    __block SPDFCollectionImportReply pending; __block NSURL* destination;
    __block BOOL finished=NO; __block NSUInteger prompts=0;
    [store importRecentPaths:@[readable] recovery:^(NSString* path,NSURL* target,SPDFCollectionImportReply reply) {
        Expect(@"permission is requested for exact failed original on main",NSThread.isMainThread && [path isEqual:denied]);
        ++prompts; pending=[reply copy]; destination=target;
    } completion:^(NSError* error){Expect(@"authorized initial build succeeds",!error);finished=YES;}];
    AwaitImport(^BOOL{return pending!=nil;});
    Expect(@"import waits for validation before advancing or completing",!finished && ![store settings][@"initialImportVersion"] &&
        [store settings][@"initialImportOwner"] && ![store documentForPath:readable] &&
        [store documentForPath:denied] && prompts==1);
    Expect(@"temporary authorization storage is private",([[fm attributesOfItemAtPath:destination.URLByDeletingLastPathComponent.path error:nil][NSFilePosixPermissions] unsignedIntValue]&0777)==0700);
    SPDFMacCollectionStore* other=[[SPDFMacCollectionStore alloc] initWithRootURL:store.rootURL];
    __block BOOL otherFinished=NO;
    [other importRecentPaths:@[denied] recovery:^(NSString* p,NSURL* u,SPDFCollectionImportReply r){(void)p;(void)u;(void)r;Expect(@"other process owner cannot ask duplicate permission",NO);}
        completion:^(NSError* error){Expect(@"live durable owner remains exclusive",error.code==24);otherFinished=YES;}];
    AwaitImport(^BOOL{return otherFinished;});
    Expect(@"another importer cannot mark pending owner complete",![store settings][@"initialImportVersion"]);
    Expect(@"picker rejects different files and remote URLs",SPDFCollectionImportURLMatchesSource([NSURL fileURLWithPath:denied],denied) &&
        !SPDFCollectionImportURLMatchesSource([NSURL fileURLWithPath:readable],denied) &&
        !SPDFCollectionImportURLMatchesSource([NSURL URLWithString:@"https://example.test/Safari.pdf"],denied));
    SPDFReadOnlyCopyResolution copy=SPDFResolveReadOnlyCopy(denied,destination.path,nil,nil);
    pending(CopyHint(copy),NO,nil); pending=nil;
    AwaitImport(^BOOL{return finished;});
    Expect(@"grant captures both documents and commits final marker only afterward",[store documents].count==2 &&
        [[store documentForPath:denied][@"versions"] count]==1 && [[store documentForPath:readable][@"versions"] count]==1 &&
        [[store settings][@"initialImportVersion"] integerValue]==1 && ![store settings][@"initialImportOwner"] &&
        ![fm fileExistsAtPath:destination.URLByDeletingLastPathComponent.path]);
    __block BOOL repeated=NO;
    [other importRecentPaths:@[@"/nonexistent/new-recent.pdf"] recovery:nil completion:^(NSError* error){Expect(@"completed build is not repeated",!error);repeated=YES;}];
    Expect(@"durable completion prevents scan and queue allocation",repeated && !other.captureQueue);

    NSString* a=ImportSource(sandbox,@"DeniedA.txt"), *b=ImportSource(sandbox,@"DeniedB.txt");
    SPDFImportTestStore* skip=ImportStore(sandbox,@"SkipStore"); [skip.denied addObjectsFromArray:@[a,b]]; skip.statDenied=YES;
    NSString* kept=ImportSource(sandbox,@"Kept.txt"); NSDictionary* saved=[skip capturePath:kept reason:@"Opened" error:nil];
    [fm removeItemAtPath:kept error:nil];
    __block BOOL skipped=NO; __block NSUInteger skipPrompts=0;
    [skip importRecentPaths:@[a,b,kept,@"/nonexistent/missing.pdf"] recovery:^(NSString* path,NSURL* target,SPDFCollectionImportReply reply) {
        (void)path;(void)target;++skipPrompts;reply(nil,YES,nil);
    } completion:^(NSError* error){Expect(@"skipping inaccessible originals finishes cleanly",!error);skipped=YES;}];
    AwaitImport(^BOOL{return skipped;});
    Expect(@"stat permission denial asks once; Skip remaining prunes empty rows only",skipPrompts==1 &&
        ![skip documentForPath:a] && ![skip documentForPath:b] && ![skip documentForPath:@"/nonexistent/missing.pdf"] &&
        [skip versionsForDocumentID:saved[@"id"]].count==1 && skip.documents.count==1);

    SPDFImportTestStore* raced=ImportStore(sandbox,@"RaceStore"); [raced.denied addObject:a];
    __block SPDFCollectionImportReply raceReply; __block BOOL raceDone=NO;
    [raced importRecentPaths:@[a] recovery:^(NSString* p,NSURL* u,SPDFCollectionImportReply r){(void)p;(void)u;raceReply=[r copy];}
        completion:^(NSError* error){Expect(@"concurrent saved history survives skip",!error);raceDone=YES;}];
    AwaitImport(^BOOL{return raceReply!=nil;});
    SPDFMacCollectionStore* writer=[[SPDFMacCollectionStore alloc] initWithRootURL:raced.rootURL];
    [writer capturePath:a reason:@"Another window opened it" error:nil]; raceReply(nil,NO,nil); raceReply=nil;
    AwaitImport(^BOOL{return raceDone;});
    Expect(@"under-lock prune preserves versions created while sheet awaited",[[raced documentForPath:a][@"versions"] count]==1);

    SPDFImportTestStore* replaced=ImportStore(sandbox,@"ReplacementStore");
    NSDictionary* oldHistory=[replaced capturePath:a reason:@"Original identity" error:nil];
    [@"Replacement identity at same path" writeToFile:a atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [replaced.denied addObject:a]; [replaced capturePath:a reason:@"Inaccessible new identity" error:nil];
    Expect(@"replacement fixture has saved old history and empty current failure",replaced.documents.count==2 &&
        [[replaced documentForPath:a][@"versions"] count]==0);
    __block BOOL replacedDone=NO; __block NSUInteger replacementPrompts=0;
    [replaced importRecentPaths:@[a] recovery:^(NSString* p,NSURL* u,SPDFCollectionImportReply r){(void)p;(void)u;++replacementPrompts;r(nil,NO,nil);}
        completion:^(NSError* error){Expect(@"replacement failed-row import completes",!error);replacedDone=YES;}];
    AwaitImport(^BOOL{return replacedDone;});
    Expect(@"saved replaced identity cannot hide current failure from permission recovery",replacementPrompts==1 &&
        ![replaced documentForPath:a] && replaced.documents.count==1 &&
        [replaced versionsForDocumentID:oldHistory[@"id"]].count==1);

    SPDFImportTestStore* disk=ImportStore(sandbox,@"DiskStore"); disk.failStorage=YES;
    __block BOOL diskDone=NO;
    [disk importRecentPaths:@[readable] recovery:^(NSString* p,NSURL* u,SPDFCollectionImportReply r){(void)p;(void)u;(void)r;Expect(@"destination failure must not request source permission",NO);}
        completion:^(NSError* error){Expect(@"destination failure pauses initial import",error.code==EIO);diskDone=YES;}];
    AwaitImport(^BOOL{return diskDone;});
    Expect(@"write EIO code5 is not mistaken for unavailable source",[disk documentForPath:readable] &&
        ![disk settings][@"initialImportVersion"] && ![disk settings][@"initialImportOwner"]);
    disk.failStorage=NO; diskDone=NO;
    [disk importRecentPaths:@[readable] recovery:nil completion:^(NSError* error){Expect(@"storage recovery retries same session",!error);diskDone=YES;}];
    AwaitImport(^BOOL{return diskDone;});
    Expect(@"retried import archives source",[[disk documentForPath:readable][@"versions"] count]==1);

    SPDFImportTestStore* disabled=ImportStore(sandbox,@"DisableStore"); [disabled.denied addObject:b];
    __block SPDFCollectionImportReply disableReply; __block BOOL disableDone=NO;
    [disabled importRecentPaths:@[b] recovery:^(NSString* p,NSURL* u,SPDFCollectionImportReply r){(void)p;(void)u;disableReply=[r copy];}
        completion:^(NSError* error){Expect(@"disabled import exits without error",!error);disableDone=YES;}];
    AwaitImport(^BOOL{return disableReply!=nil;});
    [disabled updateSettings:@{@"choice":@"disabled"} error:nil]; disableReply(nil,NO,nil); disableReply=nil;
    AwaitImport(^BOOL{return disableDone;});
    Expect(@"disable does not prune or mark incomplete import complete",[disabled documentForPath:b] &&
        ![disabled settings][@"initialImportVersion"] && ![disabled settings][@"initialImportOwner"]);

    SPDFImportTestStore* release=ImportStore(sandbox,@"ReleaseStore"); release.failRelease=YES;
    __block BOOL releaseDone=NO;
    [release importRecentPaths:@[readable] recovery:nil completion:^(NSError* error){Expect(@"lease write failure reported",error.code==EIO);releaseDone=YES;}];
    AwaitImport(^BOOL{return releaseDone;});
    Expect(@"failed release leaves durable owner for recovery",[release settings][@"initialImportOwner"] && ![release settings][@"initialImportVersion"]);
    release.failRelease=NO; releaseDone=NO;
    [release importRecentPaths:@[readable] recovery:nil completion:^(NSError* error){Expect(@"abandoned own token can retry",!error);releaseDone=YES;}];
    AwaitImport(^BOOL{return releaseDone;});
    Expect(@"reclaimed own lease finishes",[[release settings][@"initialImportVersion"] integerValue]==1 && ![release settings][@"initialImportOwner"]);
    [fm removeItemAtPath:sandbox error:nil];
}
