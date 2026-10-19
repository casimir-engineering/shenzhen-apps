#import "SPDFMacAIDocumentLinks.h"
// A document link in an answer with no retrieved evidence behind it (the assistant
// found the file in Collection, or named it) opens the document at its page on the
// real reader navigation path. Reuses AICitationReaderProbe; nothing is shown.
static NSString* TwoPagePDF(NSString* root) {
    NSString* path=[root stringByAppendingPathComponent:@"Night_Comparison_Full_Resolution.pdf"];
    CGRect media=CGRectMake(0,0,200,200);
    CGContextRef context=CGPDFContextCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],&media,NULL);
    for(int page=0;page<2;page++){CGPDFContextBeginPage(context,NULL);CGPDFContextEndPage(context);}
    CGPDFContextClose(context);CGContextRelease(context);
    return path;
}
@interface AILinkFallbackProbe : AICitationReaderProbe
@property(nonatomic) NSMutableArray<NSURL*>* webOpens;
@property(nonatomic) NSMutableArray* missingSites;
@end
@implementation AILinkFallbackProbe
- (void)aiOpenWebLink:(NSURL*)URL {
    if(!self.webOpens)self.webOpens=[NSMutableArray array];[self.webOpens addObject:URL];
}
- (void)aiShowMissingDocumentLinkOfferingSite:(NSURL*)site {
    if(!self.missingSites)self.missingSites=[NSMutableArray array];[self.missingSites addObject:site ?: NSNull.null];
}
@end
static void CheckSiteNameLinks(NSString* first) {
    AILinkFallbackProbe* reader=[AILinkFallbackProbe new];[reader seedPaths:@[first]];
    NSURL* site=[NSURL URLWithString:@"https://example.com"];
    [reader aiOpenDocumentLink:SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentOrSiteLink(@"example.com",site))];
    for(NSString* name in @[@"allegro.pl",@"foo.sh",@"src/app.sh",@"Missing.pdf"])
        [reader aiOpenDocumentLink:SPDFMacAIDocumentLinkArguments(SPDFMacAIDocumentNameLink(name))];
    NSDate* deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    while((!reader.webOpens.count || reader.missingSites.count<4) && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    Check(reader.webOpens.count==1 && [reader.webOpens[0] isEqual:site],
        "a site name that is no known document opens the site");
    NSArray* offered=@[[NSURL URLWithString:@"https://allegro.pl"],[NSURL URLWithString:@"https://foo.sh"],
        NSNull.null,NSNull.null];
    Check([[NSCountedSet setWithArray:reader.missingSites] isEqual:[NSCountedSet setWithArray:offered]] &&
        reader.webOpens.count==1,
        "a file name that is also a site says it cannot be found and offers the site; other names offer none");
    NSAlert* alert=SPDFMacAIMissingDocumentAlert(offered[0]);
    Check(alert.buttons.count==2 && [alert.informativeText containsString:@"allegro.pl"] &&
        SPDFMacAIMissingDocumentAlert(nil).buttons.count==1,"only a name that may be a site gets a second button");
    [reader aiFinishMissingDocumentAlert:NSAlertFirstButtonReturn site:offered[0]];
    [reader aiFinishMissingDocumentAlert:NSAlertSecondButtonReturn site:offered[0]];
    Check(reader.webOpens.count==2 && [reader.webOpens[1] isEqual:offered[0]],
        "the second button opens https://allegro.pl; OK opens nothing");
}
static void CheckDocumentLinkNavigation(NSString* first,NSString* root) {
    CheckSiteNameLinks(first);
    NSString* linked=TwoPagePDF(root);
    AICitationReaderProbe* reader=[AICitationReaderProbe new];[reader seedPaths:@[first,linked]];
    NSString* raw=[NSString stringWithFormat:@"spdf-ai://document?path=%@&page=2",SPDFAIDocumentIdentifier(linked)];
    NSURL* URL=[NSURL URLWithString:raw];
    Check(!SPDFMacAIResolveCitation(@{@"messages":@[]},SPDFMacAICitationArguments(URL)),
        "fixture link carries no retrieved evidence, as in the reported answer");
    Check([reader aiOpenDocumentLink:SPDFMacAIDocumentLinkArguments(URL)],"unverified document link opens");
    Check([[reader aiReaderControls][@"path"] isEqual:linked] && [[reader valueForKey:@"pageIndex"] integerValue]==1,
        "the linked document's tab is selected at the linked page");
    Check([reader.selectedTab.searchText length]==0,"an unverified link never highlights a passage");
    AICitationReaderProbe* named=[AICitationReaderProbe new];[named seedPaths:@[first,linked]];
    NSURL* byName=SPDFMacAIDocumentNameLink(@"Night_Comparison_Full_Resolution.pdf");
    Check([named aiOpenDocumentLink:SPDFMacAIDocumentLinkArguments(byName)] &&
        [[named aiReaderControls][@"path"] isEqual:linked],"a document linked by its file name opens");
    Check([named aiOpenTabPathForDocumentLink:SPDFMacAIDocumentLinkArguments(byName)]!=nil &&
        ![named aiOpenTabPathForDocumentLink:@{@"name":@"elsewhere.pdf"}],
        "only documents that are open count as open tabs");
}
