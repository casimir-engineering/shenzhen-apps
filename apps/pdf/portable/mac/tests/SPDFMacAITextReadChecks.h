#pragma once
// A sparse PDF still takes the original text-read path. Page pixels remain an
// explicit render_page/current_view request, not an extra input to every read.
static void CheckTextOnlyPageRead(NSString* path) {
    AIContextProbe* reader=[AIContextProbe new];
    reader.testCandidates=@[@{@"path":path,@"readPath":path,@"title":path.lastPathComponent,
        @"revision":SPDFSearchFileStamp(path)}];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check([tools valueForKey:@"queue"]==nil && !reader.candidateCalls,"page reading does no work before a request");
    __block NSDictionary* result=nil;
    [tools performTool:@"read_pages" arguments:@{@"path":SPDFAIDocumentIdentifier(path),@"page":@1,@"count":@3}
        completion:^(NSDictionary* value){result=value;}];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while (!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    Check(result && !result[@"error"] && [result[@"pages"] count]>0,"sparse document text read completes");
    Check(!result[@"_localPreview"] && !result[@"visualPreviewPage"] && !result[@"sparseTextPages"] &&
        !result[@"textCoverage"] && !result[@"visualCoverage"],"text reads retain the pre-card result without injected images or guidance");
    NSDictionary* page=[result[@"pages"] firstObject];
    Check([page[@"text"] length]>0 && [page[@"citation"] length]>0,"text read keeps source text and exact page citation");
}
