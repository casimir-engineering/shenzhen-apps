#import <Cocoa/Cocoa.h>

#import "SPDFMacDelegatePrivate.h"

// Getting the OCR toolchain onto the machine: the Homebrew/traineddata
// installer the OCR panel runs, and the Noto fonts ocrmypdf needs to DRAW the
// text it recognised.
//
// The fonts are a separate step because they are needed by a machine that is
// already fully installed: ocrmypdf renders the recognised text into the
// output PDF, and without a font carrying those glyphs it logs
//   "No font found with glyphs for 'chi_sim' text. Install NotoSansCJK-Regular
//    for better rendering."
// and falls back, so a Chinese datasheet comes out with a degraded text layer.
// Nobody who installed OCR before this existed would ever re-enter the
// installer, so the fonts are fetched at OCR time instead (see
// -ensureOCRFontsForLanguage:).

// The tesseract language codes that need the CJK font, and the font files a
// given `+`-joined language string requires. Pure, so the mapping is testable.
FOUNDATION_EXPORT BOOL spdf_mac_ocr_language_needs_cjk_font(NSString* language);
FOUNDATION_EXPORT NSArray<NSString*>* spdf_mac_ocr_font_files_for_language(NSString* language);

// Where ocrmypdf looks on macOS (SystemFontProvider): /Library/Fonts,
// /System/Library/Fonts and ~/Library/Fonts. We install into the last one --
// no administrator rights, no sudo prompt, exactly like the traineddata that
// goes to Application Support.
FOUNDATION_EXPORT NSArray<NSString*>* spdf_mac_ocr_font_search_directories(void);
FOUNDATION_EXPORT BOOL spdf_mac_ocr_font_is_installed(NSString* fileName);

// A shell script that downloads the missing fonts and NOTHING else. It never
// fails the caller: every fetch is guarded, a font that is already present is
// skipped, and the script exits 0 whatever happened, so it can never take an
// OCR run or an install down with it. Downloads land on `<name>.part` and are
// moved into place, so a half-written file is never visible to ocrmypdf.
FOUNDATION_EXPORT NSString* spdf_mac_ocr_font_script(NSString* language);

// The toolchain installer the OCR install panel runs: Homebrew for ocrmypdf and
// tesseract, tesseract-lang for non-English, per-language traineddata into
// Application Support, the font step above, and the app's own Python
// environment (SPDFMacToolEnvironment.h).
//
// That last step is here because the install panel is the ONLY thing a machine
// without OCR ever reaches: the background adoption runs off a resolved tool
// path, and there is none to resolve until something is installed. Leaving it
// out meant a fresh install ended on Homebrew's copy and never moved.
FOUNDATION_EXPORT NSString* spdf_mac_ocr_install_script(NSString* language);

@interface ShenzhenMacDelegate (SPDFMacOCRInstall)
- (NSString*)ocrInstallScriptForLanguage:(NSString*)language;
// Fetches any missing Noto font for `language` in the BACKGROUND and returns
// immediately: OCR must never wait on a 16 MB download. At most one fetch runs
// per session, and once the files are on disk the check is a stat and nothing
// starts. The fonts land in time for the next run, not the current one.
- (void)ensureOCRFontsForLanguage:(NSString*)language;
@end
