// The OCR install scripts, and the fonts ocrmypdf needs to DRAW recognised text.
//
// ocrmypdf 17.4.2 warns "No font found with glyphs for 'chi_sim' text. Install
// NotoSansCJK-Regular for better rendering." and falls back, so a Chinese
// datasheet gets a degraded text layer. Its SystemFontProvider matches exact
// file names in exact directories -- verified on this machine: dropping
// NotoSansCJKsc-Regular.otf into ~/Library/Fonts made _find_font_file report it
// -- so the names and directories here are a contract with that provider.
//
// The font step is spliced into the installer script, which runs under `set -e`.
// A step that can exit or fail there would take the whole install down, so this
// suite pins both properties, and runs `sh -n` over the generated scripts so a
// quoting mistake cannot ship.

#import <Cocoa/Cocoa.h>

#import "../SPDFMacOCRInstall.h"

static int gFailures;

static void Expect(BOOL condition, NSString* what) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
    ++gFailures;
}

// Parses without executing: catches an unbalanced quote or `fi` in the script.
static BOOL ShellParses(NSString* script, NSString* label) {
    NSString* path = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"spdf-script-%@.sh", NSUUID.UUID.UUIDString]];
    if (![script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) return NO;
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[ @"-n", path ];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    [task launchAndReturnError:nil];
    [task waitUntilExit];
    BOOL ok = task.terminationStatus == 0;
    if (!ok) fprintf(stderr, "  (%s did not parse; kept at %s)\n", label.UTF8String, path.UTF8String);
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    return ok;
}

int main(void) {
    @autoreleasepool {
        // --- Which languages need the CJK face -------------------------------
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"chi_sim"), @"chi_sim needs the CJK font");
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"chi_sim+eng"),
               @"the default chi_sim+eng needs the CJK font");
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"eng+chi_tra"), @"chi_tra needs it in any position");
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"chi_tra_vert"), @"the vertical variants are the same scripts");
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"jpn"), @"Japanese needs it");
        Expect(spdf_mac_ocr_language_needs_cjk_font(@"kor"), @"Korean needs it");
        Expect(!spdf_mac_ocr_language_needs_cjk_font(@"eng"), @"English does not");
        Expect(!spdf_mac_ocr_language_needs_cjk_font(@"fra+deu"), @"nor do other Latin languages");
        Expect(!spdf_mac_ocr_language_needs_cjk_font(@""), @"an empty language does not");

        // --- Which files that means ------------------------------------------
        NSArray<NSString*>* latin = spdf_mac_ocr_font_files_for_language(@"eng");
        Expect([latin isEqualToArray:@[ @"NotoSans-Regular.ttf" ]], @"English wants the Latin face only");
        NSArray<NSString*>* cjk = spdf_mac_ocr_font_files_for_language(@"chi_sim+eng");
        Expect(cjk.count == 2 && [cjk containsObject:@"NotoSans-Regular.ttf"] &&
                   [cjk containsObject:@"NotoSansCJKsc-Regular.otf"],
               @"a CJK language wants both faces");

        // --- Where ocrmypdf looks --------------------------------------------
        NSArray<NSString*>* dirs = spdf_mac_ocr_font_search_directories();
        Expect(dirs.count == 3, @"three font directories, as SystemFontProvider scans on macOS");
        Expect([dirs.firstObject hasPrefix:NSHomeDirectory()],
               @"the writable one comes first: no administrator rights, no sudo");
        Expect([dirs containsObject:@"/Library/Fonts"] && [dirs containsObject:@"/System/Library/Fonts"],
               @"a font already installed system-wide counts");
        Expect(spdf_mac_ocr_font_is_installed(@""), @"no file name needed means nothing to install");
        Expect(!spdf_mac_ocr_font_is_installed(@"SPDFDefinitelyNotAFont-Regular.otf"), @"a missing font is missing");

        // --- The font script --------------------------------------------------
        NSString* fontScript = spdf_mac_ocr_font_script(@"chi_sim+eng");
        Expect([fontScript containsString:@"NotoSansCJKsc-Regular.otf"],
               @"the CJK file name is the one the provider matches");
        Expect([fontScript containsString:@"$HOME/Library/Fonts"], @"it installs where ocrmypdf looks");
        Expect([fontScript containsString:@".part"] && [fontScript containsString:@"mv -f"],
               @"a download lands on .part and is moved, so a truncated font is never visible");
        Expect([fontScript rangeOfString:@"exit"].location == NSNotFound,
               @"no exit: this text is spliced into a larger script");
        Expect([fontScript hasSuffix:@"true\n"], @"it ends true, so `set -e` cannot trip on a skipped font");
        Expect([fontScript containsString:@"|| echo"],
               @"every fetch is guarded; a font that will not download is skipped");
        Expect(ShellParses(fontScript, @"the font script"), @"the font script parses");
        Expect(![spdf_mac_ocr_font_script(@"eng") containsString:@"NotoSansCJKsc"],
               @"an English-only run does not fetch the 16 MB CJK face");

        // --- The installer it is spliced into ---------------------------------
        NSString* install = spdf_mac_ocr_install_script(@"chi_sim+eng");
        Expect([install containsString:@"NotoSansCJKsc-Regular.otf"], @"a fresh install gets the fonts too");
        // ocrmypdf is a Python program and is NEVER installed globally: Homebrew
        // provides only the two C binaries it shells out to.
        Expect([install containsString:@"install tesseract ghostscript"],
               @"Homebrew provides tesseract and ghostscript, the programs ocrmypdf runs");
        // The ONLY ocrmypdf install is the pip one, into the app's environment.
        Expect([install rangeOfString:@"$BREW\" install ocrmypdf"].location == NSNotFound &&
                   [install rangeOfString:@"brew install ocrmypdf"].location == NSNotFound,
               @"never a global ocrmypdf: that copy is the thing this moves away from");
        Expect([install containsString:@"-m pip install --upgrade ocrmypdf"],
               @"it is installed into the virtualenv instead");
        NSRange fontStep = [install rangeOfString:@"spdf_fetch_font"];
        // The install is judged on the app's own environment, not on PATH.
        NSRange finalCheck = [install rangeOfString:@"test -x" options:NSBackwardsSearch];
        Expect([install containsString:@"/ocrmypdf\"\n"],
               @"the final check is the virtualenv's ocrmypdf");
        Expect(fontStep.location != NSNotFound && finalCheck.location != NSNotFound &&
                   fontStep.location < finalCheck.location,
               @"the fonts are fetched before the checks that decide the install succeeded");
        // A fresh machine reaches this script and nothing else, so the private
        // environment has to be built here or it is never built at all.
        Expect([install containsString:@"-m venv"] && [install containsString:@"pip install --upgrade ocrmypdf"],
               @"installing OCR also builds the app's own Python environment");
        NSRange venvStep = [install rangeOfString:@"-m venv"];
        Expect(venvStep.location != NSNotFound && finalCheck.location != NSNotFound &&
                   venvStep.location < finalCheck.location,
               @"and does it before the checks that decide the install succeeded");
        Expect(ShellParses(install, @"the installer script"), @"the installer script parses");

        if (gFailures == 0) puts("SPDFMacOCRInstallTests passed");
    }
    return gFailures == 0 ? 0 : 1;
}
