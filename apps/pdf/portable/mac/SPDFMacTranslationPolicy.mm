#import "SPDFMacTranslationPolicy.h"

static bool spdf_translation_idle(spdf_translation_context context) {
    return !context.translationRunning && !context.translationInstallRunning;
}

bool spdf_translation_selection_enabled(spdf_translation_context context) {
    if (!context.hasSelection) return false;
    if (!context.markdownActive && !context.pdfDocumentOpen) return false;
    return spdf_translation_idle(context);
}

bool spdf_translation_whole_document_available(spdf_translation_context context) {
    // Markdown too: it has no page geometry of its own, but the app can render
    // it to a PDF (the same rendition Save as PDF writes) and translate that.
    return context.pdfDocumentOpen || context.markdownActive;
}

bool spdf_translation_command_enabled(spdf_translation_context context) {
    if (spdf_translation_selection_enabled(context)) return true;
    return spdf_translation_whole_document_available(context) && spdf_translation_idle(context);
}
