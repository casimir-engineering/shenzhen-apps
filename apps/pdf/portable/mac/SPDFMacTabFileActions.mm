#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacSupport.h"

@interface ShenzhenMacDelegate (SPDFTabFileActionsPrivate)
- (void)showPathInFolder:(NSString*)path;
@end

@implementation ShenzhenMacDelegate (SPDFTabFileActions)
- (void)showTabInFolderAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) {
        NSBeep();
        return;
    }
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    [self showPathInFolder:tab.path];
}

- (void)copyPathStringToPasteboard:(NSString*)path statusMessage:(NSString*)statusMessage {
    if (!path.length) {
        NSBeep();
        return;
    }

    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (![pasteboard setString:path forType:NSPasteboardTypeString]) {
        NSBeep();
        return;
    }
    _statusLabel.stringValue = statusMessage ?: @"Path copied.";
}

- (void)copyTabFileToPasteboardAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) {
        NSBeep();
        return;
    }
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    if (!tab.path.length) {
        NSBeep();
        return;
    }

    NSURL* fileURL = [NSURL fileURLWithPath:tab.path];
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[ fileURL ]]) {
        NSBeep();
        return;
    }
    _statusLabel.stringValue = @"File copied.";
}

- (void)copyTabPathToPasteboardAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) {
        NSBeep();
        return;
    }
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    [self copyPathStringToPasteboard:tab.path statusMessage:@"Path copied."];
}

// Copy the tab's title — the document name without its .pdf extension.
- (void)copyTabTitleToPasteboardAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_tabs.count) {
        NSBeep();
        return;
    }
    SPDFDocumentTab* tab = _tabs[(NSUInteger)index];
    NSString* title = tab.path.length ? spdf_display_name_for_path(tab.path) : tab.title;
    [self copyPathStringToPasteboard:title ?: @"" statusMessage:@"Title copied."];
}

@end
