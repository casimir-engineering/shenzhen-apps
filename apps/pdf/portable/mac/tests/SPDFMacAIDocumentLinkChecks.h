// Document links without retrieved evidence: what they name and where it is found.
static void CheckDocumentLinks(void) {
    NSDictionary* link=SPDFMacAIDocumentLinkArguments([NSURL URLWithString:
        @"spdf-ai://document?path=doc:abc&page=3&revision=old&query=invented&extra=ignored"]);
    CHECK([link isEqual:(@{@"path":@"doc:abc",@"page":@3})],
        "a document link keeps its document and page and drops revision and passage");
    CHECK([SPDFMacAIDocumentLinkArguments([NSURL URLWithString:@"spdf-ai://document?documentID=collection:42"])
        isEqual:@{@"path":@"collection:42"}],"a Collection document ID is a document link");
    CHECK([SPDFMacAIDocumentLinkArguments([NSURL URLWithString:@"spdf-ai://document?path=doc:abc&page=zero"])
        isEqual:@{@"path":@"doc:abc"}],"a malformed page still opens the document");
    CHECK(!SPDFMacAIDocumentLinkArguments([NSURL URLWithString:@"spdf-ai://document?path=/etc/hosts"]) &&
        !SPDFMacAIDocumentLinkArguments([NSURL URLWithString:@"https://document?path=doc:abc"]),
        "filesystem paths and other schemes are not document links");
    CHECK(!SPDFMacAIDocumentNameLink(@"../a.pdf") && !SPDFMacAIDocumentNameLink(@"notes") &&
        !SPDFMacAIDocumentNameLink(@"x:y.pdf") && SPDFMacAIDocumentNameLink(@"Plan%20B.pdf"),
        "a file name becomes a document link; a parent folder or scheme does not");
    CHECK(!SPDFMacAIDocumentNameLink(@"example.com") && !SPDFMacAIDocumentNameLink(@"www.example.org") &&
        !SPDFMacAIDocumentNameLink(@"allegro.de") && !SPDFMacAIDocumentNameLink(@"example.com/report.pdf"),
        "site names are never document links");
    BOOL files=YES;
    for (NSString* name in @[@"name.sh",@"main.py",@"lib.rs",@"script.pl",@"archive.zip",@"src/app.mm"])
        files=files && [SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentNameLink(name))[@"name"]
            isEqual:name.lastPathComponent];
    CHECK(files,"a code or archive file whose extension is also a country or web domain is a document");
    NSURL* site=[NSURL URLWithString:@"https://example.com"];
    NSDictionary* either=SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentOrSiteLink(@"example.com",site));
    CHECK([either isEqual:(@{@"name":@"example.com",@"site":site})] &&
        [SPDFMacAIDocumentOrSiteLink(@"www.example.org",[NSURL URLWithString:@"https://www.example.org"]).scheme
            isEqual:@"https"] &&
        [SPDFMacAIDocumentOrSiteLink(@"example.com/a",[NSURL URLWithString:@"https://example.com/a"]).scheme
            isEqual:@"https"] && !SPDFMacAIDocumentOrSiteLink(@"example.com",nil),
        "a bare site name also names a document; a www name or a page on a site is only a site");
    CHECK(!SPDFMacAIResolveDocumentLink(either,@[@"/docs/example.pdf"],nil,nil,nil) &&
        [SPDFMacAIResolveDocumentLink(either,nil,@[@"/old/example.com"],nil,nil)
            isEqual:@{@"path":@"/old/example.com"}],
        "a site name opens a known document only of exactly that name");
    CHECK([SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentNameLink(@"budget.numbers"))[@"name"]
            isEqual:@"budget.numbers"] &&
        [SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentNameLink(@"docs/spec.doc"))[@"name"] isEqual:@"spec.doc"] &&
        SPDFMacAIDocumentNameLink(@"Quarterly.xls") && SPDFMacAIDocumentNameLink(@"budget.xlsx") &&
        !SPDFMacAIDocumentNameLink(@"shop.example.co.uk") && !SPDFMacAIDocumentNameLink(@"news.example.io"),
        "a file the reader cannot open is still a document name; a name ending in a domain stays a site");
    CHECK([SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentNameLink(@"docs/Q3%20Report.pdf"))[@"name"]
        isEqual:@"Q3 Report.pdf"] && SPDFMacAIDocumentNameLink(@"./notes.md") &&
        SPDFMacAIDocumentNameLink(@"book.EPUB") && SPDFMacAIDocumentNameLink(@"data.json"),
        "a relative path names its document; documents and text files the reader opens qualify");
    NSString* (^identify)(NSString*)=^NSString*(NSString* path){
        return [@"doc:" stringByAppendingString:path.lastPathComponent];
    };
    NSArray* open=@[@"/docs/Open.pdf"], *recent=@[@"/old/Recent.pdf"];
    NSArray* collection=@[@{@"id":@"7",@"path":@"/gone/Night_Comparison_Full_Resolution.pdf",
        @"title":@"Night Comparison"}];
    CHECK([SPDFMacAIResolveDocumentLink(@{@"path":@"doc:Open.pdf"},open,recent,collection,identify)
        isEqual:@{@"path":@"/docs/Open.pdf"}],"an open document resolves to its tab");
    CHECK([SPDFMacAIResolveDocumentLink(@{@"path":@"doc:Night_Comparison_Full_Resolution.pdf"},open,recent,
        collection,identify)[@"collection"][@"id"] isEqual:@"7"],
        "a document the assistant found in Collection resolves there");
    CHECK([SPDFMacAIResolveDocumentLink(@{@"name":@"night_comparison_full_resolution.PDF"},open,recent,
        collection,identify)[@"collection"] isEqual:collection[0]],"a file name matches regardless of case");
    CHECK([SPDFMacAIResolveDocumentLink(@{@"name":@"Recent.md"},open,recent,collection,identify)
        isEqual:@{@"path":@"/old/Recent.pdf"}],"a name without the right extension still finds the one document");
    CHECK([SPDFMacAIResolveDocumentLink(@{@"path":@"collection:7"},open,recent,collection,identify)[@"collection"]
        isEqual:collection[0]],"a Collection ID resolves to its row");
    CHECK(!SPDFMacAIResolveDocumentLink(@{@"path":@"doc:Missing.pdf"},open,recent,collection,identify) &&
        !SPDFMacAIResolveDocumentLink(@{@"path":@"collection:8"},open,recent,collection,identify),
        "a document that cannot be found resolves to nothing");
}
