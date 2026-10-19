@interface CapacityCollectionStore : SPDFMacCollectionStore
@property NSNumber* freeBytes;
@property NSUInteger capacityQueries;
@property NSUInteger cleanupPlans;
@property NSUInteger fileCollections;
@end
@implementation CapacityCollectionStore
- (NSNumber*)availableCapacityBytes { ++self.capacityQueries; return self.freeBytes; }
- (NSDictionary*)cleanupPlanForManifest:(NSDictionary*)manifest limit:(unsigned long long)limit protectedVersionID:(NSString*)ID {
    ++self.cleanupPlans; return [super cleanupPlanForManifest:manifest limit:limit protectedVersionID:ID];
}
- (void)collectUnreferencedFilesInManifest:(NSDictionary*)manifest {
    ++self.fileCollections; [super collectUnreferencedFilesInManifest:manifest];
}
@end
static void CapacityChecks(NSURL* sandbox) {
    NSURL* root=[sandbox URLByAppendingPathComponent:@"Dynamic"];
    CapacityCollectionStore* store=[[CapacityCollectionStore alloc] initWithRootURL:root];
    store.freeBytes=@1000;
    Check([store.settings[@"storageMode"] isEqual:@"dynamic"] && store.isStorageLimited && !store.capacityQueries,
          @"construction and settings never query volume capacity");
    Check([store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==800 && store.capacityQueries==1,
          @"explicit budget query uses 80 percent available space");
    Check(![NSFileManager.defaultManager fileExistsAtPath:root.path],@"capacity query does not create unused Collection");
    Save(root,@{@"a":Doc(@"a",0,0,@[Version(root,@"a1",@"a1",1,NO),Version(root,@"a2",@"a2",2,NO),Version(root,@"a3",@"a3",3,NO)]),
                @"b":Doc(@"b",1,0,@[Version(root,@"b1",@"b1",1,NO),Version(root,@"b2",@"b2",2,NO)])});
    Check([store transaction:^BOOL(NSMutableDictionary* m,NSError** error) { return [store enforceStorageLimitInManifest:m protectedVersionID:nil error:error]; } error:nil]
          && !store.cleanupPlans && !store.fileCollections,@"under-budget capture avoids deletion planning and garbage collection");
    store.freeBytes=@0;
    NSDictionary* dynamic=@{@"storageMode":@"dynamic"};
    NSDictionary* plan=[store previewStoragePolicy:dynamic];
    Check([plan[@"storageLimitBytes"] unsignedLongLongValue]==48 && [IDs(plan) isEqual:@"a1"],@"dynamic includes managed bytes and evicts least opened older revision");
    Check([store applyStoragePolicy:dynamic reviewedPlan:plan error:nil] && store.storageUsedBytes==48,@"dynamic reviewed cleanup applies");
    store.freeBytes=@12;
    Check([store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==48,@"reclaimed bytes keep dynamic budget stable");
    store.freeBytes=@1012;
    Check([store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==848,@"dynamic grows with newly available space");
    store.freeBytes=@0;
    plan=[store previewStoragePolicy:dynamic];
    Check([plan[@"storageLimitBytes"] unsignedLongLongValue]==38 && [IDs(plan) isEqual:@"a2"],@"dynamic shrinks after external disk use");
    store.freeBytes=@0;
    NSDictionary* largerReview=[store previewStoragePolicy:dynamic];
    store.freeBytes=@1;
    Check([store applyStoragePolicy:dynamic reviewedPlan:largerReview error:nil],@"free-space movement retaining the same removals does not invalidate review");
    store.freeBytes=@1000;
    NSDictionary* safeReview=[store previewStoragePolicy:dynamic];
    store.freeBytes=@0;
    NSError* changed=nil;
    Check(![store applyStoragePolicy:dynamic reviewedPlan:safeReview error:&changed] && changed.code==20,
          @"space reduction requiring extra deletion invalidates reviewed cleanup");
    store.freeBytes=nil;
    NSArray* before=store.documents;
    Check(![[store previewStoragePolicy:dynamic][@"canApply"] boolValue],@"unknown capacity rejects destructive explicit review");
    Check([store transaction:^BOOL(NSMutableDictionary* m,NSError** error) { return [store enforceStorageLimitInManifest:m protectedVersionID:nil error:error]; } error:nil]
          && [before isEqual:store.documents],@"unknown capacity pauses automatic eviction without losing history");
    store.freeBytes=@0;
    [store setKeep:YES versionID:@"a3" documentID:@"a" error:nil];
    plan=[store previewStoragePolicy:dynamic];
    Check(![IDs(plan) containsString:@"a2"] && ![IDs(plan) containsString:@"a3"],@"dynamic cleanup preserves whole kept history");
    // Legacy settings are normalized without changing their persisted choices.
    [store updateSettings:@{@"storageLimitBytes":@100} error:nil];
    NSUInteger queries=store.capacityQueries;
    Check([store.settings[@"storageMode"] isEqual:@"static"] && [store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==100
          && queries==store.capacityQueries,@"static budget never queries disk");
    [store updateSettings:@{@"storageLimitBytes":@0} error:nil];
    Check(!store.isStorageLimited && [store.settings[@"storageMode"] isEqual:@"unlimited"],@"legacy explicit unlimited remains unlimited");
    store.freeBytes=@1000;
    [store updateSettings:@{@"storageMode":@"dynamic",@"storageDynamicPercent":@50} error:nil];
    unsigned long long pool=1000+store.storageUsedBytes;
    Check([store.settings[@"storageDynamicPercent"] integerValue]==50 &&
        [store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==pool/2,@"dynamic fifty percent uses selected reserve");
    [store updateSettings:@{@"storageMode":@"static",@"storageLimitBytes":@10000} error:nil];
    [store updateSettings:@{@"storageMode":@"dynamic"} error:nil];
    Check([store.settings[@"storageDynamicPercent"] integerValue]==50,@"percentage persists across static and dynamic switches");
    [store updateSettings:@{@"storageDynamicPercent":@999} error:nil];
    Check([store.settings[@"storageDynamicPercent"] integerValue]==80,@"dynamic percentage clamps upper bound");
    [store updateSettings:@{@"storageDynamicPercent":@1} error:nil];
    Check([store.settings[@"storageDynamicPercent"] integerValue]==50,@"dynamic percentage clamps lower bound");
    [store updateSettings:@{@"storageDynamicPercent":@65} error:nil];
    NSDictionary* percentReview=[store previewStoragePolicy:@{@"storageMode":@"dynamic"}];
    Check([percentReview[@"storagePolicy"][@"storageDynamicPercent"] integerValue]==65 &&
        [store applyStoragePolicy:@{@"storageMode":@"dynamic"} reviewedPlan:percentReview error:nil],
        @"review and apply preserve saved percent when omitted");
    CapacityCollectionStore* reopened=[[CapacityCollectionStore alloc] initWithRootURL:root];
    Check([reopened.settings[@"storageDynamicPercent"] integerValue]==65,@"dynamic percent persists across store instances");
    store.freeBytes=@(ULLONG_MAX);
    unsigned long long saturated=ULLONG_MAX/100*65+(ULLONG_MAX%100)*65/100;
    Check([store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==saturated,@"dynamic percent calculation is overflow safe");
    NSDictionary* legacy=@{@"format":@1,@"settings":@{@"choice":@"enabled",@"storageLimitBytes":@2048},@"documents":@{}};
    Put([root URLByAppendingPathComponent:@"manifest.json"],[NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil]);
    Check([store.settings[@"storageMode"] isEqual:@"static"] && [store.storageBudget[@"storageLimitBytes"] unsignedLongLongValue]==2048,@"legacy saved static cap migrates on read");
    NSMutableDictionary* unlimited=[legacy mutableCopy]; unlimited[@"settings"]=@{@"storageLimitBytes":@0};
    Put([root URLByAppendingPathComponent:@"manifest.json"],[NSJSONSerialization dataWithJSONObject:unlimited options:0 error:nil]);
    Check([store.settings[@"storageMode"] isEqual:@"unlimited"],@"legacy saved unlimited migrates on read");
}
