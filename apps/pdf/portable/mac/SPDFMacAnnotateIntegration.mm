// Annotate in the reader (SPDFMacAnnotateIntegration.h): turning it on for every document, File > New Canvas and the
// canvas tabs, opening .szpaint files, text documents asked to become a PDF first, and the reader's hooks (switch,
// close, quit). Saving, the zoom and the View toggles are in SPDFMacAnnotateIntegrationFiles.mm.
//
// Launch: every hook here starts with a check that costs nothing when no Annotate session exists (an associated
// object lookup or a path's extension), and no session, file or font is touched before Annotate is used.
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacAnnotateCanvasView.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacAnnotateImageIO.h"
#import "SPDFMacAnnotateIntegrationPrivate.h"
#import "SPDFMacAnnotateOperations.h"
#import "SPDFMacAnnotateSessionPrivate.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillIntegration.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownPrinting.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacModels.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "spdf_document_export.h"
#import <objc/runtime.h>

NSString* const SPDFAnnotateTitle = @"Annotate";
NSString* const SPDFAnnotateFormGroupTitle = @"Fill & Sign";
NSString* const SPDFAnnotateNewCanvasTitle = @"New Canvas…";
NSString* const SPDFAnnotateNewCanvasFromClipboardTitle = @"New Canvas from Clipboard";
NSString* const SPDFAnnotateUntitledCanvasTitle = @"Untitled canvas";
NSString* const SPDFAnnotateSaveAsPDFQuestion = @"To annotate this document, save it as a PDF.";
NSString* const SPDFAnnotateSaveAsPDFButton = @"Save as PDF…";
NSString* const SPDFAnnotatePageLockedText = @"The page itself can't be changed.";
NSString* const SPDFAnnotateNeedsPDFText = @"Save this document as a PDF to annotate it.";
NSString* const SPDFAnnotateCopyNoteText = @"Annotate saves a copy of this picture as PNG.";
NSString* const SPDFAnnotateWritableCopyNote =
    @"You're annotating a copy, because the original can't be changed. Choose File > Save As... to put it where you "
    @"want.";
NSString* const SPDFAnnotateChangedCopyNote =
    @"You're annotating a copy, because another app changed the original while you were annotating it. Choose "
    @"File > Save As... to put it where you want.";
NSString* const SPDFAnnotateGrowCanvasQuestion = @"Make the canvas bigger to fit?";
NSString* const SPDFAnnotateRemoveEverythingTitle = @"Remove Everything Added with Annotate";
NSString* const SPDFAnnotateProjectFormatTitle = @"Shenzhen Paint project";

static char kSPDFAnnotateClosingKey;

static NSString* BackingFolder(void) {
    return SPDFAnnotateTabsFolder();
}

// Writes the flattened canvas as a backing PNG and, for a project, the record of which .szpaint it shows.
static BOOL WriteBacking(spdf_paint_doc* doc, NSString* backing, NSString* project, double ppi, NSError** error) {
    spdf_bitmap bitmap = {0, 0, 0, NULL};
    char err[256] = {0};
    if (spdf_paint_flatten(doc, 0, &bitmap, err, sizeof(err)) != SPDF_PAINT_OK) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:4
                                            userInfo:@{NSLocalizedDescriptionKey: err[0] ? @(err) : @"The canvas couldn't be drawn."}];
        return NO;
    }
    NSData* png = SPDFAnnotateEncodePicture(&bitmap, @"png", SPDFAnnotateResolutionProperties(nil, ppi), 0, error);
    spdf_free_bitmap(&bitmap);
    if (!png) return NO;
    spdf_mac_support_directory();
    [NSFileManager.defaultManager createDirectoryAtPath:BackingFolder() withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSDictionary* info = project ? @{@"project": project} : @{@"kind": @"canvas"};
    NSData* json = [NSJSONSerialization dataWithJSONObject:info options:0 error:NULL];
    return SPDFAnnotateWriteFileAtomically(json, [backing.stringByDeletingPathExtension stringByAppendingPathExtension:@"json"],
                                           error) &&
           SPDFAnnotateWriteFileAtomically(png, backing, error);
}

NSString* SPDFAnnotateRecentPath(NSString* path) {
    if (!SPDFAnnotateIsBackingPath(path)) return path;
    return SPDFAnnotateProjectForBackingPath(path);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation ShenzhenMacDelegate (SPDFMacAnnotate)

#pragma mark - The mode

- (SPDFMacFillController*)annotateController {
    return [self fillController];
}

- (BOOL)annotateAvailable {
    return !_presentationMode && ([self isMarkdownActive] || (_doc && _path.length));
}

- (BOOL)annotateShowing {
    return [[self existingFillController] isShowing];
}

- (SPDFAnnotateDocumentKind)annotateActiveDocumentKind {
    if ([self isMarkdownActive]) return SPDFAnnotateDocumentText;
    return _doc ? SPDFAnnotateKindForTab([self selectedTab]) : SPDFAnnotateDocumentNone;
}

- (SPDFMacAnnotateSession*)annotateActiveSession {
    return [SPDFMacAnnotateSession existingSessionForTab:[self selectedTab]];
}

// Fill & Sign's -toggleFillAndSign: asks this first: every document but a PDF is Annotate's own (one line there).
- (BOOL)annotateToggleIfNotPDF {
    SPDFAnnotateDocumentKind kind = [self annotateActiveDocumentKind];
    if (kind == SPDFAnnotateDocumentPDF || kind == SPDFAnnotateDocumentNone) return NO;
    [self toggleAnnotate:nil];
    return YES;
}

- (void)toggleAnnotate:(id)sender {
    if (![self annotateAvailable]) {
        NSBeep();
        return;
    }
    SPDFAnnotateDocumentKind kind = [self annotateActiveDocumentKind];
    if (kind == SPDFAnnotateDocumentPDF) {
        [self toggleFillAndSign:sender];  // Fill & Sign's own path: forms, signed and certified PDFs, the copy
        return;
    }
    if (kind == SPDFAnnotateDocumentText) {
        SPDFAnnotateAskToSaveAsPDF(_window, ^(BOOL save) {
            if (save) [self annotateSaveTextDocumentAsPDF:nil completion:^(SPDFDocumentTab* tab, NSError* error) {
                (void)tab;
                if (error) [self showError:@"Couldn't save as PDF" detail:error.localizedDescription];
            }];
        });
        return;
    }
    SPDFMacFillController* controller = [self annotateController];
    if ([controller isShowing]) {
        [controller setOn:NO];  // Done: the picture is written into its file
        return;
    }
    [self annotateTurnOnActiveTab];
}

- (BOOL)annotateTurnOnActiveTab {
    SPDFMacFillController* controller = [self annotateController];
    SPDFMacAnnotateSession* session = [controller annotateSessionForTab:nil create:YES];
    // The picture changed elsewhere (rotated, edited in another app) since Annotate last had it: read it again.
    if (session.loaded && !session.dirty && [session fileChangedElsewhere]) {
        [SPDFMacAnnotateSession discardSessionForTab:session.tab];
        session = [controller annotateSessionForTab:nil create:YES];
    }
    NSError* error = nil;
    if (!session || ![session loadIfNeeded:&error]) {
        [self showError:@"Annotate can't open this picture" detail:error.localizedDescription ?: @""];
        return NO;
    }
    [controller session].dismissed = NO;
    [controller setOn:YES];
    [self annotateRefit];  // the palette and status bar now take room: a fitted picture fits below and above them
    return YES;
}

#pragma mark - Canvas tabs

- (void)newCanvas:(id)sender {
    (void)sender;
    [_window makeKeyAndOrderFront:nil];  // the sheet is the window's, whatever had the keyboard before
    __weak ShenzhenMacDelegate* weakSelf = self;
    SPDFAnnotateShowNewCanvasSheet(_window, ^(NSInteger width, NSInteger height, double ppi) {
      [weakSelf annotateNewCanvasWidth:width height:height ppi:ppi background:0 front:YES];
    });
}

- (BOOL)annotateClipboardHasPicture {
    return SPDFAnnotatePasteboardHasPicture(NSPasteboard.generalPasteboard);
}

// A canvas the size of the picture on the clipboard, at its resolution, the picture as its Background (the document
// under the drawing, as an opened picture is); the tool chosen stays.
- (void)newCanvasFromClipboard:(id)sender {
    (void)sender;
    SPDFAnnotatePicture* picture = SPDFAnnotatePictureFromPasteboard(NSPasteboard.generalPasteboard);
    if (!picture) {
        [self showError:@"Couldn't make a canvas from the clipboard" detail:@"Copy a picture first."];
        return;
    }
    spdf_paint_pixels pixels = picture.pixels;
    char err[256] = {0};
    spdf_paint_doc* doc = spdf_paint_open_picture(&pixels, picture.dpi, YES, err, sizeof(err));
    if (!doc) {
        [self showError:@"Couldn't make a canvas from the clipboard" detail:err[0] ? @(err) : @""];
        return;
    }
    [self annotateOpenNewCanvas:doc ppi:picture.dpi front:YES];
}

- (SPDFDocumentTab*)annotateNewCanvasWidth:(NSInteger)width height:(NSInteger)height ppi:(double)ppi
                                background:(spdf_paint_color)background front:(BOOL)front {
    char err[256] = {0};
    spdf_paint_doc* doc = spdf_paint_new_canvas((int)MAX(1, MIN(SPDF_PAINT_MAX_SIDE, width)),
                                                (int)MAX(1, MIN(SPDF_PAINT_MAX_SIDE, height)), background, err,
                                                sizeof(err));
    if (!doc) {
        [self showError:@"Couldn't make a new canvas" detail:err[0] ? @(err) : @""];
        return nil;
    }
    return [self annotateOpenNewCanvas:doc ppi:ppi front:front];
}

// Writes the new canvas (closed here) as its tab's picture and opens that tab with Annotate on.
- (SPDFDocumentTab*)annotateOpenNewCanvas:(spdf_paint_doc*)doc ppi:(double)ppi front:(BOOL)front {
    NSString* backing = [BackingFolder() stringByAppendingPathComponent:
                                             [NSString stringWithFormat:@"%@ %@.png", SPDFAnnotateUntitledCanvasTitle,
                                                                        NSUUID.UUID.UUIDString]];
    NSError* error = nil;
    BOOL written = WriteBacking(doc, backing, nil, ppi > 0 ? ppi : 72, &error);
    spdf_paint_close(doc);
    if (!written) {
        [self showError:@"Couldn't make a new canvas" detail:error.localizedDescription ?: @""];
        return nil;
    }
    [self openPath:backing];
    NSInteger index = [self indexOfTabForPath:backing];
    SPDFDocumentTab* tab = index >= 0 ? _tabs[(NSUInteger)index] : nil;
    if (!tab) return nil;
    tab.displayName = SPDFAnnotateUntitledCanvasTitle;
    [self updateTabStrip];
    if (front) [_window makeKeyAndOrderFront:nil];
    if ([self selectedTab] == tab && _doc) [self annotateTurnOnActiveTab];
    return tab;
}

- (void)annotateRestoreCanvasTab:(SPDFDocumentTab*)tab {
    if (!tab || ![self selectedTab] || [self selectedTab] != tab || !_doc) return;
    if (!spdf_tab_display_name(tab)) {
        NSString* project = SPDFAnnotateProjectForBackingPath(tab.path);
        tab.displayName = project ? project.lastPathComponent : SPDFAnnotateUntitledCanvasTitle;
        [self updateTabStrip];
    }
    SPDFMacFillController* controller = [self annotateController];
    if (![controller isShowing] && ![controller session].dismissed) [self annotateTurnOnActiveTab];
}

// After first paint of a document (Fill & Sign's settle hook): a canvas or project tab comes back with Annotate on.
- (void)annotateDocumentDidSettle {
    if (SPDFAnnotateIsBackingPath(_path)) [self annotateRestoreCanvasTab:[self selectedTab]];
}

#pragma mark - .szpaint

// -openPaths:'s hook: a .szpaint opens as the picture its tab shows, kept in <state>/Annotate/Tabs (made now).
- (NSArray<NSString*>*)annotateReaderPathsForPaths:(NSArray<NSString*>*)paths {
    BOOL any = NO;
    for (NSString* path in paths)
        if ([path isKindOfClass:NSString.class] && [path.pathExtension.lowercaseString isEqualToString:@"szpaint"]) any = YES;
    if (!any) return paths;
    NSMutableArray* mapped = [NSMutableArray array];
    for (NSString* path in paths) {
        if (![path isKindOfClass:NSString.class] || ![path.pathExtension.lowercaseString isEqualToString:@"szpaint"]) {
            [mapped addObject:path];
            continue;
        }
        NSString* backing = [self annotateBackingForProject:path];
        if (backing) [mapped addObject:backing];
    }
    return mapped;
}

- (NSString*)annotateBackingForProject:(NSString*)project {
    for (SPDFDocumentTab* tab in _tabs)  // already open: its tab is shown as it is, unsaved changes and all
        if (SPDFAnnotateIsBackingPath(tab.path) &&
            [SPDFAnnotateProjectForBackingPath(tab.path).stringByStandardizingPath isEqual:project.stringByStandardizingPath])
            return tab.path;
    char err[512] = {0};
    spdf_paint_doc* doc = spdf_paint_read_project(project.stringByStandardizingPath.fileSystemRepresentation, err,
                                                  sizeof(err));
    if (!doc) {
        [self showError:@"Couldn't open this Shenzhen Paint project" detail:err[0] ? @(err) : @""];
        return nil;
    }
    NSString* name = [[SPDFMacAnnotateSession sidecarPathForPath:project].lastPathComponent.stringByDeletingPathExtension
        stringByAppendingPathExtension:@"png"];
    NSString* backing = [BackingFolder() stringByAppendingPathComponent:name];
    NSError* error = nil;
    BOOL written = WriteBacking(doc, backing, project.stringByStandardizingPath, spdf_paint_dpi(doc), &error);
    spdf_paint_close(doc);
    if (!written) {
        [self showError:@"Couldn't open this Shenzhen Paint project" detail:error.localizedDescription ?: @""];
        return nil;
    }
    return backing;
}

- (BOOL)annotateOpenProjectAtPath:(NSString*)path {
    if (![path.pathExtension.lowercaseString isEqualToString:@"szpaint"]) return NO;
    NSString* backing = [self annotateBackingForProject:path];
    if (!backing) return NO;
    [self openPath:backing];
    return YES;
}

#pragma mark - Text documents

- (void)annotateSaveTextDocumentAsPDF:(NSString*)path
                           completion:(void (^)(SPDFDocumentTab*, NSError*))completion {
    void (^fail)(NSString*) = ^(NSString* message) {
        if (completion)
            completion(nil, message ? [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:5
                                                      userInfo:@{NSLocalizedDescriptionKey: message}] : nil);
    };
    if ([self annotateActiveDocumentKind] != SPDFAnnotateDocumentText) {
        fail(@"Only text documents are saved as a PDF to annotate them.");
        return;
    }
    NSString* source = [_path copy];
    NSString* destination = [path stringByExpandingTildeInPath];
    if (!destination.length) {
        NSSavePanel* panel = [NSSavePanel savePanel];
        panel.title = SPDFAnnotateSaveAsPDFButton;
        panel.canCreateDirectories = YES;
        panel.allowedContentTypes = @[UTTypePDF];
        panel.directoryURL = [NSURL fileURLWithPath:source.stringByDeletingLastPathComponent];
        panel.nameFieldStringValue = [source.lastPathComponent.stringByDeletingPathExtension
            stringByAppendingPathExtension:@"pdf"];
        if ([panel runModal] != NSModalResponseOK) {
            fail(nil);
            return;
        }
        destination = panel.URL.path;
    }
    if ([destination.stringByStandardizingPath isEqual:source.stringByStandardizingPath]) {
        fail(@"Choose another name: the PDF can't replace the document itself.");
        return;
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:destination] &&
        ![self collectionProtectPath:destination operation:@"saving as PDF"]) {
        fail(nil);
        return;
    }
    NSError* error = nil;
    BOOL ok = NO;
    if ([self isMarkdownActive]) {
        // What printing makes, and what `szpdf export-pdf` writes (SPDFMacMarkdownPrintAdapter).
        SPDFMacMarkdownSession* session = [self activeMarkdownSession];
        ok = session.exportPaginationPlan && session.exportAttributedString &&
             [SPDFMacMarkdownPrintAdapter writePaginationPlan:session.exportPaginationPlan
                                             attributedString:session.exportAttributedString
                                                        toURL:[NSURL fileURLWithPath:destination] error:&error];
    } else if (_doc) {
        char err[512] = {0};
        ok = spdf_document_export_pdf(_doc, destination.fileSystemRepresentation, -1, err, sizeof(err)) == 1;
        if (!ok && err[0]) error = [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:5
                                                   userInfo:@{NSLocalizedDescriptionKey: @(err)}];
    }
    if (!ok) {
        fail(error.localizedDescription ?: @"The PDF couldn't be written.");
        return;
    }
    [self collectionDidSavePath:destination];
    [self openPath:destination];
    NSInteger index = [self indexOfTabForPath:destination];
    SPDFDocumentTab* tab = index >= 0 ? _tabs[(NSUInteger)index] : nil;
    // Annotate on for the new PDF, as soon as it is the document in front.
    if (tab && [self selectedTab] == tab && _doc) {
        SPDFMacFillController* controller = [self annotateController];
        [controller session].dismissed = NO;
        if (![controller isShowing]) [self toggleFillAndSign:nil];
    }
    if (completion) completion(tab, tab ? nil : [NSError errorWithDomain:@"ShenzhenPDF.Annotate" code:5
                                                                userInfo:@{NSLocalizedDescriptionKey: @"The PDF was saved but couldn't be opened."}]);
}

#pragma mark - The reader's hooks

- (void)annotateFlushEdits {
    SPDFMacFillController* controller = [self existingFillController];
    SPDFMacAnnotateCanvasView* view = controller.annotateCanvasView;
    if (view.session) [view commitTextEditor];
}

- (void)annotateActiveDocumentChanged {
    SPDFMacFillController* controller = [self existingFillController];
    SPDFDocumentTab* active = [self selectedTab];
    // A picture left for another document is written into its file now (in the background).
    for (SPDFDocumentTab* tab in _tabs) {
        if (tab == active) continue;
        SPDFMacAnnotateSession* session = [SPDFMacAnnotateSession existingSessionForTab:tab];
        if (session.loaded && session.dirty && session.writesInPlace && !session.neverSaved && !session.pendingWrites)
            [session saveWithCompletion:nil];
        if (controller.annotateCanvasView.session == session && session) [controller.annotateCanvasView releaseHeldFrame];
    }
}

- (BOOL)annotateTabShouldClose:(SPDFDocumentTab*)tab {
    if (!tab || [objc_getAssociatedObject(tab, &kSPDFAnnotateClosingKey) boolValue]) return YES;
    SPDFMacAnnotateSession* session = [SPDFMacAnnotateSession existingSessionForTab:tab];
    BOOL neverSaved = SPDFAnnotateIsBackingPath(tab.path) && !SPDFAnnotateProjectForBackingPath(tab.path);
    if (neverSaved) {
        if (!session) session = [SPDFMacAnnotateSession sessionForTab:tab kind:SPDFAnnotateDocumentCanvas path:tab.path];
        session.host = self;
        NSString* name = spdf_tab_display_name(tab) ?: SPDFAnnotateUntitledCanvasTitle;
        __weak ShenzhenMacDelegate* weakSelf = self;
        SPDFAnnotateAskToSaveCanvas(_window, name, NO, ^(NSModalResponse choice) {
            ShenzhenMacDelegate* me = weakSelf;
            if (!me || choice == NSAlertThirdButtonReturn) return;
            if (choice == NSAlertSecondButtonReturn) {
                [session discardNeverSavedCanvas];
                [me annotateCloseTabNow:tab];
                return;
            }
            [me annotateAskWhereToSaveSession:session completion:^(BOOL saved) {
                if (saved) [weakSelf annotateCloseTabNow:tab];
            }];
        });
        return NO;
    }
    if (session.loaded && session.kind == SPDFAnnotateDocumentPicture && !session.writesInPlace && session.dirty) {
        // A WebP, RAW or animation drawn on: its changes can only go into a PNG copy, so closing asks, as a canvas does.
        __weak ShenzhenMacDelegate* weakSelf = self;
        SPDFAnnotateAskToSaveCanvas(_window, tab.title ?: tab.path.lastPathComponent, YES, ^(NSModalResponse choice) {
            ShenzhenMacDelegate* me = weakSelf;
            if (!me || choice == NSAlertThirdButtonReturn) return;
            if (choice == NSAlertSecondButtonReturn) {
                [session discardKeptChanges];
                [me annotateCloseTabNow:tab];
                return;
            }
            [me annotateAskWhereToSaveSession:session completion:^(BOOL saved) {
                if (saved) [weakSelf annotateCloseTabNow:tab];
            }];
        });
        return NO;
    }
    if (session.loaded) {
        NSError* error = nil;
        if (![session flushForClose:NO error:&error] && error.code != NSUserCancelledError)
            [self showError:@"Couldn't save the picture" detail:error.localizedDescription ?: @""];
    }
    // Written: the picture's layers and its undo history let go of their memory with the tab (a closed tab stays
    // listed for Reopen Last Closed, which reads the file again).
    if (session && session.kind != SPDFAnnotateDocumentPDF) [SPDFMacAnnotateSession discardSessionForTab:tab];
    return YES;
}

- (void)annotateCloseTabNow:(SPDFDocumentTab*)tab {
    NSInteger index = [_tabs indexOfObjectIdenticalTo:tab];
    if (index == NSNotFound) return;
    objc_setAssociatedObject(tab, &kSPDFAnnotateClosingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self closeTabAtIndex:index preferMostRecentActive:NO];
    [SPDFMacAnnotateSession discardSessionForTab:tab];
}

- (void)annotateFlushForQuit {
    for (SPDFDocumentTab* tab in _tabs) {
        SPDFMacAnnotateSession* session = [SPDFMacAnnotateSession existingSessionForTab:tab];
        if (!session.loaded) continue;
        [[self existingFillController].annotateCanvasView commitTextEditor];
        [session flushForClose:YES error:NULL];  // quitting never asks
    }
}

@end
#pragma clang diagnostic pop

// The reader's -closeTabAtIndex: (moved here from ShenzhenPDFMac.mm, which may not grow): closing any tab asks
// Annotate first, so a never-saved canvas can ask Save / Don't Save / Cancel.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation ShenzhenMacDelegate (SPDFMacAnnotateClose)
- (void)closeTabAtIndex:(NSInteger)index {
    [self closeTabAtIndex:index preferMostRecentActive:NO];
}
@end
#pragma clang diagnostic pop
