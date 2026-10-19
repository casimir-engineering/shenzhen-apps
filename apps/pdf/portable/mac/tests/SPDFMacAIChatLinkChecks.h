// Links in the assistant's answers: only safe targets stay clickable, and answers that name documents by file name
// (or sites without https://) get links that open them.
#import "../SPDFMacAICitations.h"
static void RunChatLinkChecks(void) {
    NSAttributedString* safe=SPDFMacAIChatMarkdown(@"**Evidence** [page](spdf-ai://document?path=test&page=2) "
        "[site](https://example.com) [unsafe](file:///tmp/private) ![hidden](file:///tmp/private.png) "
        "![remote](https://example.com/tracker.png)",500,YES);
    __block NSUInteger links=0,attachments=0,pictures=0;
    [safe enumerateAttributesInRange:NSMakeRange(0,safe.length) options:0
        usingBlock:^(NSDictionary* a,NSRange r,BOOL* stop){
        (void)r;(void)stop;
        if(a[NSLinkAttributeName]) {
            links++; Check(SPDFMacAIChatLinkAllowed(a[NSLinkAttributeName]),@"rendered link is allowed");
        }
        if(a[NSAttachmentAttributeName]) { attachments++; if([a[NSAttachmentAttributeName] image]) pictures++; }
    }];
    // The remote image is a Load image placeholder (SPDFMacChatMarkdown.h); the file image is only its alt text.
    Check(links==2,@"rich Markdown retains document and HTTPS links");
    Check(attachments==1 && !pictures && [safe.string containsString:@"[Image: hidden]"],
        @"model images cannot resolve any resource by themselves");
    Check(!SPDFMacAIChatLinkAllowed([NSURL URLWithString:@"https://user:secret@example.com"]),
        @"credential URL is not clickable");
    // Answers name documents by file name too; those links must be clickable and open the document.
    NSAttributedString* named=SPDFMacAIChatMarkdown(@"See [the comparison]"
        "(Night_Comparison_Full_Resolution.pdf), "
        "[spaced](My%20Report.pdf), [folder](../secret/notes.pdf), [docs](http://example.com/a), "
        "[site](example.com), [www](www.example.org/about) and [nested](docs/Report.pdf).",500,NO);
    __block NSMutableArray* targets=[NSMutableArray array];
    [named enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0,named.length) options:0
        usingBlock:^(id value,NSRange r,BOOL* stop){ (void)r;(void)stop; if(value) [targets addObject:value]; }];
    NSDictionary* first=targets.count ? SPDFMacAIDocumentLinkArguments(targets[0]) : nil;
    Check(targets.count==6 && [first[@"name"] isEqual:@"Night_Comparison_Full_Resolution.pdf"],
        @"a file-name link becomes a clickable document link");
    Check(targets.count==6 && [SPDFMacAIDocumentLinkArguments(targets[1])[@"name"] isEqual:@"My Report.pdf"],
        @"an encoded file name opens the named document");
    Check(targets.count==6 && [[targets[2] absoluteString] isEqual:@"http://example.com/a"],
        @"a plain web link stays clickable; a parent-folder path does not become a document link");
    NSDictionary* site=targets.count==6 ? SPDFMacAIDocumentLinkArguments(targets[3]) : nil;
    Check([site[@"name"] isEqual:@"example.com"] &&
        [site[@"site"] isEqual:[NSURL URLWithString:@"https://example.com"]] &&
        [[targets[4] absoluteString] isEqual:@"https://www.example.org/about"],
        @"a site written without https:// opens as a web page unless a document has that name");
    NSAttributedString* code=SPDFMacAIChatMarkdown(@"Run [name.sh](name.sh), [main.py](main.py), [lib.rs](lib.rs), "
        "[script.pl](script.pl) and [archive.zip](archive.zip).",500,NO);
    __block NSUInteger codeDocuments=0,codeLinks=0;
    [code enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0,code.length) options:0
        usingBlock:^(id value,NSRange r,BOOL* stop){ (void)r;(void)stop; if(!value) return; codeLinks++;
            NSDictionary* link=SPDFMacAIDocumentLinkArguments(value);
            if(link[@"name"] && !link[@"site"]) codeDocuments++; }];
    Check(codeLinks==5 && codeDocuments==5,@"code and archive file names open as documents, never as websites");
    Check(targets.count==6 && [SPDFMacAIDocumentLinkArguments(targets[5])[@"name"] isEqual:@"Report.pdf"],
        @"a relative path to a document is a clickable document link");
    NSAttributedString* office=SPDFMacAIChatMarkdown(@"Open [the budget](budget.numbers) or [the spec](spec.doc).",
        500,NO);
    __block NSMutableArray* officeTargets=[NSMutableArray array];
    [office enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0,office.length) options:0
        usingBlock:^(id value,NSRange r,BOOL* stop){ (void)r;(void)stop; if(value) [officeTargets addObject:value]; }];
    Check(officeTargets.count==2 &&
        [SPDFMacAIDocumentLinkArguments(officeTargets[0])[@"name"] isEqual:@"budget.numbers"] &&
        [SPDFMacAIDocumentLinkArguments(officeTargets[1])[@"name"] isEqual:@"spec.doc"],
        @"a file the reader cannot open stays a document name, never a made-up web address");
    // The chat's own message rows follow the same rules.
    NSWindow* window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,420,400) styleMask:NSWindowStyleMaskTitled
        backing:NSBackingStoreBuffered defer:NO];
    SPDFMacAIChatView* view=[[SPDFMacAIChatView alloc] initWithFrame:window.contentView.bounds];
    window.contentView=view;
    ChatFixture* fixture=[ChatFixture new];
    fixture.chat=@{@"id":@"links",@"messages":@[@{@"role":@"user",@"content":@"Where is it?"},
        @{@"role":@"assistant",@"content":@"In [the report](docs/Report.pdf)."}]};
    [view displaySession:(id)fixture];
    NSTextView* answer=ChatBodies(view).lastObject; __block id target=nil;
    [answer.textStorage enumerateAttribute:NSLinkAttributeName inRange:NSMakeRange(0,answer.textStorage.length)
        options:0 usingBlock:^(id value,NSRange r,BOOL* stop){ (void)r;(void)stop; if(value) target=value; }];
    Check([target isKindOfClass:NSURL.class] && [SPDFMacAIDocumentLinkArguments(target)[@"name"] isEqual:@"Report.pdf"],
        @"a file-name link in an answer shown in the chat opens the document");
    // Links in a table are drawn inside the answer; they open through the chat like its other links.
    NSMutableArray<NSURL*>* opened=[NSMutableArray array];
    view.openLink=^(NSURL* URL){ [opened addObject:URL]; };
    fixture.chat=@{@"id":@"table-links",@"messages":@[@{@"role":@"user",@"content":@"Which files?"},
        @{@"role":@"assistant",@"content":@"| File | Shop |\n|---|---|\n| [the report](docs/Report.pdf) | "
            "[the shop](allegro.pl) |"}]};
    [view displaySession:(id)fixture]; [view layoutSubtreeIfNeeded];
    NSTextView* table=ChatBodies(view).lastObject;
    [table cacheDisplayInRect:table.bounds toBitmapImageRep:[table bitmapImageRepForCachingDisplayInRect:table.bounds]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (id attachment in table.accessibilityChildren)
        for (id control in [attachment accessibilityAttributeValue:NSAccessibilityChildrenAttribute])
            [control accessibilityPerformAction:NSAccessibilityPressAction];
#pragma clang diagnostic pop
    Check(opened.count==2 && [SPDFMacAIDocumentLinkArguments(opened[0])[@"name"] isEqual:@"Report.pdf"] &&
        [SPDFMacAIDocumentLinkArguments(opened[1])[@"web"] isEqual:[NSURL URLWithString:@"https://allegro.pl"]],
        [NSString stringWithFormat:@"links in a table in an answer open like its other links (%lu)",
            (unsigned long)opened.count]);
}
