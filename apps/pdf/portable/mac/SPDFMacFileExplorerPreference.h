#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Tri-state on purpose. `Unset` means the user never picked a file manager, so
// the app derives one (Shenzhen Files when installed, otherwise the system file
// manager). An explicit choice always wins — a user who deliberately picked
// Finder keeps Finder even once Shenzhen Files is installed.
typedef NS_ENUM(NSInteger, SPDFMacFileExplorerPreference) {
    SPDFMacFileExplorerUnset = -1,
    SPDFMacFileExplorerSystem = 0,
    SPDFMacFileExplorerShenzhenFiles = 1,
};

typedef NSURL* _Nullable (^SPDFMacExplorerApplicationLookup)(NSString* bundleIdentifier);
typedef void (^SPDFMacExplorerApplicationLauncher)(NSURL* applicationURL, NSArray<NSURL*>* URLs,
                                                    void (^completion)(NSError* _Nullable error));
typedef void (^SPDFMacSystemRevealHandler)(NSURL* URL, BOOL isDirectory);

FOUNDATION_EXPORT NSString* const SPDFMacShenzhenFilesBundleIdentifier;

// Returns nil for `Unset` — an unset preference is stored as a missing key.
NSString* _Nullable SPDFMacFileExplorerPreferenceIdentifier(SPDFMacFileExplorerPreference preference);
// A missing or unrecognized identifier is `Unset`, never a silent System.
SPDFMacFileExplorerPreference SPDFMacFileExplorerPreferenceFromIdentifier(NSString* _Nullable identifier);
BOOL SPDFMacShenzhenFilesIsAvailable(void);
// Pure resolution of the stored tri-state against Shenzhen Files' availability.
SPDFMacFileExplorerPreference SPDFMacResolveFileExplorerPreference(SPDFMacFileExplorerPreference stored,
                                                                  BOOL shenzhenFilesAvailable);
// The raw stored choice, including `Unset`.
SPDFMacFileExplorerPreference SPDFMacStoredFileExplorerPreference(void);
// The resolved choice every file operation routes through.
SPDFMacFileExplorerPreference SPDFMacCurrentFileExplorerPreference(void);
void SPDFMacSetFileExplorerPreference(SPDFMacFileExplorerPreference preference);
void SPDFMacInstallFileExplorerSettingsMenu(NSMenu* settingsMenu);

// The folder the Open panel should start in: the active document's folder,
// else the newest recently-opened document's folder, else home.
NSString* SPDFMacBrowseStartDirectory(NSString* _Nullable documentPath, NSArray<NSString*>* _Nullable recentPaths);

// Returns NO only for an invalid path or missing handlers. A missing/failed
// Shenzhen Files launch falls back to the system file manager asynchronously.
BOOL SPDFMacRevealPathWithHandlers(NSString* path, SPDFMacFileExplorerPreference preference,
                                   SPDFMacExplorerApplicationLookup _Nullable lookup,
                                   SPDFMacExplorerApplicationLauncher _Nullable launcher,
                                   SPDFMacSystemRevealHandler systemReveal);
BOOL SPDFMacRevealPath(NSString* path, SPDFMacFileExplorerPreference preference);
BOOL SPDFMacRevealPathUsingPreference(NSString* path);

NS_ASSUME_NONNULL_END
