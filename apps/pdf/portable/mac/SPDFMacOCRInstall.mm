#import "SPDFMacOCRInstall.h"

#import "SPDFMacSupport.h"
#import "SPDFMacToolEnvironment.h"

// Verified against ocrmypdf 17.4.2's SystemFontProvider: it matches these exact
// file names in these exact directories, so the names below are a contract with
// it and not a preference.
static NSString* const kSPDFNotoSansFile = @"NotoSans-Regular.ttf";
static NSString* const kSPDFNotoSansCJKFile = @"NotoSansCJKsc-Regular.otf";
static NSString* const kSPDFNotoSansURL =
    @"https://github.com/notofonts/notofonts.github.io/raw/main/fonts/NotoSans/hinted/ttf/NotoSans-Regular.ttf";
static NSString* const kSPDFNotoSansCJKURL =
    @"https://github.com/notofonts/noto-cjk/raw/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf";

BOOL spdf_mac_ocr_language_needs_cjk_font(NSString* language) {
    // Any CJK script needs the CJK face; the vertical variants are the same
    // scripts, and tesseract spells a multi-language request "chi_sim+eng".
    for (NSString* component in spdf_ocr_language_components(language ?: @"")) {
        NSString* code = component.lowercaseString;
        if ([code hasPrefix:@"chi_"] || [code hasPrefix:@"jpn"] || [code hasPrefix:@"kor"]) return YES;
    }
    return NO;
}

NSArray<NSString*>* spdf_mac_ocr_font_files_for_language(NSString* language) {
    // NotoSans covers the Latin the recognised text falls back to even for a
    // CJK document (part numbers, units), so it is always wanted; it is also
    // small enough (~0.6 MB against ~16 MB) that fetching it is never the cost.
    NSMutableArray<NSString*>* files = [@[ kSPDFNotoSansFile ] mutableCopy];
    if (spdf_mac_ocr_language_needs_cjk_font(language)) [files addObject:kSPDFNotoSansCJKFile];
    return files;
}

NSArray<NSString*>* spdf_mac_ocr_font_search_directories(void) {
    return @[
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Fonts"], @"/Library/Fonts",
        @"/System/Library/Fonts"
    ];
}

BOOL spdf_mac_ocr_font_is_installed(NSString* fileName) {
    if (!fileName.length) return YES;
    for (NSString* directory in spdf_mac_ocr_font_search_directories()) {
        NSString* path = [directory stringByAppendingPathComponent:fileName];
        NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        // A zero-byte file is a failed download, not an installed font.
        if (attributes && [attributes fileSize] > 0) return YES;
    }
    return NO;
}

NSString* spdf_mac_ocr_font_script(NSString* language) {
    NSMutableString* script = [NSMutableString string];
    // No `exit`: this text is also spliced into the installer script, where an
    // exit would skip the checks that follow it. Every fetch is guarded, so
    // `set -e` in that script can never be tripped by a font that would not
    // download, and the whole step ends in `true`.
    [script appendString:@"FONT_DIR=\"$HOME/Library/Fonts\"\n"
                          "mkdir -p \"$FONT_DIR\" || true\n"
                          "spdf_fetch_font() {\n"
                          "  name=\"$1\"; url=\"$2\"\n"
                          "  for dir in \"$FONT_DIR\" /Library/Fonts /System/Library/Fonts; do\n"
                          "    if [ -s \"$dir/$name\" ]; then echo \"Font $name is installed.\"; return 0; fi\n"
                          "  done\n"
                          "  echo \"Downloading font $name for OCR text rendering...\"\n"
                          "  if command -v curl >/dev/null 2>&1; then "
                          "curl -LfsS --max-time 600 \"$url\" -o \"$FONT_DIR/$name.part\"; "
                          "elif command -v wget >/dev/null 2>&1; then "
                          "wget -q -O \"$FONT_DIR/$name.part\" \"$url\"; "
                          "else echo 'curl or wget is required to download OCR fonts.'; return 1; fi\n"
                          "  if [ -s \"$FONT_DIR/$name.part\" ]; then mv -f \"$FONT_DIR/$name.part\" "
                          "\"$FONT_DIR/$name\"; else rm -f \"$FONT_DIR/$name.part\"; return 1; fi\n"
                          "}\n"];
    for (NSString* file in spdf_mac_ocr_font_files_for_language(language)) {
        NSString* url = [file isEqualToString:kSPDFNotoSansCJKFile] ? kSPDFNotoSansCJKURL : kSPDFNotoSansURL;
        [script appendFormat:@"spdf_fetch_font \"%@\" \"%@\" || echo \"Skipped %@; OCR still runs without it.\"\n",
                             file, url, file];
    }
    [script appendString:@"true\n"];
    return script;
}

NSString* spdf_mac_ocr_install_script(NSString* language) {
    NSString* languageList = [spdf_ocr_language_components(language) componentsJoinedByString:@" "];
    return [NSString
        stringWithFormat:@"set -e\n"
                          "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"\n"
                          "export NONINTERACTIVE=1\n"
                          "OCR_LANGS=\"%@\"\n"
                          "BREW=\"\"\n"
                          "if command -v brew >/dev/null 2>&1; then BREW=$(command -v brew); "
                          "elif [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; "
                          "elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew; fi\n"
                          "if ! command -v tesseract >/dev/null 2>&1 || ! command -v gs >/dev/null 2>&1; "
                          "then "
                          "if [ -z \"$BREW\" ]; then echo 'Homebrew not found. Installing Homebrew...'; "
                          "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/"
                          "install.sh)\"; "
                          "if [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; "
                          "elif [ -x /usr/local/bin/brew ]; then BREW=/usr/local/bin/brew; "
                          "else echo 'Homebrew installation did not produce a brew executable.'; exit 1; fi; fi; "
                          "echo \"Using $BREW\"; \"$BREW\" install tesseract ghostscript; "
                          "else echo 'Tesseract and Ghostscript are already installed.'; fi\n"
                          "if [ -n \"$BREW\" ] && printf '%%s\\n' \"$OCR_LANGS\" | grep -qv '^eng$'; then "
                          "echo 'Installing Tesseract language data...'; \"$BREW\" install tesseract-lang || true; "
                          "fi\n"
                          "TESS_PARENT=\"$HOME/Library/Application Support/ShenzhenPDF/tesseract\"\n"
                          "mkdir -p \"$TESS_PARENT/tessdata\"\n"
                          "download_lang() {\n"
                          "  lang=\"$1\"\n"
                          "  url=\"https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/$lang."
                          "traineddata\"\n"
                          "  dest=\"$TESS_PARENT/tessdata/$lang.traineddata\"\n"
                          "  echo \"Downloading $lang traineddata...\"\n"
                          "  if command -v curl >/dev/null 2>&1; then curl -LfsS \"$url\" -o \"$dest\"; "
                          "elif command -v wget >/dev/null 2>&1; then wget -q \"$url\" -O \"$dest\"; "
                          "else echo 'curl or wget is required to download OCR language data.'; return 1; fi\n"
                          "}\n"
                          "for lang in $OCR_LANGS; do\n"
                          "  if command -v tesseract >/dev/null 2>&1 && tesseract --list-langs 2>/dev/null | "
                          "grep -qx \"$lang\"; then echo \"Tesseract language $lang is installed.\"; "
                          "elif [ -f \"$TESS_PARENT/tessdata/$lang.traineddata\" ]; then "
                          "echo \"Bundled Shenzhen PDF language $lang is installed.\"; "
                          "else download_lang \"$lang\"; fi\n"
                          "done\n"
                          "%@"
                          "%@"
                          // ocrmypdf is ONLY ever installed into the app's own environment, so that
                          // is what the install has to produce. Under `set -e` this fails the install
                          // loudly, with the environment step's own reason already in the log.
                          "test -x \"%@/ocrmypdf\"\n"
                          "command -v tesseract >/dev/null 2>&1\n",
                         languageList, spdf_mac_ocr_font_script(language),
                         spdf_mac_tool_environment_install_step(@[ @"ocrmypdf" ]),
                         spdf_mac_tool_venv_bin_path()];
}
