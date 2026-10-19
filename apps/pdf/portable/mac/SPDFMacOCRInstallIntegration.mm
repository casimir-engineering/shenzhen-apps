#import "SPDFMacOCRInstall.h"

#import "SPDFMacToolEnvironment.h"

// The app-facing half of SPDFMacOCRInstall.h: the OCR panel's installer
// script and the background font fetch. Split from the pure script builders
// so those can be linked, and tested, without the whole app delegate.
@implementation ShenzhenMacDelegate (SPDFMacOCRInstall)

- (NSString*)ocrInstallScriptForLanguage:(NSString*)language {
    return spdf_mac_ocr_install_script(language);
}

- (void)ensureOCRFontsForLanguage:(NSString*)language {
    // Once per session: a second OCR run while the first fetch is still going
    // must not start it again, and the stat below is what stops it ever after.
    static BOOL fetchStarted = NO;
    if (fetchStarted) return;
    BOOL missing = NO;
    for (NSString* file in spdf_mac_ocr_font_files_for_language(language))
        if (!spdf_mac_ocr_font_is_installed(file)) missing = YES;
    if (!missing) return;
    fetchStarted = YES;
    // Detached and unwaited: the OCR run this was called from starts in the
    // same breath and must not wait on a download. The fonts are for the text
    // ocrmypdf DRAWS, so the run in flight may still fall back; the next one
    // has them.
    NSTask* task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    task.arguments = @[ @"-c", spdf_mac_ocr_font_script(language) ];
    task.environment = spdf_mac_tool_environment(NSProcessInfo.processInfo.environment, @[], nil);
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    [task launchAndReturnError:nil];
}

@end
