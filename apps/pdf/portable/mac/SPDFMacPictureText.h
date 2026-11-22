#pragma once
#import <Foundation/Foundation.h>

// Text found in pictures, on this Mac (core/spdf_picture_text.h lays it over the picture).
//
// A recognition result ("recognized" below) is a property list, the form Collection keeps it in:
//   {engine: "macos" | "open-source", pages: [{page: 1, width, height, lines: [{text, box, words: [{text, box}]}]}]}
// `width` and `height` are the size, in pixels, of the page as it was read (the picture as shown: turned upright, the
// whole page); each `box` is [x, y, width, height] in those pixels from the top left. Only pages with text are listed,
// so a result with no pages means the picture has no text.

NS_ASSUME_NONNULL_BEGIN

// Every still picture the reader opens (and camera RAW photos), but not comic archives, drawings (SVG) or camera sensor
// frames.
BOOL SPDFMacPictureTextCandidatePath(NSString* path);
// Raw camera sensor frames (.raw, .raw10): never kept in Collection.
static inline BOOL SPDFMacSensorFramePath(NSString* path) {
    NSString* extension = path.pathExtension.lowercaseString;
    return [extension isEqualToString:@"raw"] || [extension isEqualToString:@"raw10"];
}

// Who recognises text: "macos" (Apple's text recognition, the default) or "open-source" (Tesseract), kept like
// Translate's choice. `language` is the Tesseract language last chosen ("chi_sim+eng").
FOUNDATION_EXPORT NSString* const SPDFMacOCREngineMacOS;
FOUNDATION_EXPORT NSString* const SPDFMacOCREngineOpenSource;
NSString* SPDFMacOCREngine(void);
void SPDFMacSetOCREngine(NSString* engine);
NSString* SPDFMacOCROpenSourceLanguage(void);
void SPDFMacSetOCROpenSourceLanguage(NSString* language);

// Reads the text of a picture (or of a PDF's pages) at `path`, every page up to `maxPages`; `pages` limits it to those
// page indexes (0-based) when given. Slow: never on the main thread. Open source needs `tesseract` (its path) and
// the environment it runs with; without it macOS reads instead. nil with `error` when the document can't be read.
NSDictionary* _Nullable SPDFMacRecognizeText(NSString* path, NSString* engine, NSString* _Nullable tesseract,
                                             NSDictionary<NSString*, NSString*>* _Nullable environment,
                                             NSIndexSet* _Nullable pages, NSUInteger maxPages,
                                             BOOL (^_Nullable cancelled)(void), NSError** error);
static inline BOOL SPDFMacRecognizedHasText(NSDictionary* _Nullable recognized) {
    return [recognized[@"pages"] isKindOfClass:NSArray.class] && [recognized[@"pages"] count] > 0;
}
// A page's text as lines, for search.
NSString* SPDFMacRecognizedPageText(NSDictionary* page);

// The text laid over the pictures open in this process, by the path the reader opened (an original, or the copy a
// read-only original is shown from). Forgotten when the file changes. nil forgets.
void SPDFMacPictureTextRemember(NSString* path, NSDictionary* _Nullable recognized);
NSDictionary* _Nullable SPDFMacPictureTextKnown(NSString* path);

NS_ASSUME_NONNULL_END
