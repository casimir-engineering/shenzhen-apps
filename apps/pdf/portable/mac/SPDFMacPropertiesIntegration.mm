#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacPropertiesPanel.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "markdown/SPDFMarkdownDocument.h"
#import "markdown/SPDFMarkdownLanguage.h"

@implementation ShenzhenMacDelegate (Properties)
- (void)showProperties:(id)sender {
    (void)sender;
    NSString* path = [self selectedTab].path ?: _path;
    if (!path.length) return;
    NSMutableDictionary* textInfo = nil;
    NSInteger page = _pageIndex, headings = _outline.count;
    if (SPDFIsRenderedTextDocumentPath(path)) {
        textInfo = [NSMutableDictionary dictionary];
        NSString* languageID = SPDFSourceLanguageForPath(path);
        NSString* language = [SPDFMarkdownLanguageCatalog.sharedCatalog languageForFenceIdentifier:languageID].displayName;
        textInfo[@"format"] = languageID ? @"Text / source document" : @"Markdown";
        if (language.length) textInfo[@"language"] = language;
        SPDFMacMarkdownSession* session = [self isMarkdownActive] ? self.activeMarkdownSession : nil;
        if (session.renderedDocument) textInfo[@"text"] = session.renderedDocument.attributedString.string;
        if (session.paginationPlan) {
            textInfo[@"pageCount"] = @(session.paginationPlan.pages.count);
            textInfo[@"pageSize"] = [NSValue valueWithSize:session.paginationPlan.configuration.paperSize];
        }
        page = session.currentPageIndex; headings = session.sidebarModel.chapterItems.count;
    }
    // Cached metadata only: opening Properties never starts a provider request.
    NSDictionary* analysis=[self aiAnalysisForPath:path];
    if(analysis[@"summary"]) { if(!textInfo)textInfo=[NSMutableDictionary dictionary]; textInfo[@"aiAnalysis"]=analysis; }
    [SPDFPropertiesPanelController presentForDocument:_doc sourcePath:path
        workingPath:_workingPath.length ? _workingPath : path pageIndex:page outlineCount:headings
        annotationCount:_comments.count textInfo:textInfo parentWindow:_window];
}
@end
