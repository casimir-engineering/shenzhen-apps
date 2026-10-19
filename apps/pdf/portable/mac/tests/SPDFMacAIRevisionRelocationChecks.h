// Production observer seam: verify filesystem resolution stays on its lazy worker.
@interface SPDFAnalysisRevisionObserver : NSObject
@property(atomic) BOOL enabled;
@property(nonatomic) NSMutableSet* roots;
@property(nonatomic) dispatch_queue_t worker;
@property(nonatomic,copy) void (^changed)(NSString* root);
- (NSString*)resolveRoot:(NSString*)root;
- (void)trackRoot:(NSString*)root;
- (void)receiveRoot:(NSString*)root;
@end
@interface RevisionRootProbe : SPDFAnalysisRevisionObserver
@property(atomic) NSUInteger resolutions;
@property(atomic) BOOL touchedMain;
@end
@implementation RevisionRootProbe
- (NSString*)resolveRoot:(NSString*)root {
    self.resolutions++;self.touchedMain=self.touchedMain || NSThread.isMainThread;
    return [super resolveRoot:root];
}
@end
@interface ShenzhenMacDelegate (RevisionObserverProbe)
- (SPDFAnalysisRevisionObserver*)aiObserveCollectionAnalysisRevisions:(NSDictionary*)candidate;
@end
static void CheckRevisionRelocation(NSURL* sandbox,SPDFMacAISettings* settings) {
    NSURL* original=[sandbox URLByAppendingPathComponent:@"Old"],*moved=[sandbox URLByAppendingPathComponent:@"New"];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:original];
    [store updateSettings:@{@"choice":@"enabled",@"storageMode":@"unlimited"} error:nil];
    NSString* source=[sandbox.path stringByAppendingPathComponent:@"original.md"];
    [@"First latest revision" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* first=[store capturePath:source reason:@"Opened" error:nil];
    NSURL* copy=[store editableVersionID:nil documentID:first[@"id"] error:nil];
    NSURL* preview=[store materializeVersionID:first[@"latestVersionID"] documentID:first[@"id"] error:nil];
    AnalysisReaderProbe* reader=[AnalysisReaderProbe new];[reader configureAIAnalysis:settings];
    NSMutableDictionary* candidate=[@{@"path":copy.path,@"readPath":copy.path,@"revision":@"same bytes",
        @"landscape":@NO,@"collectionGeneration":@0} mutableCopy];
    NSDictionary* analysis=@{@"model":settings.model,@"summary":@"First",@"chapters":@[]};
    reader.candidates=@[candidate];[reader aiInstallAnalysis:analysis error:nil candidate:[candidate copy] settings:settings];
    Check([reader aiAnalysisForPath:copy.path]!=nil,"pre-move copy analysis fixture installs");
    Check([store relocateToURL:moved error:nil],"analysis fixture relocates Collection");
    Check(![reader aiAnalysisForPath:copy.path],"relocation bridge immediately invalidates old-root installed analysis");
    NSDictionary* metadata=SPDFAICollectionRevisionMetadata(store,copy.path,0);
    Check([metadata[@"analysisEligible"] boolValue] && [metadata[@"analysisDocumentID"] isEqual:first[@"id"]] &&
        [metadata[@"selectedVersionID"] isEqual:first[@"latestVersionID"]],"restored editable alias retains latest identity after move");
    Check(![SPDFAICollectionRevisionMetadata(store,preview.path,0)[@"analysisEligible"] boolValue],
        "restored preview alias remains ineligible after move");
    candidate[@"collectionGeneration"]=@1;
    [reader aiInstallAnalysis:analysis error:nil candidate:[candidate copy] settings:settings];
    Check([reader aiAnalysisForPath:copy.path]!=nil,"post-move revalidated analysis installs through old alias");
    SPDFMacCollectionStore* atNewRoot=[[SPDFMacCollectionStore alloc] initWithRootURL:moved];
    [@"Newer revision" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [atNewRoot capturePath:source reason:@"Saved" continuingDocumentID:first[@"id"] error:nil];
    Check(![reader aiAnalysisForPath:copy.path] && ![SPDFAICollectionRevisionMetadata(store,copy.path,0)[@"analysisEligible"] boolValue],
        "new-root capture invalidates old alias and excludes its now-historical revision");
    // A restored window created AFTER relocation has only the old lexical root.
    AnalysisReaderProbe* restored=[AnalysisReaderProbe new];[restored configureAIAnalysis:settings];
    candidate[@"collectionGeneration"]=@0;restored.candidates=@[candidate];
    [restored aiInstallAnalysis:analysis error:nil candidate:[candidate copy] settings:settings];
    SPDFAnalysisRevisionObserver* observer=[restored aiObserveCollectionAnalysisRevisions:candidate];
    Check(Wait(^BOOL{ @synchronized(observer) { return [observer.roots containsObject:moved.path.stringByResolvingSymlinksInPath]; } }),
        "restored observer registers current Collection root on its worker");
    [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:atNewRoot];
    Check(Wait(^BOOL{return ![restored aiAnalysisForPath:copy.path];}),"future new-root notification reaches restored old alias");
    RevisionRootProbe* probe=[RevisionRootProbe new];probe.roots=[NSMutableSet set];probe.enabled=YES;
    probe.worker=dispatch_queue_create("revision-root-test",DISPATCH_QUEUE_SERIAL);
    [probe trackRoot:original.path];dispatch_sync(probe.worker,^{});
    Check(probe.resolutions==1 && !probe.touchedMain,"root alias resolution runs only on worker");
    probe.enabled=NO;NSUInteger before=probe.resolutions;[probe receiveRoot:moved.path];[probe trackRoot:@"/disabled-root"];dispatch_sync(probe.worker,^{});
    Check(probe.resolutions==before,"disabled observer never queues filesystem resolution");
    [reader configureAIAnalysis:nil];[restored configureAIAnalysis:nil];
    [NSFileManager.defaultManager removeItemAtURL:sandbox error:nil];
}
