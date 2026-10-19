#import "SPDFMacMarkdownEditor.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacCollectionPathPolicy.h"

NSString* const SPDFMacMarkdownEditorPreferenceDefaultsKey = @"SPDFMarkdownEditorBundleIdentifier";

NSURL* SPDFMacMarkdownEditorPickerDirectoryURL(void) {
    return [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];
}

NSString* SPDFMacStoredMarkdownEditorBundleIdentifier(void) {
    NSString* value = [NSUserDefaults.standardUserDefaults
        stringForKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
    return value.length ? value : nil;
}

void SPDFMacSetMarkdownEditorBundleIdentifier(NSString* bundleIdentifier) {
    if (bundleIdentifier.length)
        [NSUserDefaults.standardUserDefaults setObject:bundleIdentifier
                                                forKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
    else
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SPDFMacMarkdownEditorPreferenceDefaultsKey];
}

static NSURL* spdf_valid_markdown_source_url(NSString* path) {
    if (!SPDFIsRenderedTextDocumentPath(path)) return nil;
    NSString* standardized = path.stringByStandardizingPath;
    BOOL isDirectory = NO;
    if (!standardized.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:standardized isDirectory:&isDirectory] || isDirectory)
        return nil;
    return [NSURL fileURLWithPath:standardized isDirectory:NO];
}

static BOOL spdf_editor_choice_is_usable(NSURL* applicationURL, NSString* bundleIdentifier) {
    return applicationURL.isFileURL &&
           [applicationURL.pathExtension caseInsensitiveCompare:@"app"] == NSOrderedSame &&
           bundleIdentifier.length > 0;
}

BOOL SPDFMacOpenMarkdownSourceWithHandlers(NSString* path, NSString* storedBundleIdentifier,
                                           SPDFMacEditorApplicationLookup lookup,
                                           SPDFMacEditorApplicationPicker picker,
                                           SPDFMacEditorApplicationLauncher launcher,
                                           SPDFMacEditorPreferenceWriter writer) {
    NSURL* documentURL = spdf_valid_markdown_source_url(path);
    if (!documentURL || !lookup || !picker || !launcher || !writer) return NO;

    NSURL* storedApplication = storedBundleIdentifier.length ? lookup(storedBundleIdentifier) : nil;
    if (storedApplication) {
        launcher(storedApplication, documentURL, ^(NSError* error) { (void)error; });
        return YES;
    }

    picker(^(NSURL* applicationURL, NSString* bundleIdentifier) {
      if (!spdf_editor_choice_is_usable(applicationURL, bundleIdentifier)) return;
      writer(bundleIdentifier);
      launcher(applicationURL, documentURL, ^(NSError* error) { (void)error; });
    });
    return YES;
}

static SPDFMacEditorApplicationLookup spdf_workspace_editor_lookup(void) {
    return ^NSURL*(NSString* bundleIdentifier) {
      return [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleIdentifier];
    };
}

static SPDFMacEditorApplicationLauncher spdf_workspace_editor_launcher(void) {
    return ^(NSURL* applicationURL, NSURL* documentURL, void (^completion)(NSError*)) {
      NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
      configuration.activates = YES;
      [NSWorkspace.sharedWorkspace openURLs:@[ documentURL ]
                       withApplicationAtURL:applicationURL
                              configuration:configuration
                          completionHandler:^(NSRunningApplication* application, NSError* error) {
                            (void)application;
                            if (completion) completion(error);
                          }];
    };
}

static SPDFMacEditorApplicationPicker spdf_native_editor_picker(NSWindow* parentWindow) {
    return ^(SPDFMacEditorPickerCompletion completion) {
      NSOpenPanel* panel = [NSOpenPanel openPanel];
      panel.title = @"Choose Text Editor";
      panel.prompt = @"Choose Editor";
      panel.message = @"Choose an application to open Markdown, text and code files.";
      panel.canChooseFiles = YES;
      panel.canChooseDirectories = NO;
      panel.allowsMultipleSelection = NO;
      panel.allowedContentTypes = @[ UTTypeApplicationBundle ];
      panel.directoryURL = SPDFMacMarkdownEditorPickerDirectoryURL();
      void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
        NSURL* applicationURL = response == NSModalResponseOK ? panel.URL : nil;
        NSString* bundleIdentifier = applicationURL ? [NSBundle bundleWithURL:applicationURL].bundleIdentifier : nil;
        completion(applicationURL, bundleIdentifier);
      };
      if (parentWindow)
          [panel beginSheetModalForWindow:parentWindow completionHandler:finish];
      else
          finish([panel runModal]);
    };
}

BOOL SPDFMacOpenMarkdownSourceInEditor(NSString* path, NSWindow* parentWindow) {
    if (SPDFMacPathIsCollectionArchive(path)) return NO;
    return SPDFMacOpenMarkdownSourceWithHandlers(
        path, SPDFMacStoredMarkdownEditorBundleIdentifier(), spdf_workspace_editor_lookup(),
        spdf_native_editor_picker(parentWindow), spdf_workspace_editor_launcher(),
        ^(NSString* bundleIdentifier) { SPDFMacSetMarkdownEditorBundleIdentifier(bundleIdentifier); });
}

@interface SPDFMacMarkdownEditorMenuTarget : NSObject
@end

@implementation SPDFMacMarkdownEditorMenuTarget

+ (instancetype)sharedTarget {
    static SPDFMacMarkdownEditorMenuTarget* target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [SPDFMacMarkdownEditorMenuTarget new]; });
    return target;
}

- (void)chooseMarkdownEditor:(id)sender {
    (void)sender;
    spdf_native_editor_picker(NSApp.keyWindow)(^(NSURL* applicationURL, NSString* bundleIdentifier) {
      if (spdf_editor_choice_is_usable(applicationURL, bundleIdentifier))
          SPDFMacSetMarkdownEditorBundleIdentifier(bundleIdentifier);
    });
}

@end


void SPDFMacInstallMarkdownEditorSettingsMenu(NSMenu* settingsMenu) {
    if (!settingsMenu) return;
    NSMenuItem* item = [settingsMenu addItemWithTitle:@"Choose Text Editor..."
                                               action:@selector(chooseMarkdownEditor:)
                                        keyEquivalent:@""];
    item.target = SPDFMacMarkdownEditorMenuTarget.sharedTarget;
}
