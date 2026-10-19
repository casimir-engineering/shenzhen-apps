// Isolated store: no user library, source permissions or app launch involved.
static void CheckHistoryDeletion(void) {
    NSString* sandbox=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:sandbox withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL* root=[NSURL fileURLWithPath:[sandbox stringByAppendingPathComponent:@"Collection"]];
    SPDFMacCollectionStore* store=[[SPDFMacCollectionStore alloc] initWithRootURL:root];
    [store updateSettings:@{@"choice":@"enabled"} error:nil];
    NSString* path=[sandbox stringByAppendingPathComponent:@"Document.txt"];
    Write(path,@"Revision A"); NSDictionary* doc=Capture(store,path,@"Opened"); NSString* docID=doc[@"id"];
    NSDictionary* first=[store versionsForDocumentID:docID].lastObject;
    Write(path,@"Revision B"); Capture(store,path,@"External change");
    NSDictionary* second=[store versionsForDocumentID:docID].lastObject;
    Write(path,@"Revision A"); Capture(store,path,@"External change");
    NSDictionary* latest=[store versionsForDocumentID:docID].lastObject;
    Expect(@"reverts retain chronology without duplicating stored bytes",[store versionsForDocumentID:docID].count==3 &&
        [first[@"hash"] isEqual:latest[@"hash"]] &&
        [[NSFileManager.defaultManager contentsOfDirectoryAtURL:[root URLByAppendingPathComponent:@"objects"]
            includingPropertiesForKeys:nil options:0 error:nil] count]==2);
    NSString* twin=[sandbox stringByAppendingPathComponent:@"Twin.txt"]; Write(twin,@"Revision B");
    NSDictionary* twinDoc=Capture(store,twin,@"Opened");
    [store setKeep:YES versionID:first[@"id"] documentID:docID error:nil];
    Expect(@"clear previous backups succeeds",[store deletePreviousBackupsForDocumentID:docID error:nil]);
    NSArray* retained=[store versionsForDocumentID:docID];
    Expect(@"clear previous retains latest snapshot identity",retained.count==1 && [retained[0][@"id"] isEqual:latest[@"id"]]);
    Expect(@"clear previous keeps original and source binding",[[NSString stringWithContentsOfFile:path
        encoding:NSUTF8StringEncoding error:nil] isEqual:@"Revision A"] && [[store documentForPath:path][@"id"] isEqual:docID]);
    Expect(@"clear previous preserves shared blobs referenced by other documents",
        [store materializeVersionID:second[@"id"] documentID:docID error:nil]==nil &&
        [store materializeVersionID:[store versionsForDocumentID:twinDoc[@"id"]].lastObject[@"id"] documentID:twinDoc[@"id"] error:nil]!=nil);
    Expect(@"latest survives reopen",[[[[SPDFMacCollectionStore alloc] initWithRootURL:root]
        versionsForDocumentID:docID].lastObject[@"id"] isEqual:latest[@"id"]]);
    Write(path,@"Revision C"); Capture(store,path,@"External change");
    NSDictionary* newest=[store versionsForDocumentID:docID].lastObject;
    Expect(@"individual version deletion succeeds",[store deleteDocumentID:docID versionID:latest[@"id"] error:nil]);
    Expect(@"individual deletion keeps another version",[store versionsForDocumentID:docID].count==1 &&
        [[store versionsForDocumentID:docID].lastObject[@"id"] isEqual:newest[@"id"]]);
    Expect(@"unshared deleted blob reclaimed",![NSFileManager.defaultManager fileExistsAtPath:
        [[root URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:first[@"hash"]].path]);
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    Expect(@"missing original still keeps latest backup",[store deletePreviousBackupsForDocumentID:docID error:nil] &&
        [store materializeVersionID:newest[@"id"] documentID:docID error:nil]!=nil);
    Expect(@"missing history reports failure",![store deletePreviousBackupsForDocumentID:@"missing" error:nil]);
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
}
