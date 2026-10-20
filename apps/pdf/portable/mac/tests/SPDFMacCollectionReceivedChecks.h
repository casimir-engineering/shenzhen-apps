// Files received through Friends (SPDFMacCollectionStore claimReceivedFiles:): each is claimed once, history before
// the first claim is never claimed, Collection off records without claiming, and not yet chosen creates nothing.
static void CheckReceivedClaims(void) {
    NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* files=NSFileManager.defaultManager;
    NSURL* root=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    long long now=(long long)NSDate.date.timeIntervalSince1970;
    Expect(@"received: not chosen claims nothing",[store claimReceivedFiles:@{@"t_new":@(now)}]==nil);
    Expect(@"received: not chosen creates no Collection",![files fileExistsAtPath:root.path]);
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSArray* first=[store claimReceivedFiles:@{@"t_old":@(now-3600),@"t_new":@(now+1)}];
    Expect(@"received: the first run claims only what came after it",[first isEqual:@[@"t_new"]]);
    Expect(@"received: claimed once",[[store claimReceivedFiles:@{@"t_new":@(now+1)}] isEqual:@[]]);
    SPDFMacCollectionStore* otherWindow=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    Expect(@"received: another window does not claim it again",
        [[otherWindow claimReceivedFiles:@{@"t_new":@(now+1),@"t_next":@(now+2)}] isEqual:@[@"t_next"]]);
    Expect(@"received: the start stays the first run's",
        [[store claimReceivedFiles:@{@"t_old":@(now-3600)}] isEqual:@[]]);
    [store updateSettings:@{@"choice":@"disabled"} error:nil];
    Expect(@"received: Collection off claims nothing",[[store claimReceivedFiles:@{@"t_off":@(now+3)}] isEqual:@[]]);
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    Expect(@"received: what came while off is not imported later",
        [[store claimReceivedFiles:@{@"t_off":@(now+3)}] isEqual:@[]]);
    NSMutableDictionary* many=[NSMutableDictionary dictionary];
    for (NSUInteger index=0; index<600; ++index) many[[NSString stringWithFormat:@"t_%04lu",(unsigned long)index]]=@(now+10);
    Expect(@"received: a long list is claimed",[[store claimReceivedFiles:many] count]==600);
    Expect(@"received: the record stays bounded",[[store settings][@"receivedFiles"][@"handled"] count]==500);
    Expect(@"received: the newest stay recorded",[[store claimReceivedFiles:@{@"t_0599":@(now+10)}] isEqual:@[]]);
    Expect(@"received: claiming captures nothing by itself",store.documents.count==0);
    [files removeItemAtPath:sandbox error:nil];
}
