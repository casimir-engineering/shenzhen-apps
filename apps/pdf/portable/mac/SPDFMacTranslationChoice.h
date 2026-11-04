#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacTranslationChoice)
// Translate (toolbar, File menu, overflow menu): asks for the language and who translates
// (SPDFMacTranslateLanguagePopover.h). The result is "<name> (<Language>)", opened right after the original.
// - On this Mac: Argos translates the whole document offline (translateDocumentLocally:), the language it is in found
//   from its text, or asked when it can't be; the translated PDF is saved beside the original, keeping its chapters.
//   A Markdown or text document is translated as the PDF it prints to.
// - AI: the assistant translates it in a new chat, into the same format, in Downloads and Collection; its progress
//   shows in the chat.
- (void)translateDocument:(id)sender;
// The request the assistant gets: "Translate “Datasheet” to French."
- (BOOL)translateShownDocumentInto:(NSString*)language;
// On this Mac, into `code` (an Argos language, "fr"), named after `language` ("French").
- (void)translateShownDocumentLocallyInto:(NSString*)code language:(NSString*)language;
// The request from the picker that the local translation is working on, or nil when it came from elsewhere:
// {target: "fr", language: "French", name: "Datasheet"}. It lasts through a Markdown or EPUB document's PDF being
// made, and ends with clearLocalTranslationRequest.
- (NSDictionary*)localTranslationRequest;
- (void)clearLocalTranslationRequest;
// The document is being made into a PDF to translate: the translation says it is a PDF.
- (void)noteLocalTranslationMakesPDF;
// The language `text` is in, as an Argos code other than `target`; nil when it can't be told, with `inTarget` YES when
// it seems to be in `target` already.
- (NSString*)localTranslationSourceForText:(NSString*)text target:(NSString*)target alreadyInTarget:(BOOL*)inTarget;
// Asks which language the document is in, to translate it into `target` (named `language`); nil on Cancel.
- (NSString*)askLocalTranslationSourceInto:(NSString*)target language:(NSString*)language;
// The language to translate from for the picker's `request`: found from `text`, or asked when it can't be told. nil when
// there is nothing to do: already in the target language (said so), or Cancel.
- (NSString*)localTranslationSourceForText:(NSString*)text request:(NSDictionary*)request;
// Where the translation of the shown document is saved: beside it, or in Downloads when its folder can't take it
// (read-only, temporary, or Collection's own).
- (NSString*)localTranslationDirectory;
// "<name> (<Language>).pdf" in `directory`, never one that is there already ("<name> (<Language>) 2.pdf").
- (NSString*)localTranslationOutputPathInDirectory:(NSString*)directory request:(NSDictionary*)request;
// Opens the translation in a tab right after `original`'s, in its group.
- (void)openTranslation:(NSString*)path besidePath:(NSString*)original;
@end
