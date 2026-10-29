#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacTranslationChoice)
// Translate (toolbar, File menu, overflow menu): asks only for the language (SPDFMacTranslateLanguagePopover.h), then
// asks the assistant to translate the shown document into it. The assistant makes "<name> (<Language>)" in the same
// format, in Downloads and Collection, and opens it next to the original; its progress shows in the chat.
- (void)translateDocument:(id)sender;
// The request the assistant gets: "Translate “Datasheet” to French."
- (BOOL)translateShownDocumentInto:(NSString*)language;
@end
