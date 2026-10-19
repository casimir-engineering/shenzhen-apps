// Capture-time recovery is part of the normal background job, never a launch scan.
static void CheckAutomaticRelink(void) {
    NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager* files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:
        [NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]]];
    Expect(@"relink adds no work during lazy construction",![files fileExistsAtPath:store.rootURL.path]);
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSString* original=[sandbox stringByAppendingPathComponent:@"Original.md"];
    NSString* renamed=[sandbox stringByAppendingPathComponent:@"Renamed.md"];
    Write(original,@"# Old retained text");
    NSDictionary* doc=Capture(store,original,@"Opened"); NSString* identifier=doc[@"id"];
    NSDictionary* first=[store versionsForDocumentID:identifier].firstObject;
    [store setKeep:YES versionID:first[@"id"] documentID:identifier error:nil];
    Write(original,@"# Latest retained text"); Capture(store,original,@"Saved annotation");
    NSArray* versions=[store versionsForDocumentID:identifier];
    [files copyItemAtPath:original toPath:renamed error:nil];
    struct stat originalInfo={}, copyInfo={}; stat(original.fileSystemRepresentation,&originalInfo);
    stat(renamed.fileSystemRepresentation,&copyInfo);
    Expect(@"relink fixture has a different inode",originalInfo.st_ino!=copyInfo.st_ino);
    [files removeItemAtPath:original error:nil];
    __block BOOL finished=NO; __block NSDictionary* relinked=nil; __block NSError* error=nil;
    [store capturePath:renamed reason:@"Opened" continuingDocumentID:nil userOpenCount:1
        completion:^(NSDictionary* row,NSError* failure,BOOL counted) {
            relinked=row; error=failure; finished=YES;
            Expect(@"automatic relink records explicit open once",counted && [row[@"openCount"] integerValue]==1);
        }];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!finished && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Expect(@"background capture relinks matching bytes with a different inode",finished && !error && [relinked[@"id"] isEqual:identifier]);
    Expect(@"latest-hash relink preserves every version and Keep without a duplicate",[[store versionsForDocumentID:identifier] isEqual:versions]);
    Expect(@"relink updates current path while retaining old alias",[relinked[@"path"] isEqual:renamed] &&
        [relinked[@"aliases"] containsObject:original] && [relinked[@"status"] isEqual:@"Protected"]);
    SPDFMacCollectionStore* reopened=[[SPDFMacCollectionStore alloc] initWithRootURL:store.rootURL];
    Expect(@"relinked identity persists across store instances",[[reopened documentForPath:renamed][@"id"] isEqual:identifier]);

    // A known old copy becomes today's current revision without erasing intervening history.
    NSString* older=[sandbox stringByAppendingPathComponent:@"Old copy.md"];
    Write(older,@"# Old retained text"); [files removeItemAtPath:renamed error:nil];
    NSDictionary* oldLinked=Capture(store,older,@"Opened");
    NSArray* restored=[store versionsForDocumentID:identifier];
    Expect(@"older hash relinks the same history",[oldLinked[@"id"] isEqual:identifier] && restored.count==3);
    Expect(@"older copy is appended as current and all previous versions survive",restored.count==3 &&
        [[restored subarrayWithRange:NSMakeRange(0,2)] isEqual:versions] &&
        [restored.lastObject[@"hash"] isEqual:first[@"hash"]] && ![restored.lastObject[@"id"] isEqual:first[@"id"]]);

    NSString* twin=[sandbox stringByAppendingPathComponent:@"Independent twin.md"];
    Write(twin,@"# Old retained text"); NSDictionary* twinDoc=Capture(store,twin,@"Opened");
    Expect(@"available original is never hijacked by an identical copy",![twinDoc[@"id"] isEqual:identifier] &&
        [[store documentForPath:older][@"id"] isEqual:identifier]);
    [files removeItemAtPath:older error:nil]; [files removeItemAtPath:twin error:nil];
    NSString* ambiguous=[sandbox stringByAppendingPathComponent:@"Ambiguous.md"];
    Write(ambiguous,@"# Old retained text"); NSDictionary* ambiguousDoc=Capture(store,ambiguous,@"Opened");
    Expect(@"ambiguous matching histories are not chosen arbitrarily",![ambiguousDoc[@"id"] isEqual:identifier] &&
        ![ambiguousDoc[@"id"] isEqual:twinDoc[@"id"]] && [store versionsForDocumentID:identifier].count==3);
    Expect(@"ambiguous histories retain their lost paths",[[store documentForPath:older][@"path"] isEqual:older] &&
        [[store documentForPath:twin][@"path"] isEqual:twin]);

    NSString* replaced=[sandbox stringByAppendingPathComponent:@"Replaced.md"];
    NSString* found=[sandbox stringByAppendingPathComponent:@"Found original.md"];
    Write(replaced,@"# Unique replaced original"); NSDictionary* replacedDoc=Capture(store,replaced,@"Opened");
    [files copyItemAtPath:replaced toPath:found error:nil];
    Write(replaced,@"# Different document occupying the original path");
    NSDictionary* occupying=Capture(store,replaced,@"Opened");
    NSDictionary* foundDoc=Capture(store,found,@"Opened");
    Expect(@"found original restores replaced history without stale unavailable flags",
        [foundDoc[@"id"] isEqual:replacedDoc[@"id"]] && ![foundDoc[@"sourceReplaced"] boolValue] &&
        ![foundDoc[@"originalUnavailable"] boolValue] && [foundDoc[@"status"] isEqual:@"Protected"]);
    Expect(@"relink leaves the unrelated occupant and its history untouched",
        [[store documentForPath:replaced][@"id"] isEqual:occupying[@"id"]] &&
        [[NSString stringWithContentsOfFile:replaced encoding:NSUTF8StringEncoding error:nil]
            isEqual:@"# Different document occupying the original path"]);

    // Permission failures are not evidence that the original is gone.
    NSString* restricted=[sandbox stringByAppendingPathComponent:@"Restricted"];
    [files createDirectoryAtPath:restricted withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* hidden=[restricted stringByAppendingPathComponent:@"Private.md"];
    Write(hidden,@"# Unique restricted source"); NSDictionary* hiddenDoc=Capture(store,hidden,@"Opened");
    [files setAttributes:@{NSFilePosixPermissions:@0000} ofItemAtPath:restricted error:nil];
    NSString* visible=[sandbox stringByAppendingPathComponent:@"Readable copy.md"];
    Write(visible,@"# Unique restricted source"); NSDictionary* visibleDoc=Capture(store,visible,@"Opened");
    [files setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:restricted error:nil];
    Expect(@"unreadable original is never mistaken for missing",![visibleDoc[@"id"] isEqual:hiddenDoc[@"id"]]);
    NSString* excluded=[sandbox stringByAppendingPathComponent:@"Excluded.md"];
    Write(excluded,@"# Unique excluded source"); NSDictionary* excludedDoc=Capture(store,excluded,@"Opened");
    [store setExcluded:YES documentID:excludedDoc[@"id"] error:nil]; [files removeItemAtPath:excluded error:nil];
    NSString* excludedCopy=[sandbox stringByAppendingPathComponent:@"New independent source.md"];
    Write(excludedCopy,@"# Unique excluded source"); NSDictionary* independent=Capture(store,excludedCopy,@"Opened");
    Expect(@"automatic relink does not repurpose an excluded history",![independent[@"id"] isEqual:excludedDoc[@"id"]]);
    [files removeItemAtPath:excludedCopy error:nil];
    NSString* alsoExcluded=[sandbox stringByAppendingPathComponent:@"Ambiguous excluded copy.md"];
    Write(alsoExcluded,@"# Unique excluded source"); NSDictionary* noPreference=Capture(store,alsoExcluded,@"Opened");
    Expect(@"exclusion does not resolve ambiguous document identity",![noPreference[@"id"] isEqual:independent[@"id"]] &&
        ![noPreference[@"id"] isEqual:excludedDoc[@"id"]]);
    [files removeItemAtPath:sandbox error:nil];
}
