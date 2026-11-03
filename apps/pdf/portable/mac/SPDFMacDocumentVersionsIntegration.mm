// Versions of a document in the reader (SPDFMacDocumentVersionsIntegration.h).
//
// Keeping the previous text when another app rewrites a commented document needs that text after it is gone, so each
// opened Markdown or PDF document gets a copy-on-write clone (clonefile: no data is copied, the clone keeps the old
// blocks only once the file is rewritten) in a temporary folder on the same disk. When the reader notices the change,
// before it reloads and moves the comments onto the new text, the clone becomes the previous version. A disk that
// cannot clone gets a plain copy for documents up to 16 MB, and nothing for larger ones.

#import "SPDFMacDocumentVersionsIntegration.h"
#import "SPDFMacDocumentVersions.h"
#import "SPDFMacCollectionCompare.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacQuitFinishing.h"
#import "SPDFMacUIHelpers.h"

#import <objc/runtime.h>
#include <sys/clonefile.h>

static NSString* const kSettingKey = @"keepVersionsWhenChanged";
static BOOL gKeepWhenChanged = YES;

NSDictionary* SPDFDocumentVersionsLoadSettings(NSDictionary* settings) {
    id value = [settings isKindOfClass:NSDictionary.class] ? settings[kSettingKey] : nil;
    // Only a real boolean false turns it off, so a hand-edited typo keeps the comments safe.
    gKeepWhenChanged = !([value isKindOfClass:NSNumber.class] &&
                         CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && ![value boolValue]);
    return settings;
}

NSDictionary* SPDFDocumentVersionsSettingsForSaving(NSDictionary* settings) {
    NSMutableDictionary* out = [settings mutableCopy];
    out[kSettingKey] = @(gKeepWhenChanged);
    return out;
}

BOOL SPDFDocumentVersionsKeepWhenChanged(void) { return gKeepWhenChanged; }
void SPDFDocumentVersionsSetKeepWhenChanged(BOOL keep) { gKeepWhenChanged = keep; }

static NSDate* ModificationDate(NSString* path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

static NSString* VersionLabel(SPDFDocumentVersion* version) {
    NSString* date = [NSDateFormatter localizedStringFromDate:version.date dateStyle:NSDateFormatterMediumStyle
                                                    timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:@"%@ · %@", version.name, date];
}

static SPDFDocumentVersionCarry CarryNamed(NSString* name) {
    if ([name isEqualToString:@"all"]) return SPDFDocumentVersionCarryAll;
    if ([name isEqualToString:@"none"]) return SPDFDocumentVersionCarryNone;
    return SPDFDocumentVersionCarryOpen;
}

@interface ShenzhenMacDelegate (SPDFDocumentVersionsActions)
- (NSWindow*)versionsWindow;
- (NSString*)versionsActivePath;
- (void)versionsSnapshot:(NSString*)path;
- (void)versionsAnnounce:(NSString*)message path:(NSString*)path;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)versionsNewVersionForPath:(NSString*)path;
@end

// Target of every version menu item (the reader's own -validateMenuItem: does not know them), and the File ▸ Versions
// submenu's delegate, which fills it for the document being read each time it opens.
@interface SPDFDocumentVersionsMenuTarget : NSObject <NSMenuDelegate, NSMenuItemValidation>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@end

@implementation SPDFDocumentVersionsMenuTarget
+ (instancetype)targetForReader:(ShenzhenMacDelegate*)reader {
    static char key;
    SPDFDocumentVersionsMenuTarget* target = objc_getAssociatedObject(reader, &key);
    if (!target) {
        target = [SPDFDocumentVersionsMenuTarget new];
        target.reader = reader;
        objc_setAssociatedObject(reader, &key, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return target;
}

- (NSString*)pathForItem:(NSMenuItem*)item {
    id path = item.representedObject;
    return [path isKindOfClass:NSString.class] ? path : [self.reader versionsActivePath];
}

- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(newVersion:)) {
        NSString* path = [self pathForItem:item];
        return SPDFDocumentVersionsSupportsPath(path) && !SPDFMacPathIsCollectionArchive(path) &&
               [NSFileManager.defaultManager fileExistsAtPath:path];
    }
    return item.action != nil;
}

- (void)newVersion:(NSMenuItem*)item {
    [self.reader versionsNewVersionForPath:[self pathForItem:item]];
}

- (void)openVersion:(NSMenuItem*)item {
    if ([item.representedObject isKindOfClass:NSString.class]) [self.reader openPaths:@[ item.representedObject ]];
}

- (void)compareVersions:(NSMenuItem*)item {
    NSArray* pair = [item.representedObject isKindOfClass:NSArray.class] ? item.representedObject : nil;
    if (pair.count != 2) return;
    SPDFDocumentVersion *older = pair[0], *newer = pair[1];
    SPDFMacShowCollectionComparison([NSURL fileURLWithPath:older.path], [NSURL fileURLWithPath:newer.path],
                                    VersionLabel(older), VersionLabel(newer), self.reader.versionsWindow);
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
    [menu removeAllItems];
    NSString* path = [self.reader versionsActivePath];
    NSArray<SPDFDocumentVersion*>* versions =
        SPDFDocumentVersionsSupportsPath(path) ? SPDFDocumentVersionsList(path) : @[];
    if (versions.count < 2) {
        NSMenuItem* none = [menu addItemWithTitle:@"No Earlier Versions" action:nil keyEquivalent:@""];
        none.enabled = NO;
        return;
    }
    [self fillMenu:menu versions:versions showing:path];
}

// The versions, newest first, each opening it; then "Compare vN with" each later one.
- (void)fillMenu:(NSMenu*)menu versions:(NSArray<SPDFDocumentVersion*>*)versions showing:(NSString*)path {
    for (SPDFDocumentVersion* version in versions.reverseObjectEnumerator) {
        NSString* title = VersionLabel(version);
        if (version.current) title = [title stringByAppendingString:@" · Current"];
        NSMenuItem* item = [menu addItemWithTitle:title action:@selector(openVersion:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = version.path;
        BOOL showing = [version.path isEqualToString:path.stringByStandardizingPath];
        item.state = showing ? NSControlStateValueOn : NSControlStateValueOff;
        if (version.commentsPath) item.toolTip = @"Has comments";
    }
    [menu addItem:NSMenuItem.separatorItem];
    for (NSUInteger i = 0; i + 1 < versions.count; i++) {
        NSMenuItem* compare = [menu addItemWithTitle:[NSString stringWithFormat:@"Compare %@ with", versions[i].name]
                                              action:nil keyEquivalent:@""];
        NSMenu* later = [[NSMenu alloc] initWithTitle:compare.title];
        for (NSUInteger j = i + 1; j < versions.count; j++) {
            NSMenuItem* item = [later addItemWithTitle:VersionLabel(versions[j]) action:@selector(compareVersions:)
                                         keyEquivalent:@""];
            item.target = self;
            item.representedObject = @[ versions[i], versions[j] ];
        }
        compare.submenu = later;
    }
}
@end

void SPDFInstallDocumentVersionsMenu(NSMenu* fileMenu, id reader) {
    SPDFDocumentVersionsMenuTarget* target = [SPDFDocumentVersionsMenuTarget targetForReader:reader];
    NSInteger index = [fileMenu indexOfItemWithTitle:@"Save As..."];
    index = index < 0 ? fileMenu.numberOfItems : index + 1;
    NSMenuItem* create = [[NSMenuItem alloc] initWithTitle:@"New Version…" action:@selector(newVersion:)
                                             keyEquivalent:@""];
    create.target = target;
    NSMenuItem* versions = [[NSMenuItem alloc] initWithTitle:@"Versions" action:nil keyEquivalent:@""];
    versions.submenu = [[NSMenu alloc] initWithTitle:@"Versions"];
    versions.submenu.delegate = target;
    [fileMenu insertItem:create atIndex:index];
    [fileMenu insertItem:versions atIndex:index + 1];
}

@implementation ShenzhenMacDelegate (SPDFDocumentVersions)
static char kSnapshotsKey;

- (NSWindow*)versionsWindow {
    return _window;
}

- (NSString*)versionsActivePath {
    return [self hasActiveDocument] ? _path.stringByStandardizingPath : nil;
}

- (void)addVersionItemsToMenu:(NSMenu*)menu path:(NSString*)path {
    if (!SPDFDocumentVersionsSupportsPath(path) || SPDFMacPathIsCollectionArchive(path)) return;
    SPDFDocumentVersionsMenuTarget* target = [SPDFDocumentVersionsMenuTarget targetForReader:self];
    NSMenuItem* create = [menu addItemWithTitle:@"New Version…" action:@selector(newVersion:) keyEquivalent:@""];
    create.target = target;
    create.representedObject = path;
    spdf_set_menu_item_system_symbol(create, @"plus.square.on.square");
    NSArray<SPDFDocumentVersion*>* versions = SPDFDocumentVersionsList(path);
    if (versions.count < 2) return;
    NSMenuItem* list = [menu addItemWithTitle:@"Versions" action:nil keyEquivalent:@""];
    list.submenu = [[NSMenu alloc] initWithTitle:@"Versions"];
    [target fillMenu:list.submenu versions:versions showing:path];
    spdf_set_menu_item_system_symbol(list, @"clock.arrow.circlepath");
}

#pragma mark New Version

- (void)versionsNewVersionForPath:(NSString*)path {
    NSArray<SPDFDocumentVersion*>* versions = SPDFDocumentVersionsList(path);
    SPDFDocumentVersion* current = versions.lastObject;
    if (!current) { NSBeep(); return; }
    NSString* frozenName = [NSString stringWithFormat:@"v%ld", (long)current.number];
    NSString* nextName = [NSString stringWithFormat:@"v%ld", (long)current.number + 1];
    NSUInteger open = 0;
    SPDFDocumentVersionsCommentCount(current.path, &open);
    NSAlert* alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Keep this as %@ and start %@?", frozenName, nextName];
    alert.informativeText = [NSString stringWithFormat:@"%@ stays as it is now, with its comments, in “%@ %@.%@”. "
                                                       @"“%@” becomes %@, for you or an agent to rewrite.",
                             frozenName, current.path.lastPathComponent.stringByDeletingPathExtension, frozenName,
                             current.path.pathExtension, current.path.lastPathComponent, nextName];
    [alert addButtonWithTitle:[NSString stringWithFormat:@"Start %@", nextName]];
    [alert addButtonWithTitle:@"Cancel"];
    NSButton* carry = nil;
    if (open) {
        NSString* title = open == 1 ? [NSString stringWithFormat:@"Bring the open comment to %@", nextName]
                                    : [NSString stringWithFormat:@"Bring the %lu open comments to %@",
                                                                 (unsigned long)open, nextName];
        carry = [NSButton checkboxWithTitle:title target:nil action:nil];
        carry.state = NSControlStateValueOn;
        [carry sizeToFit];
        alert.accessoryView = carry;
    }
    __weak ShenzhenMacDelegate* weakSelf = self;
    void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
      if (response != NSAlertFirstButtonReturn) return;
      NSError* error = nil;
      NSString* mode = carry.state == NSControlStateValueOn ? @"open" : @"none";
      NSDictionary* made = [weakSelf versionsCreateForPath:current.path carry:mode error:&error];
      if (!made) [weakSelf showError:@"Could not start a new version" detail:error.localizedDescription ?: @""];
    };
    if (_window.visible) [alert beginSheetModalForWindow:_window completionHandler:finish];
    else finish([alert runModal]);
}

- (NSDictionary*)versionsCreateForPath:(NSString*)path carry:(NSString*)carry error:(NSError**)error {
    NSString* current = SPDFDocumentVersionsCurrentPath(path);
    SPDFDocumentVersion* version = SPDFDocumentVersionsCreate(current, CarryNamed(carry), error);
    if (!version) return nil;
    [self versionsSnapshot:current];  // what the file holds now is the base for noticing the next rewrite
    NSMutableDictionary* snapshot = [self.versionSnapshots[current] mutableCopy];
    snapshot[@"afterNewVersion"] = @YES;
    if (snapshot[@"copy"]) self.versionSnapshots[current] = snapshot;
    BOOL active = [_path.stringByStandardizingPath isEqualToString:current];
    if (active && ![self isMarkdownActive]) {
        // A PDF loses the comments that were not brought along: show the file as it now is.
        [self refreshActiveTabCachedFileAttributesAfterSelfSave];
        [self reloadSelectedTabFromDiskChange];
    } else if (active) {
        [self rebuildSidebar];
    }
    [self versionsAnnounce:[NSString stringWithFormat:@"%@ kept with its comments. This is now v%ld.", version.name,
                                                      (long)version.number + 1] path:current];
    return version.dictionaryRepresentation;
}

- (NSArray<NSDictionary*>*)versionsListForPath:(NSString*)path {
    return [SPDFDocumentVersionsList(path) valueForKey:@"dictionaryRepresentation"];
}

- (BOOL)versionsCompareForPath:(NSString*)path from:(NSInteger)older to:(NSInteger)newer error:(NSError**)error {
    SPDFDocumentVersion *from = nil, *to = nil;
    for (SPDFDocumentVersion* version in SPDFDocumentVersionsList(path)) {
        if (version.number == older) from = version;
        if (version.number == newer) to = version;
    }
    if (!from || !to || older == newer) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Versions" code:2 userInfo:@{
            NSLocalizedDescriptionKey :
                [NSString stringWithFormat:@"There is no v%ld and v%ld to compare.", (long)older, (long)newer]}];
        return NO;
    }
    if (older > newer) { SPDFDocumentVersion* swap = from; from = to; to = swap; }
    SPDFMacShowCollectionComparison([NSURL fileURLWithPath:from.path], [NSURL fileURLWithPath:to.path],
                                    VersionLabel(from), VersionLabel(to), _window);
    return YES;
}

#pragma mark Keeping the previous text

- (NSMutableDictionary<NSString*, NSDictionary*>*)versionSnapshots {
    NSMutableDictionary* snapshots = objc_getAssociatedObject(self, &kSnapshotsKey);
    if (!snapshots) {
        snapshots = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kSnapshotsKey, snapshots, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return snapshots;
}

- (void)versionsForgetSnapshot:(NSString*)path {
    NSDictionary* old = self.versionSnapshots[path];
    if (old[@"folder"]) [NSFileManager.defaultManager removeItemAtPath:old[@"folder"] error:nil];
    [self.versionSnapshots removeObjectForKey:path];
}

// After the first frame, like Collection's capture: nothing here may slow a launch.
- (void)versionsDocumentDidOpen:(NSString*)path {
    if (!SPDFDocumentVersionsKeepWhenChanged() || !SPDFDocumentVersionsSupportsPath(path)) return;
    __weak ShenzhenMacDelegate* weakSelf = self;
    NSString* standard = path.stringByStandardizingPath;
    spdf_mac_after_first_paint(^{ [weakSelf versionsSnapshot:standard]; });
}

- (void)versionsSnapshot:(NSString*)path {
    if (!SPDFDocumentVersionsKeepWhenChanged() || !SPDFDocumentVersionsSupportsPath(path) ||
        SPDFMacPathIsCollectionArchive(path) || SPDFDocumentVersionsIsFrozenPath(path) ||
        ![NSFileManager.defaultManager isWritableFileAtPath:path.stringByDeletingLastPathComponent])
        return;
    NSFileManager* files = NSFileManager.defaultManager;
    NSDictionary* attributes = [files attributesOfItemAtPath:path error:nil];
    NSDictionary* old = self.versionSnapshots[path];
    if (!attributes ||
        ([old[@"date"] isEqual:attributes.fileModificationDate] && [old[@"size"] isEqual:@(attributes.fileSize)]))
        return;
    [self versionsForgetSnapshot:path];
    NSURL* folder = [files URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
                         appropriateForURL:[NSURL fileURLWithPath:path] create:YES error:nil];
    NSString* copy = [folder.path stringByAppendingPathComponent:path.lastPathComponent];
    BOOL ok = copy && clonefile(path.fileSystemRepresentation, copy.fileSystemRepresentation, 0) == 0;
    if (!ok && copy && attributes.fileSize <= 16 * 1024 * 1024) ok = [files copyItemAtPath:path toPath:copy error:nil];
    if (!ok) {
        if (folder) [files removeItemAtURL:folder error:nil];
        return;
    }
    self.versionSnapshots[path] = @{@"folder" : folder.path, @"copy" : copy, @"date" : attributes.fileModificationDate,
                                    @"size" : @(attributes.fileSize)};
}

// Right after New Version the document still holds the version just kept, with copies of its open comments: the next
// rewrite is the new version being written, not a version to keep. It is one to keep once the owner has commented on
// it again (a Markdown comment not on the kept version; a PDF comment re-saves the file and so a new snapshot).
- (BOOL)versionsSnapshotIsLatestVersion:(NSDictionary*)snapshot path:(NSString*)path markdown:(BOOL)markdown {
    NSArray<SPDFDocumentVersion*>* versions = SPDFDocumentVersionsList(path);
    SPDFDocumentVersion* latest = versions.count > 1 ? versions[versions.count - 2] : nil;
    if (!latest) return NO;
    if (!markdown) return [snapshot[@"afterNewVersion"] boolValue];
    if (![NSFileManager.defaultManager contentsEqualAtPath:latest.path andPath:snapshot[@"copy"]]) return NO;
    NSSet* (^keys)(NSString*) = ^NSSet*(NSString* file) {
      NSString* text = file ? [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] : nil;
      NSMutableSet* set = [NSMutableSet set];
      for (SPDFMarkdownComment* comment in text ? SPDFMarkdownCommentsParseFile(text) : @[])
          [set addObject:[NSString stringWithFormat:@"%@\n%@\n%@\n%@", comment.quote, comment.text, comment.author,
                                                    comment.date]];
      return set;
    };
    return [keys(SPDFMarkdownCommentsFilePath(path)) isSubsetOfSet:keys(latest.commentsPath)];
}

- (void)versionsDocumentWillReloadAfterChange:(NSString*)path {
    [self versionsKeepPreviousOf:path.stringByStandardizingPath attempt:0];
}

- (void)versionsKeepPreviousOf:(NSString*)path attempt:(NSInteger)attempt {
    NSDictionary* snapshot = self.versionSnapshots[path];
    if (!snapshot || !SPDFDocumentVersionsKeepWhenChanged()) return;
    NSFileManager* files = NSFileManager.defaultManager;
    NSDictionary* attributes = [files attributesOfItemAtPath:path error:nil];
    if (!attributes) {
        // Replaced by a rename that has not landed yet: look again shortly, for about two seconds.
        if (attempt >= 20) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          [self versionsKeepPreviousOf:path attempt:attempt + 1];
        });
        return;
    }
    if ([snapshot[@"date"] isEqual:attributes.fileModificationDate] &&
        [snapshot[@"size"] isEqual:@(attributes.fileSize)])
        return;
    BOOL markdown = ![path.pathExtension.lowercaseString isEqualToString:@"pdf"];
    // A Markdown document's comments are beside it; a PDF's were inside the text it held.
    NSUInteger comments = markdown ? SPDFDocumentVersionsCommentCount(path, NULL)
                                   : SPDFDocumentVersionsCommentCount(snapshot[@"copy"], NULL);
    if (!comments || [files contentsEqualAtPath:path andPath:snapshot[@"copy"]] ||
        [self versionsSnapshotIsLatestVersion:snapshot path:path markdown:markdown]) {
        [self versionsSnapshot:path];  // the new text is the base for noticing the next rewrite
        return;
    }
    NSError* error = nil;
    SPDFDocumentVersion* version = SPDFDocumentVersionsKeepPrevious(path, snapshot[@"copy"], snapshot[@"date"],
                                                                    markdown ? SPDFDocumentVersionCarryOpen
                                                                             : SPDFDocumentVersionCarryNone, &error);
    [self versionsSnapshot:path];
    if (!version) {
        [self showError:@"Could not keep the earlier version" detail:error.localizedDescription ?: path];
        return;
    }
    [self versionsAnnounce:[NSString stringWithFormat:@"Changed by another app. The earlier text is %@, with your "
                                                      @"comments.", version.name] path:path];
}

// In the status bar, and again once the reload under way has put its own status there.
- (void)versionsAnnounce:(NSString*)message path:(NSString*)path {
    if (![_path.stringByStandardizingPath isEqualToString:path]) return;
    _statusLabel.stringValue = message;
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (strongSelf && [strongSelf->_path.stringByStandardizingPath isEqualToString:path])
          strongSelf->_statusLabel.stringValue = message;
    });
}
@end
