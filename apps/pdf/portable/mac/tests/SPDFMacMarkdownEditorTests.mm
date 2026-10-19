#import <AppKit/AppKit.h>

#import "SPDFMacMarkdownEditor.h"

static int failures;

#define CHECK(condition, message)                   \
    do {                                            \
        if (!(condition)) {                         \
            fprintf(stderr, "FAIL: %s\n", message); \
            failures++;                             \
        }                                           \
    } while (0)

static NSString* make_source(void) {
    NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    NSString* path = [directory stringByAppendingPathComponent:@"notes.md"];
    [@"# Notes\n" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return path;
}

static void test_stored_editor_launches_directly(NSString* source) {
    NSURL* applicationURL = [NSURL fileURLWithPath:@"/tmp/Test Editor.app" isDirectory:YES];
    __block NSInteger lookupCount = 0;
    __block NSInteger pickerCount = 0;
    __block NSInteger launchCount = 0;
    __block NSInteger writeCount = 0;
    BOOL accepted = SPDFMacOpenMarkdownSourceWithHandlers(
        source, @"test.editor",
        ^NSURL*(NSString* bundleIdentifier) {
          lookupCount++;
          CHECK([bundleIdentifier isEqualToString:@"test.editor"], "lookup received the wrong bundle ID");
          return applicationURL;
        },
        ^(SPDFMacEditorPickerCompletion completion) {
          (void)completion;
          pickerCount++;
        },
        ^(NSURL* app, NSURL* document, void (^completion)(NSError*)) {
          launchCount++;
          CHECK([app isEqual:applicationURL], "stored editor launch received the wrong app");
          CHECK([document.path isEqualToString:source], "stored editor launch received the wrong source");
          completion(nil);
        },
        ^(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          writeCount++;
        });
    CHECK(accepted, "valid Markdown source was rejected");
    CHECK(lookupCount == 1 && pickerCount == 0, "stored editor unexpectedly opened the picker");
    CHECK(launchCount == 1 && writeCount == 0, "stored editor launch or persistence count was wrong");
}

static void test_first_use_picks_persists_then_launches(NSString* source) {
    NSURL* applicationURL = [NSURL fileURLWithPath:@"/tmp/Chosen Editor.app" isDirectory:YES];
    __block NSInteger lookupCount = 0;
    __block NSInteger pickerCount = 0;
    __block NSInteger launchCount = 0;
    __block NSString* writtenBundleIdentifier;
    BOOL accepted = SPDFMacOpenMarkdownSourceWithHandlers(
        source, nil,
        ^NSURL*(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          lookupCount++;
          return nil;
        },
        ^(SPDFMacEditorPickerCompletion completion) {
          pickerCount++;
          completion(applicationURL, @"chosen.editor");
        },
        ^(NSURL* app, NSURL* document, void (^completion)(NSError*)) {
          launchCount++;
          CHECK([writtenBundleIdentifier isEqualToString:@"chosen.editor"],
                "chosen editor was launched before its preference was persisted");
          CHECK([app isEqual:applicationURL] && [document.path isEqualToString:source],
                "chosen editor launch received the wrong URLs");
          completion(nil);
        },
        ^(NSString* bundleIdentifier) { writtenBundleIdentifier = [bundleIdentifier copy]; });
    CHECK(accepted, "first-use editor request was rejected");
    CHECK(lookupCount == 0, "first use queried Launch Services without a stored preference");
    CHECK(pickerCount == 1 && launchCount == 1, "first use did not pick and launch exactly once");
}

static void test_invalid_source_is_rejected(void) {
    __block NSInteger callCount = 0;
    BOOL accepted = SPDFMacOpenMarkdownSourceWithHandlers(
        @"/definitely/missing.md", nil,
        ^NSURL*(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          callCount++;
          return nil;
        },
        ^(SPDFMacEditorPickerCompletion completion) {
          (void)completion;
          callCount++;
        },
        ^(NSURL* app, NSURL* document, void (^completion)(NSError*)) {
          (void)app, (void)document, (void)completion;
          callCount++;
        },
        ^(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          callCount++;
        });
    CHECK(!accepted && callCount == 0, "missing source reached editor discovery or launch");
}

static void test_persistence_and_settings(void) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* saved = [defaults stringForKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
    SPDFMacSetMarkdownEditorBundleIdentifier(@"test.persisted.editor");
    CHECK([SPDFMacStoredMarkdownEditorBundleIdentifier() isEqualToString:@"test.persisted.editor"],
          "editor bundle ID did not round-trip");
    SPDFMacSetMarkdownEditorBundleIdentifier(nil);
    CHECK(SPDFMacStoredMarkdownEditorBundleIdentifier() == nil, "clearing the editor preference failed");

    NSMenu* settings = [[NSMenu alloc] initWithTitle:@"Settings"];
    SPDFMacInstallMarkdownEditorSettingsMenu(settings);
    CHECK(settings.numberOfItems == 1, "editor settings row was not installed");
    CHECK([settings.itemArray.firstObject.title isEqualToString:@"Choose Text Editor..."],
          "editor settings row title changed");

    if (saved) [defaults setObject:saved forKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
    else [defaults removeObjectForKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
}

static void test_picker_starts_in_applications(void) {
    NSURL* directory = SPDFMacMarkdownEditorPickerDirectoryURL();
    CHECK(directory.isFileURL && directory.hasDirectoryPath,
          "editor picker directory is not a local directory URL");
    CHECK([directory.path isEqualToString:@"/Applications"],
          "first editor picker does not start in Applications");
}

int main(void) {
    @autoreleasepool {
        NSString* source = make_source();
        test_stored_editor_launches_directly(source);
        test_first_use_picks_persists_then_launches(source);
        for (NSString* ext in @[@"txt", @"py", @"html"]) {
            NSString* code = [source.stringByDeletingPathExtension stringByAppendingPathExtension:ext];
            [@"literal source" writeToFile:code atomically:YES encoding:NSUTF8StringEncoding error:nil];
            test_stored_editor_launches_directly(code);
        }
        test_invalid_source_is_rejected();
        test_persistence_and_settings();
        test_picker_starts_in_applications();
        [NSFileManager.defaultManager removeItemAtPath:source.stringByDeletingLastPathComponent error:nil];
    }
    if (failures) return 1;
    puts("SPDF mac Markdown editor tests passed");
    return 0;
}
