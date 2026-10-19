#pragma once
static void CheckPageImageTool(NSString* path) {
    AIContextProbe* reader=[AIContextProbe new];
    reader.testCandidates=@[@{@"path":path,@"readPath":path,@"title":@"Evidence.pdf",
        @"revision":SPDFSearchFileStamp(path)}];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check([tools valueForKey:@"queue"]==nil && reader.candidateCalls==0,"image tools initialize without rendering or document reads");
    NSDictionary* region=@{@"x":@0.1,@"y":@0.2,@"width":@0.5,@"height":@0.25};
    NSMutableDictionary* args=[@{@"path":SPDFAIDocumentIdentifier(path),@"page":@1,
        @"maxDimension":@800,@"region":region} mutableCopy];
    __block NSDictionary* result=nil;
    [tools performTool:@"render_page" arguments:args completion:^(NSDictionary* value){result=value;}];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:10];
    while(!result && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(result && !result[@"error"] && [result[@"rendered"] boolValue],"assistant can request cropped page through real tool dispatch");
    Check([result[@"path"] isEqual:SPDFAIDocumentIdentifier(path)] && [result[@"citation"] containsString:@"doc:"],"image tool keeps opaque identity and page citation");
    Check([result[@"region"] isEqual:region] && [result[@"pixelWidth"] unsignedIntegerValue]<=800 &&
        [result[@"pixelHeight"] unsignedIntegerValue]<=401,"tool exposes exact region and bounded pixel dimensions");
    NSDictionary* preview=result[@"_localPreview"];
    Check([NSData dataWithContentsOfFile:preview[@"path"]].length>0 && [preview[@"region"] isEqual:region],"tool supplies actual crop asset for vision delivery");
    [NSFileManager.defaultManager removeItemAtPath:[preview[@"path"] stringByDeletingLastPathComponent] error:nil];
    for(NSDictionary* invalid in @[@{@"maxDimension":@2401},@{@"region":@{@"x":@0.8,@"y":@0,@"width":@0.5,@"height":@1}}]) {
        NSMutableDictionary* request=[args mutableCopy]; [request addEntriesFromDictionary:invalid]; result=nil;
        [tools performTool:@"render_page" arguments:request completion:^(NSDictionary* value){result=value;}];
        deadline=[NSDate dateWithTimeIntervalSinceNow:5];
        while(!result && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        Check(result[@"error"] && !result[@"_localPreview"],"invalid image dimensions/regions rejected through tool dispatch");
    }
}
