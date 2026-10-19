#import "SPDFMacImageSaveIntegration.h"
#import "SPDFMacImageSave.h"
#import "SPDFMacDocumentToolInput.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacPastedImageState.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacCollectionIntegration.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
static char pendingImageSaveKey;

@interface SPDFImageSaveFormatPicker : NSObject
@property(nonatomic, weak) NSSavePanel* panel;
@property(nonatomic, strong) NSPopUpButton* popup;
@property(nonatomic, copy) NSString* imageExtension;
- (void)formatChanged:(id)sender;
@end
@implementation SPDFImageSaveFormatPicker
- (void)formatChanged:(id)sender {
    (void)sender;
    NSString* extension = self.popup.indexOfSelectedItem == 1 ? @"pdf" : self.imageExtension;
    UTType* type = [UTType typeWithFilenameExtension:extension];
    self.panel.allowedContentTypes = type ? @[type] : @[];
    self.panel.nameFieldStringValue = [self.panel.nameFieldStringValue.stringByDeletingPathExtension
        stringByAppendingPathExtension:extension];
}
@end

@interface ShenzhenMacDelegate (SPDFMacImageSavePrivate)
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (void)rememberActiveTabState;
- (void)rememberRecentlyOpenedPath:(NSString*)path;
- (void)updateTabStrip;
- (void)saveDocumentStateForTab:(SPDFDocumentTab*)tab;
- (BOOL)saveActiveDocumentAsWithPanelTitle:(NSString*)title statusMessage:(NSString*)message;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ShenzhenMacDelegate (SPDFMacImageSave)
- (void)saveDocumentAs:(id)sender {
    if ([self saveActiveImageAs]) return;
    if (SPDFMacPathIsCollectionArchive(_path)) { [self collectionSaveArchiveCopy:sender]; return; }
    if ([self isMarkdownActive]) {
        [self saveActiveMarkdownAsPDF];
        return;
    }
    [self saveActiveDocumentAsWithPanelTitle:@"Save PDF As" statusMessage:@"Document saved."];
}

- (BOOL)saveActiveImageAs {
    if (!_doc || !SPDFOCRPathNeedsPDF(_path)) return NO;
    [self saveImageTab:[self selectedTab] completion:nil];
    return YES;
}

- (BOOL)waitForPendingImageSave:(void (^)(BOOL))completion {
    NSMutableArray* waiting = objc_getAssociatedObject(self, &pendingImageSaveKey);
    if (!waiting) return NO;
    if (completion) [waiting addObject:[completion copy]];
    return YES;
}
- (void)finishPendingImageSave:(BOOL)saved {
    NSArray* waiting = [objc_getAssociatedObject(self, &pendingImageSaveKey) copy];
    objc_setAssociatedObject(self, &pendingImageSaveKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (void (^callback)(BOOL) in waiting) callback(saved);
}
- (void)saveImageTab:(SPDFDocumentTab*)originatingTab completion:(void (^)(BOOL))completion {
    // One export at a time: closing/quitting can join it instead of starting
    // a duplicate export or terminating the worker before installation.
    if ([self waitForPendingImageSave:completion]) return;
    NSString* source = [originatingTab.path copy];
    if (!source.length) { if (completion) completion(NO); return; }
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save Image As"; panel.canCreateDirectories = YES; panel.allowsOtherFileTypes = NO;
    panel.nameFieldStringValue = SPDFPathIsUnsavedPastedImage(source)
        ? [@"Pasted Image" stringByAppendingPathExtension:source.pathExtension] : source.lastPathComponent;
    // Managed snapshots and clipboard captures are sources, never output folders.
    NSString* directory = source.stringByDeletingLastPathComponent;
    if (SPDFMacPathIsCollectionArchive(source) || [directory hasPrefix:NSTemporaryDirectory()] ||
        [directory containsString:@"/Library/Application Support/"])
        directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (directory.length) panel.directoryURL = [NSURL fileURLWithPath:directory];
    SPDFImageSaveFormatPicker* picker = [SPDFImageSaveFormatPicker new];
    picker.panel = panel; picker.imageExtension = source.pathExtension;
    picker.popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 190, 26) pullsDown:NO];
    [picker.popup addItemsWithTitles:@[[NSString stringWithFormat:@"Image (%@)", source.pathExtension.uppercaseString], @"PDF"]];
    picker.popup.target = picker; picker.popup.action = @selector(formatChanged:);
    [picker.popup setAccessibilityLabel:@"File format"];
    NSTextField* label = [NSTextField labelWithString:@"Format:"];
    NSStackView* accessory = [NSStackView stackViewWithViews:@[label, picker.popup]];
    accessory.orientation = NSUserInterfaceLayoutOrientationHorizontal; accessory.spacing = 8;
    accessory.alignment = NSLayoutAttributeCenterY; accessory.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
    accessory.frame = NSMakeRect(0, 0, MAX(260, accessory.fittingSize.width), MAX(42, accessory.fittingSize.height));
    panel.accessoryView = accessory;
    [picker formatChanged:nil];
    if ([panel runModal] != NSModalResponseOK) { if (completion) completion(NO); return; }
    NSString* destination = panel.URL.path;
    if (SPDFMacPathIsCollectionArchive(destination)) {
        [self showError:@"Collection backups are read-only" detail:@"Choose a location outside Collection."];
        if (completion) completion(NO); return;
    }
    NSDictionary* destinationIdentity = SPDFImageSaveDestinationIdentity(destination);
    if (!destinationIdentity) {
        [self showError:@"Could not inspect destination" detail:@"Choose another location and try again."];
        if (completion) completion(NO); return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![self collectionProtectPath:destination operation:@"saving an image copy"]) { if (completion) completion(NO); return; }
    objc_setAssociatedObject(self, &pendingImageSaveKey, [NSMutableArray array], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (completion) [self waitForPendingImageSave:completion];
    BOOL asPDF = picker.popup.indexOfSelectedItem == 1;
    _statusLabel.stringValue = @"Saving a copy…";
    __weak ShenzhenMacDelegate* weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSError* error = nil;
            BOOL saved = SPDFSaveImageCopy(source, destination, asPDF, &error, destinationIdentity);
            dispatch_async(dispatch_get_main_queue(), ^{
                ShenzhenMacDelegate* owner = weakSelf;
                if (!owner) return;
                if (!saved) { [owner showError:@"Could not save image copy" detail:error.localizedDescription]; [owner finishPendingImageSave:NO]; return; }
                [owner completeImageSaveFromPath:source tab:originatingTab destination:destination asPDF:asPDF];
                [owner finishPendingImageSave:YES];
            });
        }
    });
}
- (void)completeImageSaveFromPath:(NSString*)source tab:(SPDFDocumentTab*)tab
                    destination:(NSString*)destination asPDF:(BOOL)asPDF {
    // Preserve overwrite history before opening queues a generic user-open capture.
    [self collectionDidSavePath:destination];
    if (SPDFPathIsUnsavedPastedImage(source)) {
        if ([_tabs containsObject:tab] && [tab.path isEqualToString:source]) {
            BOOL active = [self selectedTab] == tab;
            if (active) [self rememberActiveTabState];
            tab.path = destination; tab.title = destination.lastPathComponent.stringByDeletingPathExtension;
            tab.readOnly = NO; tab.workingPath = nil; tab.missingFile = NO; tab.missingMessage = @"";
            tab.collectionHistoryDocumentID = nil; tab.collectionVersionLabel = nil;
            tab.copiedSourceFileSize = 0; tab.copiedSourceModificationDate = nil;
            // Force the ordinary load path to open the new file after cancelling
            // its render work; it safely releases the old cached document there.
            tab.cachedModificationDate = nil; tab.cachedFileSize = 0;
            if (active) [self loadSelectedTab];
            else [self discardCachedRuntimeForTab:tab];
            [self updateTabStrip];
            [self saveDocumentStateForTab:tab];
            [self savePersistentState];
        }
        // A finished background save must not reopen a tab the reader closed
        // or steal focus from the document they selected while it was saving.
        [self rememberRecentlyOpenedPath:destination];
    } else [self openPath:destination];
    _statusLabel.stringValue = asPDF ? @"PDF copy saved." : @"Image copy saved.";
}
@end
#pragma clang diagnostic pop

