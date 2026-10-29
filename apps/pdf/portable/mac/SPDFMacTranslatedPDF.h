#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

#include "shenzhen_pdf_core.h"

// `text` on one line: trimmed, each run of white space (no-break spaces too) one space.
NSString* SPDFTextByCollapsingWhitespace(NSString* text);

// Translating a whole PDF on this Mac (Argos): which body lines, chapter titles and comments go to the translator,
// one line each, and the translated copy written from what comes back. _pendingTranslationItems holds one entry per
// line sent, in order.
@interface ShenzhenMacDelegate (SPDFMacTranslatedPDF)
- (NSString*)sourceTextByKeepingTranslatableLines:(NSString*)sourceText
                                     sourceScript:(spdf_translation_script)sourceScript
                                     targetScript:(spdf_translation_script)targetScript;
- (NSString*)sourceTextByAppendingOutlineAndCommentItems:(NSString*)sourceText
                                            sourceScript:(spdf_translation_script)sourceScript
                                            targetScript:(spdf_translation_script)targetScript;
- (BOOL)writeTranslatedPDFWithText:(NSString*)text
                        sourcePath:(NSString*)sourcePath
                        outputPath:(NSString*)outputPath
                             error:(NSError**)errorOut;
@end
