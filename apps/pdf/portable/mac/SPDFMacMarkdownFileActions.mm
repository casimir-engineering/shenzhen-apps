#import "SPDFMacMarkdownDelegatePrivate.h"

#import "SPDFMacContextPage.h"
#import "SPDFMacPagePDFCopy.h"
#import <objc/runtime.h>
#import "SPDFMacFileExplorerPreference.h"
#import "SPDFMacMarkdownEditor.h"
#import "SPDFMacMarkdownPrinting.h"
#import "markdown/SPDFMarkdown.h"

@implementation ShenzhenMacDelegate (SPDFMacMarkdownFileActions)

// The active Markdown session can serve single-page copies once its live
// pagination plan and rendered text exist and pageIndex names a planned page.
// Deliberately probes the LIVE plan, not the export one: this runs from
// -validateMenuItem: on every menu pass, and must never build a rendition.
- (BOOL)markdownSessionCanCopyPageAtIndex:(NSInteger)pageIndex {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    return session.paginationPlan != nil && session.renderedDocument.attributedString != nil && pageIndex >= 0 &&
           pageIndex < (NSInteger)session.paginationPlan.pages.count;
}

// Copy Page honors the context-clicked page when the context menu set one,
// falling back to the current page — mirroring the PDF tab's behavior.
- (NSInteger)markdownCopyPageIndexForSender:(id)sender {
    return SPDFMacPageIndexForActionSender(sender, _contextPageIndex, self.activeMarkdownSession.currentPageIndex);
}

- (BOOL)canCopyPageAsPDFAtIndex:(NSInteger)pageIndex {
    if ([self isMarkdownActive]) return [self markdownSessionCanCopyPageAtIndex:pageIndex];
    return _doc != NULL && _path.length > 0 && pageIndex >= 0 && pageIndex < spdf_page_count(_doc);
}

- (BOOL)canCopyCurrentPageAsPDF {
    NSInteger page = [self isMarkdownActive] ? self.activeMarkdownSession.currentPageIndex : _pageIndex;
    return [self canCopyPageAsPDFAtIndex:page];
}

- (BOOL)canCopyCurrentPageImage {
    if ([self isMarkdownActive])
        return [self markdownSessionCanCopyPageAtIndex:self.activeMarkdownSession.currentPageIndex];
    return _doc != NULL && _pageIndex >= 0 && _pageIndex < (NSInteger)_renderedPages.count &&
           _renderedPages[(NSUInteger)_pageIndex].image != nil;
}

- (void)openInExternalReader:(id)sender {
    (void)sender;
    if (!_path.length) {
        NSBeep();
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:_path];
    NSURL* acrobat = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.adobe.Reader"];
    if (!acrobat)
        acrobat = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.adobe.Acrobat.Pro"];
    if (acrobat) {
        NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
        [NSWorkspace.sharedWorkspace openURLs:@[ fileURL ]
                         withApplicationAtURL:acrobat
                                configuration:config
                            completionHandler:nil];
    } else {
        [NSWorkspace.sharedWorkspace openURL:fileURL];
    }
}

- (void)showPathInFolder:(NSString*)path {
    if (!SPDFMacRevealPathUsingPreference(path)) NSBeep();
}

- (void)showInFolder:(id)sender {
    (void)sender;
    if (![self hasActiveDocument] || !_path.length) {
        NSBeep();
        return;
    }
    [self showPathInFolder:_path];
}

- (void)copyCurrentDocumentPath:(id)sender {
    (void)sender;
    if (![self hasActiveDocument] || !_path.length) {
        NSBeep();
        return;
    }
    [self copyPathStringToPasteboard:_path statusMessage:@"Path copied."];
}

- (void)copyCurrentDocumentFile:(id)sender {
    (void)sender;
    if (![self hasActiveDocument] || !_path.length) {
        NSBeep();
        return;
    }
    [self copyTabFileToPasteboardAtIndex:_selectedTabIndex];
}

- (void)openMarkdownInEditor:(id)sender {
    NSString* path = [sender isKindOfClass:NSMenuItem.class] &&
                             [((NSMenuItem*)sender).representedObject isKindOfClass:NSString.class]
                         ? ((NSMenuItem*)sender).representedObject
                         : _path;
    if (!SPDFMacOpenMarkdownSourceInEditor(path, _window)) NSBeep();
}

- (void)copyCurrentPageImage:(id)sender {
    if ([self isMarkdownActive]) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        NSInteger pageIndex = [self markdownCopyPageIndexForSender:sender];
        if (![self markdownSessionCanCopyPageAtIndex:pageIndex] ||
            ![SPDFMacMarkdownPrintAdapter copyPageImageAtIndex:(NSUInteger)pageIndex
                                                paginationPlan:session.exportPaginationPlan
                                              attributedString:session.exportAttributedString
                                                  toPasteboard:NSPasteboard.generalPasteboard]) {
            NSBeep();
            return;
        }
        _statusLabel.stringValue = @"Page image copied.";
        return;
    }
    NSInteger pageIndex = SPDFMacPageIndexForActionSender(sender, _contextPageIndex, _pageIndex);
    if (!_doc || pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count ||
        !_renderedPages[(NSUInteger)pageIndex].image) {
        NSBeep();
        return;
    }
    // Copy the document's OWN colors, like Print and Save as PDF: the cached
    // image may be recolored for the dark reading theme, and a pasted page
    // carrying our dark paper would be wrong wherever it lands. Re-render at
    // the cached page's own zoom and scale when that is the case.
    SPDFRenderedPage* cached = _renderedPages[(NSUInteger)pageIndex];
    NSImage* image = cached.image;
    if (cached.imageDarkTheme) {
        char err[512];
        BOOL darkTheme = _darkReadingTheme;
        _darkReadingTheme = NO;
        SPDFRenderedPage* original = [self renderedPageAtIndex:pageIndex
                                                      document:_doc
                                                          zoom:cached.imageZoom
                                                  displayScale:cached.imageScale
                                                         error:err
                                                   errorLength:sizeof(err)];
        _darkReadingTheme = darkTheme;
        if (!original.image) {
            NSBeep();
            return;
        }
        image = original.image;
    }

    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    [pasteboard writeObjects:@[ image ]];
    _statusLabel.stringValue = @"Page image copied.";
}

- (void)copyCurrentPageAsPDF:(id)sender {
    if ([self isMarkdownActive]) {
        SPDFMacMarkdownSession* session = self.activeMarkdownSession;
        NSInteger pageIndex = [self markdownCopyPageIndexForSender:sender];
        if (![self markdownSessionCanCopyPageAtIndex:pageIndex]) {
            NSBeep();
            return;
        }
        NSString* base = _path.lastPathComponent.stringByDeletingPathExtension;
        NSString* fileName =
            [NSString stringWithFormat:@"%@ - page %ld.pdf", base.length ? base : @"Page", (long)(pageIndex + 1)];
        if (![SPDFMacMarkdownPrintAdapter copyPageAtIndex:(NSUInteger)pageIndex
                                           paginationPlan:session.exportPaginationPlan
                                         attributedString:session.exportAttributedString
                                                 fileName:fileName
                                             toPasteboard:NSPasteboard.generalPasteboard]) {
            NSBeep();
            return;
        }
        _statusLabel.stringValue = @"Page copied.";
        return;
    }
    NSInteger pageIndex = SPDFMacPageIndexForActionSender(sender, _contextPageIndex, _pageIndex);
    if (!_doc || !_path.length || pageIndex < 0 || pageIndex >= spdf_page_count(_doc)) {
        NSBeep();
        return;
    }
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    if ([_path.pathExtension.lowercaseString isEqualToString:@"pdf"]) {
        NSError* error = nil;
        SPDFMacPagePDFCopy* copy = SPDFCreatePagePDFCopy(_doc, pageIndex, _path, &error);
        if (!copy) { [self showError:@"Could not copy page" detail:error.localizedDescription]; return; }
        if (!SPDFWritePagePDFCopy(copy, pasteboard)) { NSBeep(); return; }
        _statusLabel.stringValue = @"Page copied.";
        return;
    }
    // Image/EPUB/etc exports must not block interaction or borrow the live
    // document across threads. Capture the context page now, then own a new
    // MuPDF document on the worker. Original colours/alpha remain intact.
    NSString* path = [_path copy];
    NSString* source = [_workingPath.length ? _workingPath : _path copy];
    NSInteger clipboardChange = pasteboard.changeCount;
    static char generationKey;
    NSUInteger generation = [objc_getAssociatedObject(self, &generationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, &generationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ShenzhenMacDelegate* weakSelf = self;
    _statusLabel.stringValue = @"Copying page as PDF…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            char message[1024] = {};
            spdf_document* document = spdf_open(source.fileSystemRepresentation, message, sizeof(message));
            NSError* error = nil;
            SPDFMacPagePDFCopy* copy = document ? SPDFCreatePagePDFCopy(document, pageIndex, path, &error) : nil;
            if (document) spdf_close(document);
            NSString* failure = error.localizedDescription ?: @(message);
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* owner = weakSelf;
                if (!owner || [objc_getAssociatedObject(owner, &generationKey) unsignedIntegerValue] != generation ||
                    pasteboard.changeCount != clipboardChange) {
                    if (copy) [NSFileManager.defaultManager removeItemAtURL:copy.fileURL.URLByDeletingLastPathComponent error:nil];
                    return;
                }
                if (!copy) { [owner showError:@"Could not copy page" detail:failure]; return; }
                if (!SPDFWritePagePDFCopy(copy, pasteboard)) { NSBeep(); return; }
                owner->_statusLabel.stringValue = @"Page copied.";
            });
        }
    });
}

@end
