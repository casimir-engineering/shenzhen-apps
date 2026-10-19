#import "SPDFMacCollectionStorePrivate.h"
#import <limits.h>

// Only named, manifest-referenced files count against the cap. Preview caches and
// interrupted uncommitted writes are disposable; shared objects count just once.
static NSDictionary* References(NSDictionary* manifest) {
    NSMutableDictionary* objects=[NSMutableDictionary dictionary];
    NSMutableSet* indexes=[NSMutableSet set];
    for (NSDictionary* doc in [manifest[@"documents"] allValues]) for (NSDictionary* v in doc[@"versions"]) {
        if (v[@"hash"]) objects[v[@"hash"]]=v[@"size"] ?: @0;
        for (NSDictionary* asset in v[@"assets"]) if (asset[@"hash"])
            objects[asset[@"hash"]]=asset[@"size"] ?: @0;
        if (v[@"indexFile"]) [indexes addObject:v[@"indexFile"]];
    }
    return @{@"objects":objects,@"indexes":indexes};
}
static NSSet* VersionFiles(NSDictionary* version) {
    NSMutableSet* files=[NSMutableSet set];
    if (version[@"hash"]) [files addObject:[@"objects/" stringByAppendingString:version[@"hash"]]];
    for (NSDictionary* asset in version[@"assets"]) if (asset[@"hash"])
        [files addObject:[@"objects/" stringByAppendingString:asset[@"hash"]]];
    if (version[@"indexFile"]) [files addObject:[@"indexes/" stringByAppendingString:version[@"indexFile"]]];
    return files;
}
static unsigned long long AddBytes(unsigned long long a,unsigned long long b) {
    return ULLONG_MAX-a<b ? ULLONG_MAX : a+b;
}
static NSString* ReviewToken(NSDictionary* manifest) {
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingSortedKeys error:nil];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString* token=[NSMutableString string];
    for (NSUInteger i=0;i<sizeof(digest);++i) [token appendFormat:@"%02x",digest[i]];
    return token;
}
static BOOL Protected(NSDictionary* doc) {
    if ([doc[@"editableCopies"] count]) return YES; // These files may be the user's only editable originals.
    for (NSDictionary* v in doc[@"versions"]) if ([v[@"keep"] boolValue]) return YES;
    return NO;
}
static NSArray* RankedDocuments(NSDictionary* manifest) {
    return [[manifest[@"documents"] allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
        NSComparisonResult order=[a[@"openCount"] ?: @0 compare:b[@"openCount"] ?: @0];
        if (order==NSOrderedSame) order=[a[@"lastOpenedAt"] ?: @0 compare:b[@"lastOpenedAt"] ?: @0];
        if (order==NSOrderedSame) order=[a[@"id"] compare:b[@"id"]];
        return order;
    }];
}
static void RemoveVersion(NSMutableDictionary* manifest,NSString* documentID,NSString* versionID) {
    NSMutableDictionary* doc=manifest[@"documents"][documentID];
    NSMutableArray* versions=doc[@"versions"];
    NSIndexSet* positions=[versions indexesOfObjectsPassingTest:^BOOL(NSDictionary* v,NSUInteger i,BOOL* stop) {
        (void)i;(void)stop; return [v[@"id"] isEqual:versionID];
    }];
    [versions removeObjectsAtIndexes:positions];
    if (!versions.count) {
        // An exclusion is a future-capture setting and survives history eviction.
        if ([doc[@"excluded"] boolValue]) {
            [doc removeObjectForKey:@"latestVersionID"]; [doc removeObjectForKey:@"capturedAt"];
            doc[@"status"]=@"Excluded";
        } else [manifest[@"documents"] removeObjectForKey:documentID];
    }
}
@implementation SPDFMacCollectionStore (CleanupPrivate)
- (NSDictionary*)fileSizesInManifest:(NSDictionary*)manifest {
    NSDictionary* references=References(manifest); NSMutableDictionary* sizes=[NSMutableDictionary dictionary];
    for (NSString* folder in @[@"objects",@"indexes"]) {
        id entries=references[folder];
        for (NSString* filename in entries) {
            if (![filename isEqual:filename.lastPathComponent]) continue;
            NSString* relative=[folder stringByAppendingPathComponent:filename];
            NSURL* URL=[self.rootURL URLByAppendingPathComponent:relative];
            struct stat info={}; unsigned long long size=0;
            if (lstat(URL.fileSystemRepresentation,&info)==0 && S_ISREG(info.st_mode)) size=(unsigned long long)info.st_size;
            else if ([folder isEqual:@"objects"]) size=[entries[filename] unsignedLongLongValue];
            sizes[relative]=@(size);
        }
    }
    for (NSDictionary* doc in [manifest[@"documents"] allValues]) if ([doc[@"editableCopies"] count]) {
        NSURL* directory=[[self.rootURL URLByAppendingPathComponent:@"editable"] URLByAppendingPathComponent:doc[@"id"]];
        for (NSURL* URL in [NSFileManager.defaultManager enumeratorAtURL:directory includingPropertiesForKeys:nil options:0 errorHandler:nil]) {
            struct stat info={};
            if (lstat(URL.fileSystemRepresentation,&info)==0 && S_ISREG(info.st_mode))
                sizes[[URL.path substringFromIndex:self.rootURL.path.length+1]]=@((unsigned long long)info.st_size);
        }
    }
    return sizes;
}
- (unsigned long long)retainedBytesInManifest:(NSDictionary*)manifest {
    unsigned long long total=0;
    for (NSNumber* size in [[self fileSizesInManifest:manifest] allValues]) total=AddBytes(total,size.unsignedLongLongValue);
    return total;
}
- (NSDictionary*)cleanupPlanForManifest:(NSDictionary*)manifest limit:(unsigned long long)limit
                   protectedVersionID:(NSString*)protectedVersionID {
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    NSMutableDictionary* candidate=[NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:nil];
    NSDictionary* sizes=[self fileSizesInManifest:manifest];
    NSMutableDictionary* counts=[NSMutableDictionary dictionary];
    unsigned long long used=0;
    for (NSNumber* size in sizes.allValues) used=AddBytes(used,size.unsignedLongLongValue);
    unsigned long long remaining=used;
    for (NSDictionary* doc in [manifest[@"documents"] allValues]) for (NSDictionary* version in doc[@"versions"])
        for (NSString* file in VersionFiles(version)) counts[file]=@([counts[file] unsignedLongLongValue]+1);
    NSMutableArray* removals=[NSMutableArray array]; NSUInteger documents=0;
    NSArray* ranked=RankedDocuments(candidate);
    if (limit && remaining>limit) for (NSUInteger stage=0;stage<2 && remaining>limit;++stage) {
        for (NSDictionary* entry in ranked) {
            if (remaining<=limit) break;
            NSMutableDictionary* doc=candidate[@"documents"][entry[@"id"]];
            if (!doc || Protected(doc)) continue;
            NSArray* versions=[doc[@"versions"] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
                NSComparisonResult order=[a[@"capturedAt"] compare:b[@"capturedAt"]];
                return order==NSOrderedSame ? [a[@"id"] compare:b[@"id"]] : order;
            }];
            NSString* latest=doc[@"latestVersionID"] ?: [versions lastObject][@"id"];
            for (NSDictionary* version in versions) {
                if (remaining<=limit) break;
                BOOL isLatest=[version[@"id"] isEqual:latest];
                if ((stage==0 && isLatest) || (stage==1 && !isLatest) ||
                    [version[@"id"] isEqual:protectedVersionID]) continue;
                [removals addObject:@{@"documentID":doc[@"id"],@"versionID":version[@"id"],
                    @"title":doc[@"title"] ?: @"Document",@"capturedAt":version[@"capturedAt"] ?: @0,
                    @"openCount":doc[@"openCount"] ?: @0,@"stage":stage==0 ? @"previousVersion" : @"document"}];
                RemoveVersion(candidate,doc[@"id"],version[@"id"]);
                if (stage==1) ++documents;
                for (NSString* file in VersionFiles(version)) {
                    unsigned long long count=[counts[file] unsignedLongLongValue];
                    if (count==1) remaining-=[sizes[file] unsignedLongLongValue];
                    counts[file]=@(count ? count-1 : 0);
                }
            }
        }
    }
    BOOL fits=!limit || remaining<=limit;
    return @{@"storageLimitBytes":@(limit),@"usedBytes":@(used),@"projectedBytes":@(remaining),
        @"reclaimedBytes":@(used-remaining),@"removedVersionCount":@(removals.count),
        @"removedDocumentCount":@(documents),@"canApply":@(fits),@"reviewToken":ReviewToken(manifest),
        @"removals":removals,@"error":fits ? @"" : @"Kept histories or the incoming document prevent this storage limit. Increase the limit or review Keep selections."};
}
- (void)applyCleanupPlan:(NSDictionary*)plan toManifest:(NSMutableDictionary*)manifest {
    if (![plan[@"removals"] count]) return;
    for (NSDictionary* removal in plan[@"removals"])
        RemoveVersion(manifest,removal[@"documentID"],removal[@"versionID"]);
    // This transient flag is removed before serialization; reclamation only runs
    // after the replacement manifest is durable, while still holding its lock.
    manifest[@"_collectUnreferencedFiles"]=@YES;
}
- (BOOL)enforceStorageLimitInManifest:(NSMutableDictionary*)manifest
                  protectedVersionID:(NSString*)versionID error:(NSError**)error {
    NSDictionary* budget=[self storageBudgetForManifest:manifest settings:manifest[@"settings"]];
    // Unknown capacity must never become a zero-byte quota or delete retained history.
    if (![budget[@"capacityAvailable"] boolValue]) return YES;
    unsigned long long limit=[budget[@"storageLimitBytes"] unsignedLongLongValue];
    if (!limit || (budget[@"usedBytes"] && [budget[@"usedBytes"] unsignedLongLongValue]<=limit)) return YES;
    NSDictionary* plan=[self cleanupPlanForManifest:manifest limit:limit protectedVersionID:versionID];
    if (![plan[@"canApply"] boolValue]) {
        if (error) *error=SPDFCollectionError(6,plan[@"error"]); return NO;
    }
    [self applyCleanupPlan:plan toManifest:manifest]; return YES;
}
- (void)collectUnreferencedFilesInManifest:(NSDictionary*)manifest {
    NSDictionary* references=References(manifest); NSFileManager* fm=NSFileManager.defaultManager;
    for (NSString* folder in @[@"objects",@"indexes"]) {
        id entries=references[folder];
        for (NSURL* URL in [fm contentsOfDirectoryAtURL:[self.rootURL URLByAppendingPathComponent:folder]
                            includingPropertiesForKeys:nil options:0 error:nil]) {
            BOOL retained=[entries isKindOfClass:NSDictionary.class] ? entries[URL.lastPathComponent]!=nil :
                           [entries containsObject:URL.lastPathComponent];
            if (!retained) [fm removeItemAtURL:URL error:nil];
        }
    }
    NSURL* previews=[self.rootURL URLByAppendingPathComponent:@"previews"];
    NSURL* editable=[self.rootURL URLByAppendingPathComponent:@"editable"];
    for (NSURL* docURL in [fm contentsOfDirectoryAtURL:editable includingPropertiesForKeys:nil options:0 error:nil])
        if (!manifest[@"documents"][docURL.lastPathComponent]) [fm removeItemAtURL:docURL error:nil];
    for (NSURL* docURL in [fm contentsOfDirectoryAtURL:previews includingPropertiesForKeys:nil options:0 error:nil]) {
        NSDictionary* doc=manifest[@"documents"][docURL.lastPathComponent];
        if (!doc) { [fm removeItemAtURL:docURL error:nil]; continue; }
        NSSet* versions=[NSSet setWithArray:[doc[@"versions"] valueForKey:@"id"]];
        for (NSURL* versionURL in [fm contentsOfDirectoryAtURL:docURL includingPropertiesForKeys:nil options:0 error:nil])
            if (![versions containsObject:versionURL.lastPathComponent]) [fm removeItemAtURL:versionURL error:nil];
    }
}
@end
@implementation SPDFMacCollectionStore (Cleanup)
- (NSDictionary*)previewStorageLimit:(unsigned long long)limit {
    return [self cleanupPlanForManifest:[self readManifest] limit:limit protectedVersionID:nil];
}
- (BOOL)applyStorageLimit:(unsigned long long)limit reviewedPlan:(NSDictionary*)plan error:(NSError**)error {
    return [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSDictionary* current=[self cleanupPlanForManifest:manifest limit:limit protectedVersionID:nil];
        if ([plan[@"storageLimitBytes"] unsignedLongLongValue]!=limit ||
            ![current[@"reviewToken"] isEqual:plan[@"reviewToken"]] ||
            ![current[@"removals"] isEqual:plan[@"removals"]] ||
            ![current[@"projectedBytes"] isEqual:plan[@"projectedBytes"]]) {
            if (failure) *failure=SPDFCollectionError(20,@"Collection changed since this cleanup was reviewed. Review the updated estimate and try again.");
            return NO;
        }
        if (![current[@"canApply"] boolValue]) {
            if (failure) *failure=SPDFCollectionError(6,current[@"error"]); return NO;
        }
        [self applyCleanupPlan:current toManifest:manifest];
        manifest[@"settings"][@"storageLimitBytes"]=@(limit);
        manifest[@"settings"][@"storageMode"]=limit ? @"static" : @"unlimited"; return YES;
    } error:error];
}
- (BOOL)recordUserOpenForDocumentID:(NSString*)documentID error:(NSError**)error {
    return [self recordUserOpenCount:1 forDocumentID:documentID error:error];
}
- (BOOL)recordUserOpenCount:(NSUInteger)count forDocumentID:(NSString*)documentID error:(NSError**)error {
    if (!count || !documentID.length || ![self readManifest][@"documents"][documentID]) return YES;
    return [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        (void)failure; NSMutableDictionary* doc=manifest[@"documents"][documentID];
        if (doc) {
            unsigned long long previous=[doc[@"openCount"] unsignedLongLongValue];
            doc[@"openCount"]=@(ULLONG_MAX-previous<count ? ULLONG_MAX : previous+count);
            doc[@"lastOpenedAt"]=@(NSDate.date.timeIntervalSince1970);
        }
        return YES;
    } error:error];
}
@end
