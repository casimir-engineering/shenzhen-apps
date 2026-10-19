#import "SPDFMacFileBrowsing.h"
#import "SPDFMacDocumentOpening.h"

#import "SPDFMacFileExplorerPreference.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacSupport.h"

@implementation ShenzhenMacDelegate (SPDFMacFileBrowsing)

// The native picker, rooted at `directoryURL` when we have one. Shenzhen Files
// cannot return a selection, so this stays the only way a browse hands a file
// straight back to the app.
- (void)runOpenPanelInDirectory:(NSURL*)directoryURL {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = spdf_document_content_types();
    if (directoryURL) panel.directoryURL = directoryURL;
    if ([panel runModal] == NSModalResponseOK && panel.URL.path.length) [self showDocumentsAtPaths:@[ panel.URL.path ]];
}

// Opening a document needs a chooser that hands the selection back to the app.
// Shenzhen Files can only open a window at a folder, so it is deliberately NOT
// on this path -- routing Open... to it would replace "pick a file" with "look
// at a file manager". The file-manager preference governs revealing a path,
// which is a genuine "take me there" request; see -showPathInFolder:.
- (void)browseForDocumentInDirectory:(NSString*)directory {
    NSString* standardized = directory.stringByStandardizingPath;
    BOOL isDirectory = NO;
    // A missing or unreadable folder opens the picker wherever macOS last left
    // it rather than failing the command.
    if (!standardized.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:standardized isDirectory:&isDirectory] || !isDirectory) {
        [self runOpenPanelInDirectory:nil];
        return;
    }
    [self runOpenPanelInDirectory:[NSURL fileURLWithPath:standardized isDirectory:YES]];
}

- (void)openDocument:(id)sender {
    (void)sender;
    [self browseForDocumentInDirectory:SPDFMacBrowseStartDirectory(_path, _recentlyOpenedPaths)];
}

// Cmd+Shift+O: type or paste a path to jump straight to it. A file opens
// directly; a folder opens the standard Open panel rooted at it. Handy for
// pasting a path from a terminal or a chat.
- (void)openPathPrompt:(id)sender {
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Open Path";
    alert.informativeText = @"Enter a file or folder path. A folder opens the Open panel there.";
    [alert addButtonWithTitle:@"Open"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 420, 24)];
    field.placeholderString = @"/path/to/file-or-folder";
    // Prefill from the clipboard when it already looks like a path, so a
    // copied path just needs Return.
    NSString* clip = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clip.length && ([clip hasPrefix:@"/"] || [clip hasPrefix:@"~"] || [clip hasPrefix:@"file://"]))
        field.stringValue = clip;
    alert.accessoryView = field;
    if (_window) [_window makeFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self openResolvedPath:field.stringValue];
}

// Resolves a user-entered path (file:// URL, ~ expansion, trimming) and either
// opens the file or points the Open panel at the folder.
- (void)openResolvedPath:(NSString*)input {
    NSString* path = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!path.length) return;
    if ([path hasPrefix:@"file://"]) {
        NSURL* url = [NSURL URLWithString:path];
        if (url.isFileURL && url.path.length) path = url.path;
    }
    path = path.stringByExpandingTildeInPath;
    path = path.stringByStandardizingPath ?: path;

    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        [self showError:@"Path not found" detail:[NSString stringWithFormat:@"No file or folder exists at:\n%@", path]];
        return;
    }
    if (isDirectory) {
        [self browseForDocumentInDirectory:path];
        return;
    }
    [self showDocumentsAtPaths:@[ path ]];
}

- (BOOL)openFilesFromPasteboard:(NSPasteboard*)pasteboard {
    NSArray<NSString*>* paths = SPDFDocumentPathsFromPasteboard(pasteboard);
    if (!paths.count) return NO;
    [self openPaths:paths];
    return YES;
}

@end
