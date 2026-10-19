#import "SPDFMacTranslationEnablement.h"

#import "SPDFMacMarkdownDelegatePrivate.h"

// Defined in ShenzhenPDFMac.mm.
@interface ShenzhenMacDelegate (SPDFMacTranslationEnablementPrivate)
- (NSString*)trimmedSelectedTextForCommand;
@end

@implementation ShenzhenMacDelegate (SPDFMacTranslationEnablement)

// One description of the tab for every Translate entry point (toolbar button,
// File menu, overflow menu, context menu). See SPDFMacTranslationPolicy.h for
// what each entry point does with it — in short, selection translation works
// anywhere there is a selection (Markdown included), whole-document
// translation stays on the PDF render path.
- (spdf_translation_context)translationContext {
    spdf_translation_context context = {};
    context.markdownActive = [self isMarkdownActive];
    context.pdfDocumentOpen = _doc != NULL;
    context.hasSelection = [self trimmedSelectedTextForCommand].length > 0;
    context.translationRunning = _translationRunning;
    context.translationInstallRunning = _translationInstallRunning;
    return context;
}

- (void)updateTranslateCommandEnablement {
    _translateButton.enabled = spdf_translation_command_enabled([self translationContext]);
}

- (BOOL)beginTranslateCommandForSender:(id)sender {
    spdf_translation_context context = [self translationContext];
    if (spdf_translation_selection_enabled(context)) {
        [self showSelectionTranslationPanel:sender];
        return NO;
    }
    // Both busy checks live here rather than in the command, so every entry
    // point is gated the same way.
    if (_translationInstallRunning) {
        [_translationInstallPanel makeKeyAndOrderFront:nil];
        _statusLabel.stringValue = @"Translation installer is already running.";
        return NO;
    }
    if (_translationRunning) {
        _statusLabel.stringValue = @"Translation is already running.";
        return NO;
    }
    // A Markdown tab reaches this too: it is rendered to a PDF first, and that
    // is what gets translated (SPDFMacMarkdownTranslate.h).
    if (spdf_translation_whole_document_available(context) && _path.length) return YES;
    NSBeep();
    return NO;
}

@end
