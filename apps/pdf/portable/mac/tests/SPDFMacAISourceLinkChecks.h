// The reported citation, word for word, and what the chat does with it: which file its ID names, whether it stays a
// link, and the source card under it. Pure; no reader, Collection or window.
#import <CommonCrypto/CommonDigest.h>
static NSString* SourceIdentifier(NSString* path) {  // SPDFAIDocumentIdentifier's hash, which this suite does not link
    NSData* data=[path.stringByStandardizingPath dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString* result=[NSMutableString stringWithString:@"doc:"];
    for (NSUInteger i=0;i<sizeof(digest);i++) [result appendFormat:@"%02x",digest[i]];
    return result;
}
static NSString* const ReportedAnswer=@"The \"IR at 100%\" figure appears only in **`OV50X_Before_vs_IR_On_4_Images.pdf`** — "
    "2 pages (\"8K – earlier vs IR on\" and \"Binned – earlier vs IR on\"), where the new frame notes \"IR at 100%; filter "
    "fitted\" [OV50X_Before_vs_IR_On_4_Images · p. 1](spdf-ai://document?path=doc:cfe318d84a9b708a7162b3d1bb5982fe21a47cc8f11fc0901d4930381b9062ad"
    "&page=1&revision=16777231:48755348:106945084:1792063145:28289975:1792063145:28993103). Note it is a filter/IR-blocking "
    "test (earlier vs IR on), not a controlled IR-off/IR-on measurement; the OV50Q40 doc uses 4 kHz PWM at 10% duty instead.";
static void CheckSourceLinks(void) {
    // The cited ID is the hash of the Collection editable copy History opened for the earlier revision, not of the
    // document's source file, which is what a Collection row's path holds.
    NSString* copy=@"/Users/raph/Library/Application Support/ShenzhenPDF/Collection/editable/4F17B704-EDC7-4310-8DDF-"
        "6CD981B30371/C7E545D3-C2AE-4554-9745-F3A63A73F995/OV50X_Before_vs_IR_On_4_Images.pdf";
    NSString* original=@"/Users/raph/Projects/Blackstar_Dothinkey_Controller_Mac/output/pdf/OV50X_Before_vs_IR_On_4_Images.pdf";
    NSString* cited=@"doc:cfe318d84a9b708a7162b3d1bb5982fe21a47cc8f11fc0901d4930381b9062ad";
    CHECK([SourceIdentifier(copy) isEqual:cited] && ![SourceIdentifier(original) isEqual:cited],
        "the reported citation names the editable copy, not the source file");
    NSDictionary* link=SPDFMacAIDocumentLinkArguments([NSURL URLWithString:[ReportedAnswer substringWithRange:
        [ReportedAnswer rangeOfString:@"spdf-ai://[^)]+" options:NSRegularExpressionSearch]]]);
    CHECK([link isEqual:(@{@"path":cited,@"page":@1})],"the reported link is well formed: its ID and page 1");
    NSDictionary* row=@{@"id":@"4F17B704-EDC7-4310-8DDF-6CD981B30371",@"path":original,@"aliases":@[original],
        @"editablePaths":@[copy]};
    NSString* (^identify)(NSString*)=^NSString*(NSString* path) { return SourceIdentifier(path); };
    CHECK([SPDFMacAIResolveDocumentLink(link,nil,nil,@[row],identify) isEqual:@{@"path":copy}],
        "with its tab closed, the citation opens that exact editable copy");
    NSMutableDictionary* before=[row mutableCopy]; [before removeObjectForKey:@"editablePaths"];
    CHECK(!SPDFMacAIResolveDocumentLink(link,nil,@[original],@[before],identify),
        "without the copy, nothing else answers to the ID: no match by name or source");
    CHECK([SPDFMacAIResolveDocumentLink(link,@[copy],nil,@[row],identify) isEqual:@{@"path":copy}],
        "an open tab of the copy is still found first");

    // The chat: one document cited, so a card; gone, plain words and no card.
    NSDictionary* shown=SPDFMacAIAnswerPresentation(ReportedAnswer,^BOOL(NSURL* URL){ (void)URL; return YES; });
    CHECK([shown[@"text"] isEqual:ReportedAnswer],"an available citation is left exactly as the model wrote it");
    CHECK([shown[@"source"][@"title"] isEqual:@"OV50X_Before_vs_IR_On_4_Images"] && [shown[@"source"][@"page"] isEqual:@1] &&
        [[shown[@"source"][@"link"] absoluteString] containsString:cited],"the one cited document gets a card: title, page 1");
    NSDictionary* gone=SPDFMacAIAnswerPresentation(ReportedAnswer,^BOOL(NSURL* URL){ (void)URL; return NO; });
    CHECK(![gone[@"text"] containsString:@"spdf-ai://"] && [gone[@"text"] containsString:
        @"filter fitted\" OV50X_Before_vs_IR_On_4_Images · p. 1. Note"] && !gone[@"source"],
        "a citation of a document that is gone is plain words, with no card");

    // Several documents: a card only for the one the model names as its main source, whose line then goes.
    NSString* a=@"spdf-ai://document?path=doc:a&page=3&revision=r", *b=@"spdf-ai://document?path=doc:b&page=1&revision=r";
    NSString* two=[NSString stringWithFormat:@"Stated in [A · p. 3](%@) and [B · p. 1](%@).",a,b];
    CHECK(!SPDFMacAIAnswerPresentation(two,nil)[@"source"],"two documents and no main source: no card");
    NSDictionary* main=SPDFMacAIAnswerPresentation([two stringByAppendingFormat:@"\n\nMain source: [B · p. 1](%@)",b],nil);
    CHECK([[main[@"source"][@"link"] absoluteString] isEqual:b] && [main[@"text"] isEqual:two],
        "the main source gets the card and its line leaves the answer");
    NSDictionary* same=SPDFMacAIAnswerPresentation([NSString stringWithFormat:@"See [A · p. 3](%@) and [A, page 5](%@)",
        a,[a stringByReplacingOccurrencesOfString:@"page=3" withString:@"page=5"]],nil);
    BOOL first=[same[@"source"][@"page"] isEqual:@3] && [same[@"source"][@"title"] isEqual:@"A"];
    CHECK(first,
        "two pages of one document are still one source; the card shows the first page cited");
    NSDictionary* stop=SPDFMacAIAnswerPresentation([NSString stringWithFormat:@"In [A · p. 3](%@.)",a],nil);
    NSString* moved=[NSString stringWithFormat:@"In [A · p. 3](%@).",a];
    CHECK([stop[@"text"] isEqual:moved] && [[stop[@"source"][@"link"] absoluteString] isEqual:a],
        "a full stop typed inside the link moves after it");
}
