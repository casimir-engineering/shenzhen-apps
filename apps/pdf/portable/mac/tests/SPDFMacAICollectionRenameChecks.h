static void CheckAICollectionRename(AIContextProbe* reader,SPDFMacCollectionStore* store,NSDictionary* document,NSString* copyPath,SPDFTabGroup* group) {
    // Distinct document title and working filename must both survive Undo.
    NSURL* initial=[store renameEditablePath:copyPath filename:@"Working copy.pdf" documentTitle:@"Collection title.pdf"
        expectedTitle:document[@"title"] error:nil];
    Check(initial!=nil,"Collection rename fixture prepared");
    copyPath=initial.path; NSDictionary* before=[store editableInfoForPath:copyPath][@"document"];
    NSData* originalBytes=[NSData dataWithContentsOfFile:copyPath];
    SPDFDocumentTab* tab=Tab(copyPath,group); [reader seedTabs:@[tab]];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    NSString* name=@"SW-1302 - slide switch - datasheet";
    NSString* renamedPath=[copyPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"pdf"]];
    __block NSDictionary* result;
    NSDictionary* args=@{@"path":SPDFAIDocumentIdentifier(copyPath),@"name":name,@"revision":SPDFSearchFileStamp(copyPath)};
    [tools performTool:@"rename_document" arguments:args completion:^(NSDictionary* value){result=value;}];
    Check([result[@"renamed"] boolValue] && [result[@"undoable"] boolValue],"AI tool directly renames Collection copy with Undo");
    Check([tab.path isEqual:renamedPath] && tab.group==group && ![NSFileManager.defaultManager fileExistsAtPath:copyPath],"rename replaces tab path in its original group");
    NSDictionary* after=[store editableInfoForPath:renamedPath][@"document"];
    Check([after[@"title"] isEqual:renamedPath.lastPathComponent] && [after[@"path"] isEqual:before[@"path"]] &&
        [after[@"id"] isEqual:before[@"id"]] && [after[@"versions"] isEqual:before[@"versions"]],"rename preserves source identity and every historical version");
    Check([[NSData dataWithContentsOfFile:renamedPath] isEqual:originalBytes],"Collection rename preserves exact document bytes");
    Check([tools undoLastAction:nil] && [tab.path isEqual:copyPath],"AI Undo restores Collection filename and tab");
    Check([[[store editableInfoForPath:copyPath] objectForKey:@"document"][@"title"] isEqual:before[@"title"]],"Undo restores distinct previous Collection title exactly");
    NSProgress* cancelled=[NSProgress progressWithTotalUnitCount:1];[cancelled cancel];
    Check([reader aiRenameDocument:@{@"path":copyPath,@"name":name,@"revision":SPDFSearchFileStamp(copyPath)} progress:cancelled][@"error"]!=nil,"cancelled rename cannot mutate Collection");
    Check([reader aiRenameDocument:@{@"path":copyPath,@"name":name,@"revision":@"stale"} progress:[NSProgress progressWithTotalUnitCount:1]][@"error"]!=nil,"stale Collection rename rejected");
    [originalBytes writeToFile:renamedPath atomically:YES];
    Check([reader aiRenameDocument:@{@"path":copyPath,@"name":name,@"revision":SPDFSearchFileStamp(copyPath)} progress:[NSProgress progressWithTotalUnitCount:1]][@"error"]!=nil,"rename collision never overwrites another file");
    Check([[[store editableInfoForPath:copyPath] objectForKey:@"document"][@"title"] isEqual:before[@"title"]],"failed rename leaves Collection title intact");
    [NSFileManager.defaultManager removeItemAtPath:renamedPath error:nil];
    Check(![store renameEditablePath:copyPath filename:[name stringByAppendingPathExtension:@"pdf"]
        documentTitle:name expectedTitle:@"An outdated title" error:nil],"atomic title guard rejects a concurrent Collection rename");
    Check([NSFileManager.defaultManager fileExistsAtPath:copyPath],"title conflict leaves the working file untouched");
    result=nil;
    [tools performTool:@"rename_document" arguments:@{@"path":SPDFAIDocumentIdentifier(copyPath),@"name":name,@"revision":SPDFSearchFileStamp(copyPath)} completion:^(NSDictionary* value){result=value;}];
    Check([result[@"renamed"] boolValue],"second Collection rename succeeds");
    // A separate human rename changes the Collection title, without changing this copy's bytes.
    NSURL* human=[store renameEditablePath:renamedPath filename:@"Human name.pdf" error:nil];
    Check(human && ![tools undoLastAction:nil],"AI Undo refuses to overwrite a later human rename");
    fprintf(stdout,"AI Collection rename, source/history preservation, cancellation and Undo passed\n");
}
