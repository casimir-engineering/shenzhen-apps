#import "SPDFMacAIMetadataActions.h"
static NSDictionary* MetadataTool(SPDFMacAITools* tools,NSString* name,NSDictionary* arguments) {
    __block NSDictionary* result=nil;
    [tools performTool:name arguments:arguments completion:^(NSDictionary* value){result=value;}];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result!=nil,"metadata/history action finishes");return result;
}
// Each save gives the file a fresh second /ID half from a generator MuPDF seeds
// with the current second, so saving the same pages again differs there alone.
static NSData* MetadataBytesWithoutFileID(NSData* data) {
    NSString* text=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSRegularExpression* fileID=[NSRegularExpression regularExpressionWithPattern:
        @"/ID\\s*\\[\\s*<[0-9A-Fa-f]*>\\s*<[0-9A-Fa-f]*>\\s*\\]" options:0 error:nil];
    NSString* kept=[fileID stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length)
        withTemplate:@"/ID[]"];
    return [kept dataUsingEncoding:NSISOLatin1StringEncoding];
}
// Waits for the next second, so a redone save always gets a different identifier
// from the first one, as it does when a person redoes an edit later.
static void MetadataNextSecond(void) {
    time_t start=time(NULL);
    while(time(NULL)==start)[NSThread sleepForTimeInterval:.01];
}
static BOOL MetadataSamePages(NSData* a,NSData* b) {
    return a && b && [MetadataBytesWithoutFileID(a) isEqual:MetadataBytesWithoutFileID(b)];
}
static void CheckAIMetadataHistory(NSString* root,NSString* path) {
    AIContextProbe* reader=[AIContextProbe new];[reader seedTabs:@[]];[reader seedControls];
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:
        [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"metadata-settings.yaml"]]];
    settings.enabled=YES;settings.automaticAnalysis=YES;
    [reader configureAIAnalysis:settings];[reader seedTabs:@[Tab(path,nil)]];[reader seedPDF:path];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    NSURL* cacheRoot=[SPDFMacAISettings.defaultURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"AI/Analysis"];
    SPDFMacAIAnalysisCache* cache=[[SPDFMacAIAnalysisCache alloc] initWithRootURL:cacheRoot];
    Check(![NSFileManager.defaultManager fileExistsAtPath:cacheRoot.path],"metadata/history initialization creates no analysis storage");
    NSString* key=SPDFAIContentHash(path,[NSProgress progressWithTotalUnitCount:1],nil);
    NSDictionary* before=SPDFAIValidateAnalysis(@{@"summary":@"Original summary",@"keywords":@[@"audio"],
        @"tags":@[@"electronics"],@"chapters":@[@{@"title":@"Audio",@"page":@1}],@"analyzedPages":@[@1],
        @"language":@"en",@"model":settings.model,@"cacheKey":key,@"contentHash":key},1,NO,nil);
    Check([cache storeAnalysis:before forHash:key error:nil],"metadata fixture stored");
    [reader aiInstallAnalysis:before error:nil candidate:[reader aiDocumentCandidateForPath:path] settings:settings];
    Check([[reader aiAnalysisForPath:path] isEqual:before],"production metadata fixture installed");
    NSData* document=[NSData dataWithContentsOfFile:path];
    NSString* revision=SPDFSearchFileStamp(path);
    NSDictionary* args=@{@"path":SPDFAIDocumentIdentifier(path),@"revision":revision,@"metadata":@{
        @"summary":@"中文摘要",@"language":@"zh-Hans",@"chapters":@[@{@"title":@"音频",@"page":@1}]}};
    NSDictionary* result=MetadataTool(tools,@"update_document_metadata",args);
    Check([result[@"changed"] boolValue] && [result[@"undoable"] boolValue] && !result[@"metadataReceipt"],
        "metadata tool updates directly and hides its private receipt");
    NSDictionary* after=[reader aiAnalysisForPath:path];
    Check([after[@"language"] isEqual:@"zh-Hans"] && [after[@"summary"] isEqual:@"中文摘要"] &&
        [after[@"chapters"][0][@"title"] isEqual:@"音频"] && [[cache analysisForHash:key] isEqual:after],
        "metadata language and generated chapters publish and persist together");
    Check([[NSData dataWithContentsOfFile:path] isEqual:document],"metadata edit never rewrites document bytes");
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue] &&
        [[reader aiAnalysisForPath:path] isEqual:before] && [[cache analysisForHash:key] isEqual:before] && tools.canRedo,
        "metadata Undo restores exact persistent and displayed values");
    Check([MetadataTool(tools,@"redo_action",@{})[@"redone"] boolValue] &&
        [[reader aiAnalysisForPath:path] isEqual:after] && [[cache analysisForHash:key] isEqual:after] && tools.canUndo,
        "metadata Redo restores exact persistent and displayed values");
    NSMutableDictionary* externalMetadata=[after mutableCopy];externalMetadata[@"summary"]=@"Another window's edit";
    Check([cache storeAnalysis:externalMetadata forHash:key error:nil],"external metadata fixture committed");
    Check(MetadataTool(tools,@"undo_action",@{})[@"error"] &&
        [[cache analysisForHash:key] isEqual:externalMetadata],"metadata Undo preserves another window's cache edit");
    Check([cache storeAnalysis:after forHash:key error:nil],"metadata cache restored for remaining history checks");
    NSMutableDictionary* invalid=[args mutableCopy];invalid[@"metadata"]=@{@"chapters":@[@{@"title":@"Outside",@"page":@2}]};
    Check(MetadataTool(tools,@"update_document_metadata",invalid)[@"error"] &&
        [[reader aiAnalysisForPath:path] isEqual:after],"metadata rejects invalid chapters without changing cached result");
    invalid[@"metadata"]=@{@"summary":@"Should not change"};invalid[@"revision"]=@"old";
    Check(MetadataTool(tools,@"update_document_metadata",invalid)[@"error"],"metadata rejects stale document revision");
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue],"metadata second Undo succeeds");
    MetadataTool(tools,@"reader_control",@{@"path":SPDFAIDocumentIdentifier(path),@"control":@"map",@"value":@"shown"});
    Check(!tools.canRedo && MetadataTool(tools,@"redo_action",@{})[@"error"],"new action invalidates metadata redo branch");
    // Metadata and file transactions share one journal. Restoring the same
    // bytes must not strand the older metadata action behind a new inode stamp.
    tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check([MetadataTool(tools,@"update_document_metadata",args)[@"changed"] boolValue],"mixed history metadata edit");
    Check([MetadataTool(tools,@"reader_control",@{@"path":SPDFAIDocumentIdentifier(path),@"control":@"rotate",
        @"value":@"clockwise",@"revision":SPDFSearchFileStamp(path)})[@"undoable"] boolValue],"mixed history PDF edit");
    NSData* mixedRotation=[NSData dataWithContentsOfFile:path];
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue] &&
        [MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue] &&
        [[cache analysisForHash:key] isEqual:before] && [[reader aiAnalysisForPath:path] isEqual:before],
        "metadata Undo survives a later file Undo restoring its source bytes");
    MetadataNextSecond();
    Check([MetadataTool(tools,@"redo_action",@{})[@"redone"] boolValue] &&
        [MetadataTool(tools,@"redo_action",@{})[@"redone"] boolValue] &&
        [[cache analysisForHash:key] isEqual:after] &&
        MetadataSamePages([NSData dataWithContentsOfFile:path],mixedRotation),
        "mixed metadata and file history redoes both changes");
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue],"mixed rotation restored for conflict test");
    NSMutableData* conflicting=[document mutableCopy];[conflicting appendData:[@"\n% external\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [conflicting writeToFile:path atomically:YES];
    Check(MetadataTool(tools,@"undo_action",@{})[@"error"] && [[cache analysisForHash:key] isEqual:after],
        "metadata Undo rejects different source bytes after a file Undo");
    [document writeToFile:path atomically:YES];
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue],"metadata Undo accepts exact restored source bytes");
    // File transactions restore bytes atomically, changing stat revisions on every Undo.
    tools=[[SPDFMacAITools alloc] initWithReader:reader];
    for(NSUInteger i=0;i<2;i++) {
        result=MetadataTool(tools,@"reader_control",@{@"path":SPDFAIDocumentIdentifier(path),@"control":@"rotate",
            @"value":@"clockwise",@"revision":SPDFSearchFileStamp(path)});
        Check([result[@"undoable"] boolValue],"two rotations recorded for redo");
    }
    NSData* twiceRotated=[NSData dataWithContentsOfFile:path];
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue] &&
        [MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue],"two file actions undo in sequence");
    MetadataNextSecond();
    Check([MetadataTool(tools,@"redo_action",@{})[@"redone"] boolValue] &&
        [MetadataTool(tools,@"redo_action",@{})[@"redone"] boolValue],"two file actions redo despite new file revisions");
    Check(MetadataSamePages([NSData dataWithContentsOfFile:path],twiceRotated),
        "file redo returns to the same final pages");
    Check([MetadataTool(tools,@"undo_action",@{})[@"undone"] boolValue],"file redo creates a fresh Undo receipt");
    NSMutableData* external=[[NSData dataWithContentsOfFile:path] mutableCopy];
    [external appendData:[@"\n% human edit\n" dataUsingEncoding:NSUTF8StringEncoding]];[external writeToFile:path atomically:YES];
    Check(MetadataTool(tools,@"redo_action",@{})[@"error"] && [[NSData dataWithContentsOfFile:path] isEqual:external],
        "file redo refuses intervening document edits");
    [document writeToFile:path atomically:YES];
    // Hold the main thread until the cache is committed, then simulate the file
    // watcher advancing the document before the pending UI publication runs.
    Check([cache storeAnalysis:before forHash:key error:nil],"race fixture cache reset");
    [reader aiInstallAnalysis:before error:nil candidate:[reader aiDocumentCandidateForPath:path] settings:settings];
    __block NSDictionary* race=nil;
    [reader aiUpdateMetadata:@{@"path":path,@"revision":SPDFSearchFileStamp(path),
        @"metadata":@{@"summary":@"Late worker result"}} progress:[NSProgress progressWithTotalUnitCount:1]
        completion:^(NSDictionary* value){race=value;}];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(![[cache analysisForHash:key][@"summary"] isEqual:@"Late worker result"] && deadline.timeIntervalSinceNow>0)
        [NSThread sleepForTimeInterval:.005];
    Check([[cache analysisForHash:key][@"summary"] isEqual:@"Late worker result"],"worker committed before file watcher race");
    [external writeToFile:path atomically:YES];
    deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!race && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check([race[@"changed"] boolValue] && ![reader aiAnalysisForPath:path],
        "committed cache edit retains receipt without publishing stale metadata onto a changed document");
    [document writeToFile:path atomically:YES];
    puts("AI metadata persistence and Undo/Redo acceptance passed");
}
