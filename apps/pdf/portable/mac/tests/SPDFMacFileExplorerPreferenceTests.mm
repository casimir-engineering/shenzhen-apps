#import <Cocoa/Cocoa.h>

#import "SPDFMacFileExplorerPreference.h"

static int failures;

#define CHECK(condition, message)                   \
    do {                                            \
        if (!(condition)) {                         \
            fprintf(stderr, "FAIL: %s\n", message); \
            failures++;                             \
        }                                           \
    } while (0)

static NSString* make_fixture(BOOL directory) {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:root
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    if (directory) return root;
    NSString* file = [root stringByAppendingPathComponent:@"document.pdf"];
    [@"fixture" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return file;
}

static void remove_fixture(NSString* path) {
    NSString* root = [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:NULL] &&
                             [path.pathExtension.lowercaseString isEqualToString:@"pdf"]
                         ? path.stringByDeletingLastPathComponent
                         : path;
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
}

// Re-validates both rows and asserts the checkmark tracks the RESOLVED
// preference, with the "(Automatic)" hint only while nothing was chosen.
static void check_menu_state(NSMenu* submenu, SPDFMacFileExplorerPreference stored) {
    BOOL available = SPDFMacShenzhenFilesIsAvailable();
    SPDFMacFileExplorerPreference resolved = SPDFMacResolveFileExplorerPreference(stored, available);
    NSMenuItem* finder = [submenu itemAtIndex:0];
    NSMenuItem* shenzhen = [submenu itemAtIndex:1];
    id<NSMenuItemValidation> target = (id<NSMenuItemValidation>)finder.target;
    [target validateMenuItem:finder];
    CHECK([target validateMenuItem:shenzhen] == available, "Shenzhen Files row enablement ignores availability");
    NSMenuItem* active = resolved == SPDFMacFileExplorerShenzhenFiles ? shenzhen : finder;
    NSMenuItem* inactive = active == finder ? shenzhen : finder;
    CHECK(active.state == NSControlStateValueOn, "the resolved file manager is not checked");
    CHECK(inactive.state == NSControlStateValueOff, "a non-resolved file manager is checked");
    BOOL derived = stored == SPDFMacFileExplorerUnset;
    CHECK([active.title hasSuffix:@" (Automatic)"] == derived, "the derived-default hint is wrong");
    CHECK(![inactive.title hasSuffix:@" (Automatic)"], "an inactive row claims to be the automatic default");
}

static void test_identifiers(void) {
    CHECK([SPDFMacFileExplorerPreferenceIdentifier(SPDFMacFileExplorerSystem) isEqualToString:@"system"],
          "system identifier changed");
    CHECK([SPDFMacFileExplorerPreferenceIdentifier(SPDFMacFileExplorerShenzhenFiles)
              isEqualToString:@"shenzhen-files"],
          "Shenzhen Files identifier changed");
    CHECK(SPDFMacFileExplorerPreferenceIdentifier(SPDFMacFileExplorerUnset) == nil,
          "an unset preference must not persist an identifier");
    CHECK(SPDFMacFileExplorerPreferenceFromIdentifier(@"shenzhen-files") == SPDFMacFileExplorerShenzhenFiles,
          "saved Shenzhen Files preference did not round-trip");
    CHECK(SPDFMacFileExplorerPreferenceFromIdentifier(@"system") == SPDFMacFileExplorerSystem,
          "saved system preference did not round-trip");
    CHECK(SPDFMacFileExplorerPreferenceFromIdentifier(@"unknown") == SPDFMacFileExplorerUnset,
          "unknown preference was mistaken for an explicit choice");
    CHECK(SPDFMacFileExplorerPreferenceFromIdentifier(nil) == SPDFMacFileExplorerUnset,
          "missing preference was mistaken for an explicit choice");
}

// The whole point of the tri-state: derive only when nothing was chosen.
static void test_resolution(void) {
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerUnset, YES) == SPDFMacFileExplorerShenzhenFiles,
          "unset preference did not default to an installed Shenzhen Files");
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerUnset, NO) == SPDFMacFileExplorerSystem,
          "unset preference did not fall back to the system file manager");
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerSystem, YES) == SPDFMacFileExplorerSystem,
          "an explicit Finder choice was flipped by an installed Shenzhen Files");
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerSystem, NO) == SPDFMacFileExplorerSystem,
          "an explicit Finder choice did not survive");
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerShenzhenFiles, YES) ==
              SPDFMacFileExplorerShenzhenFiles,
          "an explicit Shenzhen Files choice did not survive");
    CHECK(SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerShenzhenFiles, NO) ==
              SPDFMacFileExplorerShenzhenFiles,
          "an explicit Shenzhen Files choice was dropped while the app is missing");
}

static void test_persistence_and_menu(void) {
    NSUserDefaults* defaults = NSUserDefaults.standardUserDefaults;
    NSString* saved = [defaults stringForKey:@"SPDFFileExplorerPreference"];
    SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerShenzhenFiles);
    CHECK(SPDFMacStoredFileExplorerPreference() == SPDFMacFileExplorerShenzhenFiles,
          "Shenzhen Files preference was not persisted");
    SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerSystem);
    CHECK(SPDFMacStoredFileExplorerPreference() == SPDFMacFileExplorerSystem,
          "system preference was not persisted");
    CHECK(SPDFMacCurrentFileExplorerPreference() == SPDFMacFileExplorerSystem,
          "an explicit system preference did not survive resolution");
    SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerUnset);
    CHECK(SPDFMacStoredFileExplorerPreference() == SPDFMacFileExplorerUnset,
          "clearing the preference did not restore the unset state");
    CHECK(SPDFMacCurrentFileExplorerPreference() ==
              (SPDFMacShenzhenFilesIsAvailable() ? SPDFMacFileExplorerShenzhenFiles : SPDFMacFileExplorerSystem),
          "the unset preference did not resolve against Shenzhen Files availability");

    NSMenu* settings = [[NSMenu alloc] initWithTitle:@"Settings"];
    SPDFMacInstallFileExplorerSettingsMenu(settings);
    CHECK(settings.numberOfItems == 1, "file-manager settings item was not installed");
    NSMenuItem* item = [settings itemAtIndex:0];
    CHECK([item.title isEqualToString:@"File Manager"], "file-manager settings title changed");
    CHECK(item.submenu.numberOfItems == 2, "file-manager submenu does not contain both choices");
    check_menu_state(item.submenu, SPDFMacFileExplorerUnset);
    SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerSystem);
    check_menu_state(item.submenu, SPDFMacFileExplorerSystem);
    SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerShenzhenFiles);
    check_menu_state(item.submenu, SPDFMacFileExplorerShenzhenFiles);

    if (saved) [defaults setObject:saved forKey:@"SPDFFileExplorerPreference"];
    else [defaults removeObjectForKey:@"SPDFFileExplorerPreference"];
}

static void test_system_route(void) {
    NSString* path = make_fixture(NO);
    __block NSInteger lookupCount = 0;
    __block NSInteger launchCount = 0;
    __block NSInteger systemCount = 0;
    __block BOOL revealedDirectory = YES;

    BOOL accepted = SPDFMacRevealPathWithHandlers(
        path, SPDFMacFileExplorerSystem,
        ^NSURL*(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          lookupCount++;
          return nil;
        },
        ^(NSURL* applicationURL, NSArray<NSURL*>* URLs, void (^completion)(NSError*)) {
          (void)applicationURL;
          (void)URLs;
          (void)completion;
          launchCount++;
        },
        ^(NSURL* URL, BOOL isDirectory) {
          systemCount++;
          revealedDirectory = isDirectory;
          CHECK([URL.path isEqualToString:path], "system reveal received the wrong path");
        });
    CHECK(accepted, "valid system reveal was rejected");
    CHECK(lookupCount == 0 && launchCount == 0, "system route consulted Shenzhen Files");
    CHECK(systemCount == 1 && !revealedDirectory, "system file route was not selected exactly once");
    remove_fixture(path);
}

static void test_shenzhen_route(void) {
    NSString* path = make_fixture(YES);
    NSURL* appURL = [NSURL fileURLWithPath:@"/Applications/Shenzhen Files.app" isDirectory:YES];
    __block NSInteger systemCount = 0;
    __block NSInteger launchCount = 0;

    BOOL accepted = SPDFMacRevealPathWithHandlers(
        path, SPDFMacFileExplorerShenzhenFiles,
        ^NSURL*(NSString* bundleIdentifier) {
          CHECK([bundleIdentifier isEqualToString:SPDFMacShenzhenFilesBundleIdentifier],
                "unexpected Shenzhen Files bundle identifier");
          return appURL;
        },
        ^(NSURL* applicationURL, NSArray<NSURL*>* URLs, void (^completion)(NSError*)) {
          launchCount++;
          CHECK([applicationURL isEqual:appURL], "launcher received the wrong application");
          CHECK(URLs.count == 1 && [URLs.firstObject.path isEqualToString:path], "launcher received the wrong path");
          completion(nil);
        },
        ^(NSURL* URL, BOOL isDirectory) {
          (void)URL;
          (void)isDirectory;
          systemCount++;
        });
    CHECK(accepted && launchCount == 1, "Shenzhen Files route was not launched");
    CHECK(systemCount == 0, "successful Shenzhen Files launch also opened Finder");
    remove_fixture(path);
}

static void test_fallbacks(void) {
    NSString* path = make_fixture(NO);
    for (NSInteger mode = 0; mode < 2; ++mode) {
        __block NSInteger systemCount = 0;
        SPDFMacExplorerApplicationLookup lookup = ^NSURL*(NSString* bundleIdentifier) {
          (void)bundleIdentifier;
          return mode == 0 ? nil : [NSURL fileURLWithPath:@"/Applications/Shenzhen Files.app"];
        };
        SPDFMacExplorerApplicationLauncher launcher =
            ^(NSURL* applicationURL, NSArray<NSURL*>* URLs, void (^completion)(NSError*)) {
              (void)applicationURL;
              (void)URLs;
              NSError* error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
              completion(error);
            };
        BOOL accepted = SPDFMacRevealPathWithHandlers(path, SPDFMacFileExplorerShenzhenFiles, lookup, launcher,
                                                      ^(NSURL* URL, BOOL isDirectory) {
                                                        (void)URL;
                                                        (void)isDirectory;
                                                        systemCount++;
                                                      });
        CHECK(accepted && systemCount == 1, "Shenzhen Files failure did not fall back exactly once");
    }
    CHECK(!SPDFMacRevealPathWithHandlers(@"/definitely/missing", SPDFMacFileExplorerSystem, nil, nil,
                                        ^(NSURL* URL, BOOL isDirectory) {
                                          (void)URL;
                                          (void)isDirectory;
                                        }),
          "missing path was accepted");
    remove_fixture(path);
}

// The folder the native Open panel starts in.
static void test_browse_start_directory(void) {
    NSString* file = make_fixture(NO);
    NSString* directory = file.stringByDeletingLastPathComponent;
    NSString* recent = make_fixture(NO);
    NSString* recentDirectory = recent.stringByDeletingLastPathComponent;
    NSString* home = NSHomeDirectory();

    CHECK([SPDFMacBrowseStartDirectory(file, @[ recent ]) isEqualToString:directory],
          "the active document's folder did not win");
    CHECK([SPDFMacBrowseStartDirectory(nil, @[ recent ]) isEqualToString:recentDirectory],
          "the newest recent document's folder was not used");
    CHECK([SPDFMacBrowseStartDirectory(@"", @[ @"/definitely/missing/a.pdf", recent ])
              isEqualToString:recentDirectory],
          "a stale recent path was not skipped");
    CHECK([SPDFMacBrowseStartDirectory(nil, nil) isEqualToString:home], "the home folder is not the last resort");
    CHECK([SPDFMacBrowseStartDirectory(@"/definitely/missing/a.pdf", @[]) isEqualToString:home],
          "a missing document folder did not fall back home");
    remove_fixture(file);
    remove_fixture(recent);
}

int main(void) {
    @autoreleasepool {
        test_identifiers();
        test_resolution();
        test_persistence_and_menu();
        test_system_route();
        test_shenzhen_route();
        test_fallbacks();
        test_browse_start_directory();
    }
    if (failures) return 1;
    puts("SPDF mac file-explorer preference tests passed");
    return 0;
}
