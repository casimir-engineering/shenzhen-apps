@interface SPDFCollectionStorageControlsProbe : SPDFMacCollectionWindow
@end
@implementation SPDFCollectionStorageControlsProbe
- (void)showError:(NSError*)error {
    if(error) { fprintf(stderr,"Storage controls error: %s\n",error.localizedDescription.UTF8String); Expect(@"storage control actions succeed without modal errors",NO); }
}
@end
static void CheckCollectionStorageControls(void) {
    NSURL* root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    [store updateSettings:@{@"storageMode":@"dynamic",@"storageDynamicPercent":@60} error:nil];
    SPDFMacCollectionWindow* manager=[[SPDFCollectionStorageControlsProbe alloc] initWithStore:store open:^(NSString* path,BOOL archived) {
        (void)path; (void)archived;
    }];
    [manager showDestination:@"Settings"];
    Layout(manager.window,NSMakeSize(850,590));
    Expect(@"dynamic percentage loads the saved setting",manager.dynamicPercent.integerValue==60 &&
        [manager.dynamicPercentLabel.stringValue isEqual:@"60%"] && !manager.dynamicPercent.hidden);
    Expect(@"dynamic percentage uses a bounded accessible native slider",manager.dynamicPercent.minValue==50 &&
        manager.dynamicPercent.maxValue==80 && manager.dynamicPercent.accessibilityLabel.length>0);
    Expect(@"storage mode explanation precedes options",Label(manager.settingsPane,@"Dynamic adjusts with free space; Static uses a fixed limit.")!=nil);
    Expect(@"location explains verified movement of all files",Label(manager.settingsPane,
        @"Moves all Collection files to the new location. Copies are verified before the old files are removed.")!=nil);
    manager.dynamicPercent.doubleValue=65.4; [manager changeDynamicPercent:manager.dynamicPercent];
    Expect(@"slider rounds to whole percentages and shows unapplied changes",manager.dynamicPercent.integerValue==65 &&
        [manager.dynamicPercentLabel.stringValue isEqual:@"65%"] && [manager.settingsStatus.stringValue containsString:@"Pending change"] &&
        [store.settings[@"storageDynamicPercent"] integerValue]==60);
    [manager changeLimit:nil];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (deadline.timeIntervalSinceNow>0 && ([store.settings[@"storageDynamicPercent"] integerValue]!=65 ||
        manager.mutationPending || !manager.hasLoadedResults || manager.loadingResults))
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"Apply persists the reviewed percentage together with dynamic mode",
        [store.settings[@"storageDynamicPercent"] integerValue]==65 && [store.settings[@"storageMode"] isEqual:@"dynamic"]);
    [manager updateStoragePolicy];
    Expect(@"applied percentage replaces pending feedback",[manager.settingsStatus.stringValue isEqual:@"Applied limit: Dynamic · 65% available."]);
    [manager.limitPicker selectItemAtIndex:1]; [manager performSelector:@selector(changeLimitMode:) withObject:manager.limitPicker];
    Expect(@"static mode hides percentage and exposes the fixed amount",manager.dynamicPercent.hidden &&
        manager.dynamicPercentLabel.hidden && !manager.limitField.hidden);
    [manager.limitPicker selectItemAtIndex:2]; [manager performSelector:@selector(changeLimitMode:) withObject:manager.limitPicker];
    Expect(@"switching modes retains the chosen dynamic percentage",manager.dynamicPercent.integerValue==65 && !manager.dynamicPercent.hidden);
    [manager.window close];
    dispatch_sync(manager.preferenceQueue,^{});
    [NSFileManager.defaultManager removeItemAtURL:root error:nil];
}
