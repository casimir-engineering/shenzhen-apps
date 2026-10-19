#import "SPDFMacAIChatMarkdown.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacChatMarkdown.h"

BOOL SPDFMacAIChatLinkAllowed(NSURL* URL) {
    return SPDFMacChatMarkdownLinkAllowed(URL, SPDFMacChatMarkdownLinksAssistant);
}

// "example.com" or "www.example.org/page" written without https://: a web link.
static NSURL* BareHostLink(NSString* destination) {
    NSString* host=[destination componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/?#"]].firstObject.lowercaseString;
    NSArray<NSString*>* labels=[host componentsSeparatedByString:@"."];
    if (labels.count<2 || host.length>253) return nil;
    NSCharacterSet* allowed=[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyz0123456789-"];
    for (NSString* label in labels)
        if (!label.length || [label stringByTrimmingCharactersInSet:allowed].length) return nil;
    NSString* top=labels.lastObject;
    if (top.length<2 || [top stringByTrimmingCharactersInSet:NSCharacterSet.lowercaseLetterCharacterSet].length)
        return nil;
    return [NSURL URLWithString:[@"https://" stringByAppendingString:destination]];
}

SPDFMacChatMarkdownOptions* SPDFMacAIChatMarkdownOptions(void) {
    SPDFMacChatMarkdownOptions* options = [SPDFMacChatMarkdownOptions new];
    options.links = SPDFMacChatMarkdownLinksAssistant;
    // Answers often link a document by its file name or folder, "[Report](docs/Report.pdf)": make it a document
    // link. A site written without https:// opens as a web page unless a document of that name is known.
    options.bareLink = ^NSURL*(NSString* destination) {
        return SPDFMacAIDocumentNameLink(destination) ?:
            SPDFMacAIDocumentOrSiteLink(destination, BareHostLink(destination));
    };
    return options;
}

NSAttributedString* SPDFMacAIChatMarkdown(NSString* text, CGFloat width, BOOL dark) {
    SPDFMacChatMarkdownOptions* options = SPDFMacAIChatMarkdownOptions();
    options.width = width;
    options.dark = dark;
    options.keepsWideBlocks = NO;
    return SPDFMacChatMarkdownRender(text ?: @"", options);
}
