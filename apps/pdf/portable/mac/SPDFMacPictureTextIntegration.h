#pragma once
#import "SPDFMacDelegatePrivate.h"

NS_ASSUME_NONNULL_BEGIN

// Text in pictures and scanned PDFs, read on this Mac (SPDFMacPictureText.h, SPDFMacPictureTextStore.h).
@interface ShenzhenMacDelegate (PictureText)
// Collection's half of opening `path`. A picture is read for text in the background first, with the engine chosen for
// OCR (macOS unless open source was chosen), or with what Collection kept the last time; it is kept, by `capture`
// (Collection's ordinary capture, which hands back the document it kept), only when it has text, and its text then
// selects and searches in the open picture. A picture without text is remembered as such and never kept. NO when
// `path` isn't a picture.
- (BOOL)pictureTextOpenedPath:(NSString*)path capture:(void (^)(void (^kept)(NSDictionary* _Nullable doc)))capture;
// Once per launch, a while after it: the pictures Collection kept before their text was read are read, one at a time,
// in one window's process; those without text leave it (unless Collection holds their only copy).
- (void)pictureTextScheduleCollectionCheck;
// The OCR button's "macOS" choice. A picture: its text is read and laid over it, and Collection keeps it with that
// text. A PDF: the pages without text get Apple's text as a text layer, written into the file as OCR does. Anything
// else is made into a PDF first, as for open source.
- (void)recognizeShownDocumentTextOnThisMac;
// Delete All Text on a picture: the text found in it goes, and Collection stops keeping it. NO when the shown document
// isn't a picture (the PDF command then runs as before).
- (BOOL)deleteTextFromPicture:(id)sender;
- (BOOL)shownPictureHasText;
@end

NS_ASSUME_NONNULL_END
