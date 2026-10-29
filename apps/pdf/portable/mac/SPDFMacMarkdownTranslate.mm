#import "SPDFMacTranslationChoice.h"
#import "SPDFMacMarkdownTranslate.h"

#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownPrinting.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacTranslateChapters.h"

// Defined in ShenzhenPDFMac.mm.
@interface ShenzhenMacDelegate (SPDFMacMarkdownTranslatePrivate)
- (NSString*)trimmedSelectedTextForCommand;
- (void)translateDocument:(id)sender;
@end

@implementation ShenzhenMacDelegate (SPDFMacMarkdownTranslate)

// <name>.pdf beside the document, stepping to <name>-1.pdf and so on rather
// than overwriting a PDF that is already there. The rendition is a real file on
// purpose: the translated copy is derived from it, and a reader who wonders
// what was translated can open it.
- (NSString*)availableRenditionPathForMarkdownPath:(NSString*)path {
    NSString* base = path.stringByDeletingPathExtension;
    NSString* candidate = [base stringByAppendingPathExtension:@"pdf"];
    for (NSUInteger suffix = 1; [NSFileManager.defaultManager fileExistsAtPath:candidate] && suffix < 100; ++suffix)
        candidate = [[NSString stringWithFormat:@"%@-%lu", base, (unsigned long)suffix]
            stringByAppendingPathExtension:@"pdf"];
    return [NSFileManager.defaultManager fileExistsAtPath:candidate] ? nil : candidate;
}

- (BOOL)beginWholeDocumentTranslationForMarkdown {
    if (![self isMarkdownActive]) return NO;
    // A selection translates on its own, unless the picker asked for the whole document.
    if ([self trimmedSelectedTextForCommand].length > 0 && ![self localTranslationRequest]) return NO;

    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    SPDFMarkdownPaginationPlan* plan = session.exportPaginationPlan;
    NSAttributedString* text = session.exportAttributedString;
    NSString* source = self->_path;
    if (!plan || !text || !source.length) return NO;

    NSString* rendition = [self availableRenditionPathForMarkdownPath:source];
    NSError* error = nil;
    if (!rendition ||
        ![SPDFMacMarkdownPrintAdapter writePaginationPlan:plan
                                         attributedString:text
                                                    toURL:[NSURL fileURLWithPath:rendition]
                                                    error:&error]) {
        [self showError:@"Could not translate this text document"
                 detail:error.localizedDescription
                            ?: @"Shenzhen PDF could not render it to a PDF to translate."];
        return YES;  // handled: the caller must not fall through to the PDF path
    }

    // Its headings become its chapters, on the pages they print on, so the translation keeps them (translated).
    NSMutableArray* chapters = [NSMutableArray array];
    SPDFMacMarkdownSidebarModel* printed = session.renderedDocument
        ? [[SPDFMacMarkdownSidebarModel alloc] initWithRenderedDocument:session.renderedDocument paginationPlan:plan] : nil;
    for (NSDictionary* item in printed.chapterItems)
        if ([item[@"page"] integerValue] >= 0)
            [chapters addObject:@{@"title" : item[@"title"] ?: @"", @"page" : item[@"page"], @"level" : item[@"level"] ?: @0}];
    SPDFMacTranslateWriteChapters(rendition, chapters, nil, nil);
    [self noteLocalTranslationMakesPDF];

    // Opening it makes it the active tab, so the whole-document pipeline runs
    // against real page geometry with nothing about it made Markdown-aware.
    [self openPath:rendition];
    if ([self isMarkdownActive]) return YES;  // the open did not take; do not recurse
    [self translateDocumentLocally:nil];
    return YES;
}

@end
