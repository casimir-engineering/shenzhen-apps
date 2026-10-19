#import "SPDFMacCollectionStorePrivate.h"
#import <sys/mount.h>
#import <limits.h>
#import <math.h>

NSDictionary* SPDFCollectionStorageSettings(NSDictionary* saved) {
    NSString* mode=saved[@"storageMode"];
    if (![@[@"dynamic",@"static",@"unlimited"] containsObject:mode ?: @""])
        mode=saved[@"storageLimitBytes"] ? ([saved[@"storageLimitBytes"] unsignedLongLongValue] ? @"static" : @"unlimited") : @"dynamic";
    id value=saved[@"storageDynamicPercent"];
    double supplied=[value isKindOfClass:NSNumber.class] ? [value doubleValue] : 80;
    NSInteger percent=isfinite(supplied) ? (NSInteger)MAX(50.0,MIN(80.0,supplied)) : 80;
    return @{@"storageMode":mode,@"storageLimitBytes":saved[@"storageLimitBytes"] ?: @0,@"storageDynamicPercent":@(percent)};
}
@implementation SPDFMacCollectionStore (Capacity)
- (BOOL)isStorageLimited {
    NSDictionary* settings=SPDFCollectionStorageSettings(self.settings);
    return [settings[@"storageMode"] isEqual:@"dynamic"] ||
        ([settings[@"storageMode"] isEqual:@"static"] && [settings[@"storageLimitBytes"] unsignedLongLongValue]>0);
}
- (NSNumber*)availableCapacityBytes {
    // Find the existing parent for an unused Collection; never create a folder to query it.
    NSURL* URL=self.rootURL;
    if (![URL isEqual:self.originalRootURL] && ![NSFileManager.defaultManager fileExistsAtPath:URL.path]) return nil;
    while (![NSFileManager.defaultManager fileExistsAtPath:URL.path] && URL.path.length>1)
        URL=URL.URLByDeletingLastPathComponent;
    struct statfs volume={};
    if (statfs(URL.fileSystemRepresentation,&volume)!=0 || volume.f_bsize<=0) return nil;
    unsigned long long blocks=(unsigned long long)volume.f_bavail,size=(unsigned long long)volume.f_bsize;
    return @(blocks>ULLONG_MAX/size ? ULLONG_MAX : blocks*size);
}
- (NSDictionary*)storageBudgetForManifest:(NSDictionary*)manifest settings:(NSDictionary*)saved {
    NSDictionary* settings=SPDFCollectionStorageSettings(saved);
    NSString* mode=settings[@"storageMode"];
    if (![mode isEqual:@"dynamic"])
        return @{@"storageMode":mode,@"storageLimitBytes":[mode isEqual:@"unlimited"] ? @0 : settings[@"storageLimitBytes"],@"capacityAvailable":@YES};
    NSNumber* free=[self availableCapacityBytes];
    unsigned long long used=[self retainedBytesInManifest:manifest],available=free.unsignedLongLongValue;
    unsigned long long pool=ULLONG_MAX-used<available ? ULLONG_MAX : available+used;
    // Integer arithmetic avoids rounding overflow. One byte is the smallest finite quota;
    // zero remains reserved for explicit unlimited storage.
    unsigned long long percent=[settings[@"storageDynamicPercent"] unsignedLongLongValue];
    unsigned long long budget=pool/100*percent+(pool%100)*percent/100;
    return @{@"storageMode":mode,@"storageDynamicPercent":@(percent),@"storageLimitBytes":@(free ? MAX(1ULL,budget) : 0),
        @"availableBytes":free ?: @0,@"usedBytes":@(used),@"capacityAvailable":@(free!=nil)};
}
- (NSDictionary*)storageBudget {
    NSDictionary* manifest=[self readManifest];
    return [self storageBudgetForManifest:manifest settings:manifest[@"settings"]];
}
- (NSDictionary*)previewStoragePolicy:(NSDictionary*)policy {
    NSDictionary* manifest=[self readManifest];
    NSMutableDictionary* merged=[manifest[@"settings"] mutableCopy] ?: [NSMutableDictionary dictionary];
    [merged addEntriesFromDictionary:policy];
    NSDictionary* settings=SPDFCollectionStorageSettings(merged);
    NSDictionary* budget=[self storageBudgetForManifest:manifest settings:settings];
    NSMutableDictionary* plan=[[self cleanupPlanForManifest:manifest limit:[budget[@"storageLimitBytes"] unsignedLongLongValue] protectedVersionID:nil] mutableCopy];
    plan[@"storagePolicy"]=settings;
    if (![budget[@"capacityAvailable"] boolValue]) {
        plan[@"canApply"]=@NO; plan[@"error"]=@"Available disk space could not be read. No copies will be deleted. Try again when the Collection drive is available.";
    }
    return plan;
}
- (BOOL)applyStoragePolicy:(NSDictionary*)policy reviewedPlan:(NSDictionary*)plan error:(NSError**)error {
    return [self transaction:^BOOL(NSMutableDictionary* manifest,NSError** failure) {
        NSMutableDictionary* merged=[manifest[@"settings"] mutableCopy] ?: [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:policy];
        NSDictionary* settings=SPDFCollectionStorageSettings(merged);
        NSDictionary* budget=[self storageBudgetForManifest:manifest settings:settings];
        NSDictionary* current=[self cleanupPlanForManifest:manifest limit:[budget[@"storageLimitBytes"] unsignedLongLongValue] protectedVersionID:nil];
        // Free space changes continually. A smaller deletion set is safe; a larger or different
        // set needs a new review. The manifest token still guards concurrent Collection writes.
        NSSet* reviewed=[NSSet setWithArray:plan[@"removals"] ?: @[]];
        BOOL same=[settings isEqual:plan[@"storagePolicy"]] && [current[@"reviewToken"] isEqual:plan[@"reviewToken"]];
        for (NSDictionary* removal in current[@"removals"]) if (![reviewed containsObject:removal]) same=NO;
        if (!same || ![budget[@"capacityAvailable"] boolValue]) {
            if (failure) *failure=SPDFCollectionError(20,@"Collection or available space changed. Review the updated storage estimate and try again."); return NO;
        }
        if (![current[@"canApply"] boolValue]) { if(failure)*failure=SPDFCollectionError(6,current[@"error"]); return NO; }
        [self applyCleanupPlan:current toManifest:manifest];
        [manifest[@"settings"] addEntriesFromDictionary:settings]; return YES;
    } error:error];
}
@end
