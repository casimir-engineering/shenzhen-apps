#import "SPDFMacImageProperties.h"
#import "SPDFMacMarkdownDelegatePrivate.h"

// The app-level half of "rotate a Markdown document": the two rotate commands
// (menu items, their shortcuts, and the toolbar) reaching the session's paper.
//
// On a PDF, rotating turns the rendered page — the pixels themselves come out
// sideways, which is what a scanned page needs. A Markdown document has no
// rendered page to turn; it is text poured onto A4. So the same command turns
// the PAPER instead: portrait becomes landscape, the document re-flows onto the
// wider, shorter sheet, and every glyph stays upright. Nothing rotates.
//
// The choice lives on the TAB (persisted as "markdownLandscape"), not on the
// app, so two Markdown tabs can sit in different orientations and each comes
// back the way it was left. -loadSelectedMarkdownTab: hands it to the session
// before activation, exactly like the font scale and the reading theme.

@implementation ShenzhenMacDelegate (SPDFMacMarkdownOrientation)

- (BOOL)canRotateActivePage {
    // Markdown first: _path can name a .md while _doc is NULL, and the PDF
    // clause below is the pre-existing test, unchanged.
    if ([self isMarkdownActive]) return self.activeMarkdownSession.state == SPDFMacMarkdownSessionReady;
    return _doc != NULL && ([_path.pathExtension.lowercaseString isEqualToString:@"pdf"] || SPDFPathIsRasterImage(_path));
}

- (BOOL)rotateMarkdownPaperByDegrees:(int)degrees {
    // Both directions land on the same two sheets, because A4 turned either way
    // is the same rectangle; the sign has nowhere to go. (A PDF page has four
    // distinct rotations, which is why THAT path still cares.)
    (void)degrees;
    if (![self canRotateActivePage] || ![self isMarkdownActive]) return NO;
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab) return NO;
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    BOOL landscape = session.pageOrientation != SPDFMarkdownPageOrientationLandscape;
    tab.markdownLandscape = landscape;
    [session applyPageOrientation:landscape ? SPDFMarkdownPageOrientationLandscape
                                            : SPDFMarkdownPageOrientationPortrait];
    // Remembered against the FILE, not just the open tab: a document turned for
    // a wide table or a gantt chart is still that document tomorrow, so reopening
    // it brings back the sheet it was last read on (-seedNewTabFromDocumentMemory:).
    // Merged into the document's entry, which -saveDocumentStateForTab: extends
    // rather than replaces, and written out by the save below.
    NSString* key = [self documentStateKeyForPath:tab.path];
    if (key.length) {
        NSMutableDictionary* state = _documentStates[key];
        if (![state isKindOfClass:NSMutableDictionary.class])
            state = [state mutableCopy] ?: [NSMutableDictionary dictionary];
        state[@"markdownLandscape"] = @(landscape);
        state[@"path"] = tab.path ?: state[@"path"] ?: @"";
        _documentStates[key] = state;
    }
    // The re-flow is asynchronous; the page count and viewport controls catch
    // up from the session's own viewport handler once the new plan installs.
    [self savePersistentState];
    return YES;
}

@end
