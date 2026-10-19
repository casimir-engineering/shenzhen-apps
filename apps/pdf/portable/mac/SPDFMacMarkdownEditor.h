#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NSURL* _Nullable (^SPDFMacEditorApplicationLookup)(NSString* bundleIdentifier);
typedef void (^SPDFMacEditorPickerCompletion)(NSURL* _Nullable applicationURL,
                                              NSString* _Nullable bundleIdentifier);
typedef void (^SPDFMacEditorApplicationPicker)(SPDFMacEditorPickerCompletion completion);
typedef void (^SPDFMacEditorApplicationLauncher)(NSURL* applicationURL, NSURL* documentURL,
                                                 void (^completion)(NSError* _Nullable error));
typedef void (^SPDFMacEditorPreferenceWriter)(NSString* bundleIdentifier);

FOUNDATION_EXPORT NSString* const SPDFMacMarkdownEditorPreferenceDefaultsKey;

// Native editor discovery starts where applications are actually selectable,
// rather than beside the Markdown document where every row is disabled.
NSURL* SPDFMacMarkdownEditorPickerDirectoryURL(void);
NSString* _Nullable SPDFMacStoredMarkdownEditorBundleIdentifier(void);
void SPDFMacSetMarkdownEditorBundleIdentifier(NSString* _Nullable bundleIdentifier);

// Injectable policy behind the UI: a valid stored editor launches immediately;
// otherwise the native picker runs, its choice is persisted, then launched.
// The source must be an existing Markdown file. Returns NO only when the
// request itself is invalid; picker cancellation is an accepted no-op.
BOOL SPDFMacOpenMarkdownSourceWithHandlers(NSString* path,
                                           NSString* _Nullable storedBundleIdentifier,
                                           SPDFMacEditorApplicationLookup lookup,
                                           SPDFMacEditorApplicationPicker picker,
                                           SPDFMacEditorApplicationLauncher launcher,
                                           SPDFMacEditorPreferenceWriter writer);

BOOL SPDFMacOpenMarkdownSourceInEditor(NSString* path, NSWindow* _Nullable parentWindow);
void SPDFMacInstallMarkdownEditorSettingsMenu(NSMenu* settingsMenu);

NS_ASSUME_NONNULL_END
