// Generated fixture only: repeated thumbnails must not rewrite the entire library.
static void CheckCollectionMaterializationPerformance(void) {
    NSString* directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* root=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"Collection"]];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSString* path=[directory stringByAppendingPathComponent:@"Preview.txt"];
    [@"Retained preview bytes" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary* document=[store capturePath:path reason:@"Opened" error:nil];
    NSDictionary* version=[store versionsForDocumentID:document[@"id"]].firstObject;
    NSMutableDictionary* manifest=[store readManifest];
    for(NSUInteger i=0;i<500;i++) {
        NSMutableDictionary* row=[document mutableCopy];
        row[@"id"]=[NSString stringWithFormat:@"fixture-%lu",(unsigned long)i];
        NSMutableArray* history=[NSMutableArray array];
        for(NSUInteger j=0;j<10;j++) [history addObject:version];
        row[@"versions"]=history; manifest[@"documents"][row[@"id"]]=row;
    }
    NSURL* manifestURL=[root URLByAppendingPathComponent:@"manifest.json"];
    NSData* fixture=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    [fixture writeToURL:manifestURL atomically:YES];
    NSDictionary* before=[fm attributesOfItemAtPath:manifestURL.path error:nil];
    CFAbsoluteTime begin=CFAbsoluteTimeGetCurrent();
    NSURL* preview=nil;
    for(NSUInteger iteration=0;iteration<20;iteration++) @autoreleasepool {
        preview=[store materializeVersionID:version[@"id"] documentID:document[@"id"] error:nil];
        Expect(@"repeated materialization returns protected copy",preview!=nil);
    }
    double elapsed=(CFAbsoluteTimeGetCurrent()-begin)*1000;
    fprintf(stderr,"Collection materialization: 20 requests, %lu manifest bytes, %.2f ms\n",
        (unsigned long)fixture.length,elapsed);
    NSDictionary* after=[fm attributesOfItemAtPath:manifestURL.path error:nil];
    Expect(@"preview requests do not rewrite library manifest",
        [before[NSFileSystemFileNumber] isEqual:after[NSFileSystemFileNumber]] &&
        [before[NSFileModificationDate] isEqual:after[NSFileModificationDate]]);
    Expect(@"read transaction leaves manifest bytes identical",[[NSData dataWithContentsOfURL:manifestURL] isEqual:fixture]);
    [fm setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:preview.path error:nil];
    [@"Tampered preview" writeToURL:preview atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSURL* repaired=[store materializeVersionID:version[@"id"] documentID:document[@"id"] error:nil];
    Expect(@"read transaction still repairs a modified preview",[[NSData dataWithContentsOfURL:repaired]
        isEqual:[NSData dataWithContentsOfFile:path]]);
    [@"broken manifest" writeToURL:manifestURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError* error=nil;
    Expect(@"read transaction rejects corrupt metadata without replacing it",
        ![store materializeVersionID:version[@"id"] documentID:document[@"id"] error:&error] && error!=nil &&
        [[NSString stringWithContentsOfURL:manifestURL encoding:NSUTF8StringEncoding error:nil] isEqual:@"broken manifest"]);
    [fm removeItemAtPath:directory error:nil];
}
