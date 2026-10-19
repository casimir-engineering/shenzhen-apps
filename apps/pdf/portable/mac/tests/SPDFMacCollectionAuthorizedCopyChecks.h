#import "SPDFMacReadOnlyCopy.h"
#import <objc/runtime.h>

// Simulates a protected third-party source: the first authorized read can
// succeed while a later unscoped read fails, independently of Unix mode bits.
static NSString* DeniedCaptureSource;
static NSUInteger DeniedCaptureReads;
@interface NSData (SPDFDeniedCaptureTest)
+ (instancetype)spdf_testReadFile:(NSString*)path options:(NSDataReadingOptions)options error:(NSError**)error;
@end
@implementation NSData (SPDFDeniedCaptureTest)
+ (instancetype)spdf_testReadFile:(NSString*)path options:(NSDataReadingOptions)options error:(NSError**)error {
    if ([path isEqual:DeniedCaptureSource]) {
        ++DeniedCaptureReads;
        if (error) *error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:nil];
        return nil;
    }
    return [self spdf_testReadFile:path options:options error:error];
}
@end
static NSDictionary* WaitAuthorizedCapture(SPDFMacCollectionStore* store, NSString* source, NSDictionary* hint,
                                           NSError** outError, BOOL* recorded) {
    __block BOOL done=NO; __block NSDictionary* result; __block NSError* failure; __block BOOL counted=NO;
    [store capturePath:source authorizedCopy:hint reason:@"Opened" continuingDocumentID:nil userOpenCount:1
        completion:^(NSDictionary* row,NSError* error,BOOL didRecord) {
            result=row; failure=error; counted=didRecord; done=YES;
        }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while (!done && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Expect(@"authorized capture completes",done);
    if (outError) *outError=failure; if(recorded)*recorded=counted; return result;
}
static NSDictionary* CopyHint(SPDFReadOnlyCopyResolution result) {
    NSMutableDictionary* hint=[result.fingerprintBinding mutableCopy]; hint[@"path"]=result.workingPath; return hint;
}
static void CheckCollectionAuthorizedCopy(void) {
    NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* source=[sandbox stringByAppendingPathComponent:@"Safari.pdf"];
    NSString* copy=[sandbox stringByAppendingPathComponent:@"reader.pdf"];
    PDFDocument* encrypted=[[PDFDocument alloc] initWithData:PlainPDF()];
    [encrypted writeToFile:source withOptions:@{PDFDocumentOwnerPasswordOption:@"owner-secret",PDFDocumentUserPasswordOption:@"reader-secret"}];
    [fm setAttributes:@{NSFilePosixPermissions:@0400} ofItemAtPath:source error:nil];
    __block NSUInteger authorizations=0;
    SPDFReadOnlyCopyResolution resolved=SPDFResolveReadOnlyCopy(source,copy,nil,^{++authorizations;});
    Expect(@"fresh authorized read binds both files",resolved.hasCopyBinding && authorizations==1 &&
        SPDFReadOnlyCopyBindingMatches(resolved.fingerprintBinding,source,copy));
    NSData* originalBytes=[NSData dataWithContentsOfFile:copy];
    Method original=class_getClassMethod(NSData.class,@selector(dataWithContentsOfFile:options:error:));
    Method intercepted=class_getClassMethod(NSData.class,@selector(spdf_testReadFile:options:error:));
    method_exchangeImplementations(original,intercepted);
    DeniedCaptureSource=source; DeniedCaptureReads=0;
    @try {
        NSDictionary* legacyAttributes=@{NSFileSize:@(resolved.fileSize),NSFileModificationDate:resolved.modificationDate};
        Expect(@"legacy launch/preload remains lazy and readable without source access",
            SPDFReuseLegacyReadOnlyCopy(copy,resolved.fileSize,resolved.modificationDate,legacyAttributes,YES) && DeniedCaptureReads==0);
        Expect(@"explicit consultation does not retain unproven legacy metadata",
            !SPDFReuseLegacyReadOnlyCopy(copy,resolved.fileSize,resolved.modificationDate,legacyAttributes,NO));
        Expect(@"malformed YAML binding does not crash or validate",
            !SPDFReadOnlyCopyBindingMatches(@{@"source":@1,@"copy":@2},source,copy));
        SPDFReadOnlyCopyResolution reused=SPDFResolveReadOnlyCopy(source,copy,resolved.fingerprintBinding,^{++authorizations;});
        Expect(@"bound restored copy reuses without source read or authorization",reused.hasCopyBinding && authorizations==1 && DeniedCaptureReads==0);
        SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]]];
        Expect(@"constructing store does not schedule capture",store.captureQueue==nil);
        [store updateSettings:@{@"choice":@"enabled"} error:nil];
        NSError* error=nil; BOOL recorded=NO;
        // Reproduces the previous lifecycle: document is visible from its copy,
        // yet the Collection hook rereads and fails the inaccessible original.
        Expect(@"old direct-source capture fails after permission expires",![store capturePath:source reason:@"Opened" error:&error] && error.code==NSFileReadNoPermissionError);
        DeniedCaptureReads=0;
        NSDictionary* row=WaitAuthorizedCapture(store,source,CopyHint(resolved),&error,&recorded);
        Expect(@"authorized copy repairs failed history without rereading source",row && !error && recorded && DeniedCaptureReads==0 &&
            [row[@"path"] isEqual:source] && [row[@"sourceFingerprint"] isEqual:SPDFCollectionFingerprint(source)] &&
            [row[@"openCount"] unsignedIntegerValue]==1 && [row[@"versions"] count]==1);
        if (!row) { [fm removeItemAtPath:sandbox error:nil]; return; }
        NSDictionary* version=[row[@"versions"] lastObject];
        NSURL* archived=[store materializeVersionID:version[@"id"] documentID:row[@"id"] error:nil];
        Expect(@"raw encrypted bytes and privacy preserved",[version[@"encrypted"] boolValue] && !version[@"indexFile"] &&
            [[NSData dataWithContentsOfURL:archived] isEqual:originalBytes]);
        // Deliberately clear reuse proof: the edit gate must not borrow the
        // reader-only hint even when invoked within an existing capture context.
        NSString* contextKey=[NSString stringWithFormat:@"SPDFCollectionCapture.%p",store];
        NSDictionary* context=@{@"path":SPDFCollectionPath(source),@"epoch":@"",@"userOpenState":@{@"authorizedCopy":CopyHint(resolved),@"explicitOpen":@YES}};
        [store transaction:^BOOL(NSMutableDictionary* m,NSError** e) {(void)e;[m[@"documents"][row[@"id"]] removeObjectForKey:@"sourceFingerprint"];return YES;} error:nil];
        NSThread.currentThread.threadDictionary[contextKey]=context;
        Expect(@"edit protection never falls back to reader hint",![store ensureProtectedPath:source reason:@"Edit" error:&error] && DeniedCaptureReads>0);
        Expect(@"nested capture restores request context",NSThread.currentThread.threadDictionary[contextKey]==context);
        [NSThread.currentThread.threadDictionary removeObjectForKey:contextKey];

        // Same size/date is insufficient: replace inode while preserving mtime.
        DeniedCaptureSource=nil;
        NSDictionary* attrs=[fm attributesOfItemAtPath:source error:nil];
        [originalBytes writeToFile:source atomically:YES];
        [fm setAttributes:@{NSFileModificationDate:attrs[NSFileModificationDate],NSFilePosixPermissions:@0400} ofItemAtPath:source error:nil];
        DeniedCaptureSource=source; DeniedCaptureReads=0;
        SPDFMacCollectionStore* stale=[[SPDFMacCollectionStore alloc] initWithRootURL:[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Stale"]]];
        [stale updateSettings:@{@"choice":@"enabled"} error:nil];
        Expect(@"same-size/date replacement rejects stale source identity",!WaitAuthorizedCapture(stale,source,CopyHint(resolved),&error,NULL) &&
            error.code==5 && [[stale documentForPath:source][@"versions"] count]==0 && DeniedCaptureReads==0);
        DeniedCaptureSource=nil;
        resolved=SPDFResolveReadOnlyCopy(source,copy,resolved.fingerprintBinding,^{++authorizations;});
        Expect(@"consulted changed identity renews bound copy",resolved.hasCopyBinding && authorizations==2);
        // Suspend worker so the original immutable hint becomes stale in queue.
        stale.captureQueue.suspended=YES;
        __block BOOL done=NO; __block NSError* queuedError;
        [stale capturePath:source authorizedCopy:CopyHint(resolved) reason:@"Opened" continuingDocumentID:nil userOpenCount:1
            completion:^(NSDictionary* row,NSError* failure,BOOL didCount){(void)row;(void)didCount;queuedError=failure;done=YES;}];
        [@"different shadow" writeToFile:copy atomically:YES encoding:NSUTF8StringEncoding error:nil];
        DeniedCaptureSource=source; DeniedCaptureReads=0; stale.captureQueue.suspended=NO;
        NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!done && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Expect(@"queued shadow replacement rejected across retries without source fallback",done && queuedError.code==5 &&
            [[stale documentForPath:source][@"versions"] count]==0 && DeniedCaptureReads==0);
    } @finally { DeniedCaptureSource=nil; method_exchangeImplementations(original,intercepted); }
    [fm removeItemAtPath:sandbox error:nil];
}
