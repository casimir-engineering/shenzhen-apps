// Annotate's files in the reader (SPDFMacAnnotateIntegration.h): Cmd-S, Save As with its formats, Set as Desktop
// Picture, the session host (Collection before and after a write, the tab following the file), the zoom and the
// View toggles.
#import "SPDFMacAnnotateLayersPanel.h"
#import "SPDFMacAnnotateIntegrationPrivate.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacModels.h"

// The Save panel's format popup: the panel's file type and name follow the choice.
@interface SPDFAnnotateFormatPicker : NSObject
@property(nonatomic, weak) NSSavePanel* panel;
@property(nonatomic, strong) NSPopUpButton* popup;
- (void)formatChanged:(id)sender;
@end

@implementation SPDFAnnotateFormatPicker
- (NSDictionary*)row {
    return self.popup.selectedItem.representedObject;
}
- (void)formatChanged:(id)sender {
    (void)sender;
    NSDictionary* row = [self row];
    UTType* type = [UTType typeWithFilenameExtension:row[@"extension"]];
    self.panel.allowedContentTypes = type ? @[type] : @[];
    self.panel.nameFieldStringValue = [self.panel.nameFieldStringValue.stringByDeletingPathExtension
        stringByAppendingPathExtension:row[@"extension"]];
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ShenzhenMacDelegate (SPDFMacAnnotateFiles)

#pragma mark - Saving

- (BOOL)annotateHandlesSave:(id)sender {
    SPDFMacAnnotateSession* session = [self annotateActiveSession];
    if (!session.loaded || session.kind == SPDFAnnotateDocumentPDF) return NO;
    [self annotateSaveDocumentAs:sender];  // File > Save As... (Shift-Cmd-S); Save (Cmd-S) is its own item
    return YES;
}

- (void)annotateSaveDocument:(id)sender {
    SPDFMacAnnotateSession* session = [self annotateActiveSession];
    if (!session.loaded || session.kind == SPDFAnnotateDocumentPDF) {
        [self saveDocumentAs:sender];
        return;
    }
    [[self existingFillController].annotateCanvasView commitTextEditor];
    // The first Cmd-S of a canvas, and a picture that can't take its changes (WebP, RAW, an animation), ask where.
    if (session.neverSaved || !session.writesInPlace) {
        [self annotateAskWhereToSaveSession:session completion:nil];
        return;
    }
    [session saveWithCompletion:^(NSError* error) {
        if (error && error.code != NSUserCancelledError) [self showError:@"Couldn't save the picture" detail:error.localizedDescription];
    }];
}

- (void)annotateSaveDocumentAs:(id)sender {
    SPDFMacAnnotateSession* session = [self annotateActiveSession];
    if (!session.loaded || session.kind == SPDFAnnotateDocumentPDF) {
        [self saveDocumentAs:sender];
        return;
    }
    [self annotateAskWhereToSaveSession:session completion:nil];
}

- (void)annotateAskWhereToSaveSession:(SPDFMacAnnotateSession*)session completion:(void (^)(BOOL))completion {
    [[self existingFillController].annotateCanvasView commitTextEditor];
    if (!session.loaded && ![session loadIfNeeded:NULL]) {
        if (completion) completion(NO);
        return;
    }
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.canCreateDirectories = YES;
    panel.allowsOtherFileTypes = NO;
    BOOL asPNG = session.neverSaved || !session.writesInPlace;
    NSString* format = asPNG ? @"png" : session.projectPath ? @"szpaint" : (SPDFAnnotateFormatForPath(session.path) ?: @"png");
    NSString* original = session.projectPath ?: session.path;
    NSString* name = session.neverSaved ? @"Untitled" : original.lastPathComponent.stringByDeletingPathExtension;
    panel.nameFieldStringValue = name;
    NSString* folder = session.neverSaved ? nil : original.stringByDeletingLastPathComponent;
    if (!folder.length || SPDFAnnotateIsBackingPath(original))
        folder = [NSFileManager.defaultManager URLsForDirectory:NSPicturesDirectory inDomains:NSUserDomainMask].firstObject.path;
    if (folder.length) panel.directoryURL = [NSURL fileURLWithPath:folder];
    SPDFAnnotateFormatPicker* picker = [SPDFAnnotateFormatPicker new];
    picker.panel = panel;
    picker.popup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 26) pullsDown:NO];
    for (NSDictionary* row in SPDFAnnotateSaveFormats()) {
        [picker.popup addItemWithTitle:row[@"title"]];
        picker.popup.lastItem.representedObject = row;
        if ([row[@"format"] isEqual:format]) [picker.popup selectItem:picker.popup.lastItem];
    }
    picker.popup.target = picker;
    picker.popup.action = @selector(formatChanged:);
    picker.popup.accessibilityLabel = @"File format";
    NSTextField* label = [NSTextField labelWithString:@"Format:"];
    NSStackView* accessory = [NSStackView stackViewWithViews:@[label, picker.popup]];
    accessory.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    accessory.spacing = 8;
    accessory.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
    accessory.frame = NSMakeRect(0, 0, MAX(300, accessory.fittingSize.width), MAX(42, accessory.fittingSize.height));
    panel.accessoryView = accessory;
    [picker formatChanged:nil];
    __weak ShenzhenMacDelegate* weakSelf = self;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
        (void)picker;  // kept alive by the block while the panel is up
        if (response != NSModalResponseOK) {
            if (completion) completion(NO);
            return;
        }
        NSString* destination = panel.URL.path;
        if (!destination.pathExtension.length)  // a name typed without one still gets the chosen format's
            destination = [destination stringByAppendingPathExtension:[picker row][@"extension"]];
        [session saveAsPath:destination format:[picker row][@"format"] quality:0.92 completion:^(NSError* error) {
            if (error && error.code != NSUserCancelledError) [weakSelf showError:@"Couldn't save the picture" detail:error.localizedDescription];
            if (completion) completion(error == nil);
        }];
    }];
}

- (void)setDesktopPicture:(id)sender {
    (void)sender;
    SPDFMacAnnotateSession* session = [self annotateActiveSession];
    NSString* path = session ? (session.neverSaved ? nil : session.path) : _path;
    if (session.projectPath || !path.length || SPDFAnnotateDocumentKindForPath(path) != SPDFAnnotateDocumentPicture) {
        [self showError:@"Save the picture first" detail:@"The desktop picture is made from a saved picture file."];
        return;
    }
    void (^apply)(void) = ^{
        NSError* error = nil;
        for (NSScreen* screen in NSScreen.screens)
            if (![NSWorkspace.sharedWorkspace setDesktopImageURL:[NSURL fileURLWithPath:path] forScreen:screen
                                                         options:@{} error:&error])
                break;
        if (error) [self showError:@"Couldn't set the desktop picture" detail:error.localizedDescription];
    };
    if (session.dirty && session.writesInPlace) [session saveWithCompletion:^(NSError* error) { if (!error) apply(); }];
    else apply();
}

#pragma mark - The session's host

- (BOOL)annotateSessionProtectPath:(NSString*)path {
    if (SPDFAnnotateIsBackingPath(path)) return YES;
    return [self collectionProtectPath:path operation:@"annotating the picture"];
}

- (void)annotateSession:(SPDFMacAnnotateSession*)session didWritePath:(NSString*)path {
    if (!SPDFAnnotateIsBackingPath(path)) [self collectionDidSavePath:path];
    SPDFDocumentTab* tab = session.tab;
    if (!tab || ![tab.path isEqual:path]) return;
    int width = 0, height = 0;
    spdf_paint_size(session.canvas, &width, &height);
    BOOL resized = width != (int)session.readerPixelSize.width || height != (int)session.readerPixelSize.height;
    if ([self selectedTab] != tab) {
        [self discardCachedRuntimeForTab:tab];  // read again when it comes to the front
        session.readerPixelSize = NSMakeSize(width, height);
        session.pageStale = NO;
        return;
    }
    if ([self annotateShowing] && !resized) {
        // The canvas covers the page: the reader just learns the file is its own write, not someone else's.
        [self refreshActiveTabCachedFileAttributesAfterSelfSave];
        session.pageStale = YES;
        return;
    }
    [self annotateReloadTab:tab session:session];
}

- (void)annotateReloadTab:(SPDFDocumentTab*)tab session:(SPDFMacAnnotateSession*)session {
    int width = 0, height = 0;
    spdf_paint_size(session.canvas, &width, &height);
    BOOL resized = width != (int)session.readerPixelSize.width || height != (int)session.readerPixelSize.height;
    [self rememberActiveTabState];
    if (resized) {
        tab.hasScrollOrigin = NO;
        tab.scrollOrigin = NSZeroPoint;
    }
    tab.cachedModificationDate = nil;
    tab.cachedFileSize = 0;
    [self discardCachedRuntimeForTab:tab];
    session.readerPixelSize = NSMakeSize(width, height);
    session.pageStale = NO;
    [self loadSelectedTab];
}

- (void)annotateSession:(SPDFMacAnnotateSession*)session didSaveAsPath:(NSString*)path {
    SPDFDocumentTab* tab = session.tab;
    if (!tab || ![_tabs containsObject:tab]) return;
    BOOL active = [self selectedTab] == tab;
    if (active) [self rememberActiveTabState];
    tab.path = path;
    NSString* project = SPDFAnnotateProjectForBackingPath(path);
    tab.displayName = project ? project.lastPathComponent : nil;
    tab.title = path.lastPathComponent.stringByDeletingPathExtension;
    tab.readOnly = NO;
    tab.workingPath = nil;
    tab.missingFile = NO;
    tab.missingMessage = @"";
    tab.collectionHistoryDocumentID = nil;
    tab.collectionVersionLabel = nil;
    tab.cachedModificationDate = nil;
    tab.cachedFileSize = 0;
    int width = 0, height = 0;
    spdf_paint_size(session.canvas, &width, &height);
    session.readerPixelSize = NSMakeSize(width, height);
    session.pageStale = NO;
    if (active) [self loadSelectedTab];
    else [self discardCachedRuntimeForTab:tab];
    [self updateTabStrip];
    [self saveDocumentStateForTab:tab];
    [self savePersistentState];
}

- (void)annotateShowWrittenPictureOfSession:(SPDFMacAnnotateSession*)session {
    SPDFMacAnnotateCanvasView* view = [self existingFillController].annotateCanvasView;
    if (session.tab == [self selectedTab] && session.pageStale && ![self annotateShowing])
        [self annotateReloadTab:session.tab session:session];
    // The new page picture renders right after the reload; until then the held canvas shows the same pixels.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [view releaseHeldFrame];
    });
}

#pragma mark - Zoom

- (void)annotateZoomTo:(id)level atCanvasPoint:(NSValue*)point {
    SPDFMacAnnotateCanvasView* view = [self existingFillController].annotateCanvasView;
    if ([level isEqual:@"fit"]) {
        [self fitPage:nil];
        return;
    }
    CGFloat target = [level isEqual:@"actual"] ? 1.0 : [level doubleValue];
    CGFloat current = view.session ? [view zoomLevel] : _zoom;
    if (target <= 0 || current <= 0) return;
    target = MAX(0.125, MIN(8.0, target));  // 12.5 %-800 % (§ 1 View)
    NSPoint windowPoint = [self visibleCenterWindowPoint];
    if (point && view.session) {
        NSInteger page = view.session.kind == SPDFAnnotateDocumentPDF ? MAX(0, view.session.currentPage) : -1;
        NSRect r = [view viewRectForCanvasRect:NSMakeRect(point.pointValue.x, point.pointValue.y, 0, 0) page:page];
        windowPoint = [view convertPoint:r.origin toView:nil];
    }
    [self zoomByFactor:target / current centeredAtWindowPoint:windowPoint];
}

#pragma mark - View toggles

- (void)annotateApplyViewSettings {
    SPDFMacFillController* controller = [self existingFillController];
    SPDFAnnotateSettings* settings = SPDFAnnotateSettings.shared;
    SPDFMacAnnotateCanvasView* view = controller.annotateCanvasView;
    view.showsRulers = settings.showsRulers;
    view.showsGridlines = settings.showsGridlines;
    view.needsDisplay = YES;
    if (controller) SPDFAnnotateUpdateStatusBar(controller, [self annotateShowing] ? [self annotateActiveSession] : nil);
}

// The Layers panel takes the minimap's place (§ 1): the minimap's slot shows, as wide as the panel, with the panel in
// it instead of the minimap; on Done the minimap comes back at its own width, as the person left it.
static char kSPDFAnnotateKeptMinimapWidthKey;
static const CGFloat kSPDFAnnotateLayersSlotWidth = 252;

- (void)annotateLayersPanelDidShow:(BOOL)shown {
    NSNumber* kept = objc_getAssociatedObject(self, &kSPDFAnnotateKeptMinimapWidthKey);
    if (shown && !kept) {
        objc_setAssociatedObject(self, &kSPDFAnnotateKeptMinimapWidthKey, @(_minimapWidth), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        _minimapWidth = kSPDFAnnotateLayersSlotWidth;
    } else if (!shown && kept) {
        _minimapWidth = kept.doubleValue;
        objc_setAssociatedObject(self, &kSPDFAnnotateKeptMinimapWidthKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self setMinimapActuallyVisible:shown ? YES : _minimapPreferredVisible];
    _minimapView.alphaValue = shown ? 0 : 1;  // the panel is what shows in the slot
    dispatch_async(dispatch_get_main_queue(), ^{ [self annotateRefit]; });  // once the panel has its size
}

- (NSView*)annotateLayersSlot {
    return objc_getAssociatedObject(self, &kSPDFAnnotateKeptMinimapWidthKey) ? _minimapView : nil;
}

- (CGFloat)persistedMinimapWidth {
    NSNumber* kept = objc_getAssociatedObject(self, &kSPDFAnnotateKeptMinimapWidthKey);
    return kept ? kept.doubleValue : _minimapWidth;
}

- (void)toggleAnnotateLayers:(id)sender {
    (void)sender;
    SPDFMacFillController* controller = [self existingFillController];
    if (controller) SPDFAnnotateToggleLayersPanel(controller);
}

- (void)toggleAnnotateStatusBar:(id)sender {
    (void)sender;
    SPDFAnnotateSettings.shared.showsStatusBar = !SPDFAnnotateSettings.shared.showsStatusBar;
    [self annotateApplyViewSettings];
}

- (void)toggleAnnotateRulers:(id)sender {
    (void)sender;
    SPDFAnnotateSettings.shared.showsRulers = !SPDFAnnotateSettings.shared.showsRulers;
    [self annotateApplyViewSettings];
}

- (void)toggleAnnotateGridlines:(id)sender {
    (void)sender;
    SPDFAnnotateSettings.shared.showsGridlines = !SPDFAnnotateSettings.shared.showsGridlines;
    [self annotateApplyViewSettings];
}

- (void)toggleAnnotateThumbnail:(id)sender {
    (void)sender;
    SPDFMacAnnotateCanvasView* view = [self existingFillController].annotateCanvasView;
    view.showsThumbnail = !view.showsThumbnail;
    view.needsDisplay = YES;
}

@end
#pragma clang diagnostic pop
