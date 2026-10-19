#pragma once
// Exercise actual retrieval, rendering and navigation, not just schema acceptance.
static void CheckOptionalRevisions(NSString* path) {
    NSString* identifier=SPDFAIDocumentIdentifier(path);
    NSString* revision=SPDFSearchFileStamp(path);
    AICitationReaderProbe* reader=[AICitationReaderProbe new];
    [reader seedPaths:@[path]];
    SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:reader];
    Check([tools valueForKey:@"queue"]==nil,"optional revision handling creates no worker before use");
    for (NSString* name in @[@"read_pages",@"render_page",@"show_document"]) {
        NSMutableDictionary* args=[@{@"path":identifier,@"page":@1} mutableCopy];
        for (id supplied in @[NSNull.null,@"",revision]) {
            if (supplied==NSNull.null) [args removeObjectForKey:@"revision"];
            else args[@"revision"]=supplied;
            NSDictionary* result=CitationTool(tools,name,args);
            Check(!result[@"error"],"omitted, empty and exact optional revisions execute successfully");
            if ([name isEqual:@"read_pages"])
                Check([result[@"pages"][0][@"text"] containsString:@"Audio amplifier"],"empty revision returns actual page text");
            else if ([name isEqual:@"render_page"])
                Check([result[@"rendered"] boolValue] && [NSData dataWithContentsOfFile:result[@"_localPreview"][@"path"]].length>0,
                      "empty revision returns actual page pixels");
            else Check([result[@"opened"] boolValue],"empty revision completes reader navigation");
            [SPDFMacAIChatStore discardTemporaryPreview:result[@"_localPreview"]];
        }
        // Validate before allocating a retrieval worker, including malformed JSON
        // types. Whitespace is a supplied revision, not an omission to trim away.
        for (id supplied in @[@"stale",@" ",NSNull.null,@1,@[]]) {
            SPDFMacAITools* rejected=[[SPDFMacAITools alloc] initWithReader:reader];
            args[@"revision"]=supplied;
            NSDictionary* result=CitationTool(rejected,name,args);
            Check(result[@"error"] && !result[@"pages"] && !result[@"_localPreview"] && !result[@"opened"],
                  "stale or malformed optional revision is rejected without evidence or navigation");
            Check([rejected valueForKey:@"queue"]==nil,"invalid revisions never start document work");
        }
    }
    NSDictionary* rename=CitationTool(tools,@"rename_document",@{@"path":identifier,@"name":@"should-not-rename.pdf",@"revision":@""});
    NSDictionary* rotate=CitationTool(tools,@"reader_control",@{@"path":identifier,@"control":@"rotate",@"value":@"clockwise",@"revision":@""});
    Check(rename[@"error"] && rotate[@"error"] && [SPDFSearchFileStamp(path) isEqual:revision],
          "empty write revisions cannot rename or rotate the document");
}
