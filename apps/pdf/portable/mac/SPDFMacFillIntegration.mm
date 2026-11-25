#import "SPDFMacFillIntegration.h"

#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacEditedPageThumbnails.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacPageRendering.h"
#import "SPDFMacViewportRenderPriority.h"
#import "SPDFMacWorkspaceChrome.h"

#include "spdf_fill_ink.h"

#import <objc/runtime.h>

static char kSPDFFillControllerKey, kSPDFFillMenuTargetKey, kSPDFFillFormStampKey;

// Implemented by the coordinator and its other categories.
@interface ShenzhenMacDelegate (SPDFMacFillReader)
- (BOOL)isMarkdownActive;
- (NSString*)activeWorkingPath;
- (CGFloat)backingScale;
- (void)showError:(NSString*)message detail:(NSString*)detail;
- (spdf_document*)openSpdfDocumentAtPath:(NSString*)path
                              sourcePath:(NSString*)sourcePath
                                  status:(spdf_open_status*)status
                                   error:(char*)err
                             errorLength:(size_t)errLen;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)collectionDidSavePath:(NSString*)path;
- (BOOL)collectionProtectPath:(NSString*)path operation:(NSString*)operation;
- (BOOL)moveActivePDFToWritableCopyForOperation:(NSString*)operation;
- (BOOL)activePDFNeedsSaveAsBeforeModificationWithReason:(NSString**)reasonOut;
- (void)cacheActiveRenderedPagesForSelectedTab;
- (void)resizeDocumentView;
- (NSString*)pathForStateFile:(NSString*)name;
@end

@interface ShenzhenMacDelegate (SPDFMacFillHost) <SPDFMacFillHost>
@end

// The Edit and File menu items' target, so their validation stays here.
@interface SPDFFillMenuTarget : NSObject <NSMenuItemValidation>
@property(nonatomic, weak) ShenzhenMacDelegate* reader;
@end
@implementation SPDFFillMenuTarget
- (void)toggleFillAndSign:(id)sender { [self.reader toggleFillAndSign:sender]; }
- (void)saveFinalCopy:(id)sender { [self.reader saveFinalCopy:sender]; }
- (void)removeAllPenLinesAndArrows:(id)sender { [self.reader removeAllPenLinesAndArrows:sender]; }
- (void)removeEverythingAddedWithFillSign:(id)sender { [self.reader removeEverythingAddedWithFillSign:sender]; }
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    BOOL available = [self.reader fillSignAvailable];
    if (item.action == @selector(toggleFillAndSign:))
        item.state = [self.reader fillSignShowing] ? NSControlStateValueOn : NSControlStateValueOff;
    // Enabled only when there is something to remove.
    if (item.action == @selector(removeAllPenLinesAndArrows:))
        return available && [self.reader fillSignCanAddItems] && [self.reader fillSignHasAddedItemsDrawingsOnly:YES];
    if (item.action == @selector(removeEverythingAddedWithFillSign:))
        return available && ([self.reader fillSignHasFilledFields] ||
                             ([self.reader fillSignCanAddItems] && [self.reader fillSignHasAddedItemsDrawingsOnly:NO]));
    return available;
}
@end

void SPDFFillInstallMenuItems(NSMenu* editMenu, NSMenu* fileMenu, ShenzhenMacDelegate* reader) {
    SPDFFillMenuTarget* target = [SPDFFillMenuTarget new];
    target.reader = reader;
    objc_setAssociatedObject(reader, &kSPDFFillMenuTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* fill = [editMenu addItemWithTitle:@"Fill & Sign" action:@selector(toggleFillAndSign:) keyEquivalent:@"f"];
    fill.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    fill.target = target;
    [editMenu addItemWithTitle:@"Remove All Pen Lines and Arrows" action:@selector(removeAllPenLinesAndArrows:)
                 keyEquivalent:@""].target = target;
    [editMenu addItemWithTitle:@"Remove Everything Added with Fill & Sign"
                        action:@selector(removeEverythingAddedWithFillSign:) keyEquivalent:@""].target = target;
    NSInteger saveAs = [fileMenu indexOfItemWithTarget:nil andAction:@selector(saveDocumentAs:)];
    NSMenuItem* finalCopy = [[NSMenuItem alloc] initWithTitle:@"Save Final Copy…" action:@selector(saveFinalCopy:)
                                                keyEquivalent:@""];
    finalCopy.target = target;
    [fileMenu insertItem:finalCopy atIndex:saveAs >= 0 ? saveAs + 1 : fileMenu.numberOfItems];
}

@implementation ShenzhenMacDelegate (SPDFMacFill)

- (SPDFMacFillController*)existingFillController {
    return objc_getAssociatedObject(self, &kSPDFFillControllerKey);
}

- (SPDFMacFillController*)fillController {
    SPDFMacFillController* controller = [self existingFillController];
    if (!controller) {
        controller = [[SPDFMacFillController alloc] initWithHost:self];
        objc_setAssociatedObject(self, &kSPDFFillControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return controller;
}

- (BOOL)fillSignAvailable {
    if (!_doc || _presentationMode || [self isMarkdownActive]) return NO;
    return [_path.pathExtension caseInsensitiveCompare:@"pdf"] == NSOrderedSame ||
           [self existingFillController].session.hasSummary;
}

- (BOOL)fillSignShowing {
    return [[self existingFillController] isShowing];
}

// The PDF takes added items (a fill-only PDF does not); unknown until its form was read, which happens on first use.
- (BOOL)fillSignCanAddItems {
    SPDFFillSession* session = [[self existingFillController] session];
    return !session.hasSummary || session.summary.can_add_items;
}

// Lines still waiting to be written count: the Remove commands write them first.
- (BOOL)fillSignHasAddedItemsDrawingsOnly:(BOOL)drawingsOnly {
    if (!_doc) return NO;
    SPDFMacFillController* controller = [self existingFillController];
    if (controller && [controller hasPendingStrokes]) return YES;
    char err[128];
    if (!drawingsOnly) return spdf_fill_pages_with_items(_doc, SPDF_FILL_NM_PREFIX, NULL, 0, err, sizeof(err)) > 0 ||
                              spdf_fill_pages_with_items(_doc, "spdf-annotate-", NULL, 0, err, sizeof(err)) > 0;
    return spdf_fill_pages_with_items(_doc, SPDF_FILL_PEN_NM_PREFIX, NULL, 0, err, sizeof(err)) > 0 ||
           spdf_fill_pages_with_items(_doc, SPDF_FILL_ARROW_NM_PREFIX, NULL, 0, err, sizeof(err)) > 0;
}

// A field of the PDF's own form holds something Fill & Sign put there (spdf_form_filled_count).
- (BOOL)fillSignHasFilledFields {
    char err[128];
    return _doc && spdf_form_filled_count(_doc, err, sizeof(err)) > 0;
}

- (NSString*)fillFormStampForTab:(SPDFDocumentTab*)tab {
    return [NSString stringWithFormat:@"%@|%llu|%.3f|%p", _path ?: @"", tab.cachedFileSize,
                                      tab.cachedModificationDate.timeIntervalSinceReferenceDate, (void*)_doc];
}

// Reads the form summary for the active tab when its file changed since the last read. Returns the session holding
// it, or nil for a PDF without a form when no session exists (nothing is created for those).
- (SPDFFillSession*)fillReadSummaryCreatingSession:(BOOL)create {
    SPDFDocumentTab* tab = [self selectedTab];
    if (!tab || !_doc || [self isMarkdownActive]) return nil;
    NSString* stamp = [self fillFormStampForTab:tab];
    SPDFMacFillController* controller = [self existingFillController];
    SPDFFillSession* session = controller ? [controller session] : nil;
    if ([objc_getAssociatedObject(tab, &kSPDFFillFormStampKey) isEqual:stamp] && !create) return session;
    if (session.hasSummary && [session.summaryStamp isEqual:stamp]) return session;
    spdf_form_summary summary;
    memset(&summary, 0, sizeof(summary));
    char err[256];
    BOOL read = spdf_form_summary_read(_doc, &summary, err, sizeof(err));
    objc_setAssociatedObject(tab, &kSPDFFillFormStampKey, stamp, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!read) return session;
    if (!session && (create || summary.kind == SPDF_FORM_FILLABLE)) session = [[self fillController] session];
    session.summary = summary;
    session.hasSummary = YES;
    session.summaryStamp = stamp;
    return session;
}

- (void)fillSignDocumentDidSettle {
    SPDFFillSession* session = [self fillReadSummaryCreatingSession:NO];
    if (session && session.isForm && !session.on && !session.dismissed && session.summary.signed_count == 0 &&
        session.summary.docmdp != 1)
        session.on = YES;  // a PDF with its own form opens ready to fill
    [[self existingFillController] activeDocumentChanged];
}

- (void)fillSignActiveDocumentChanged {
    [[self existingFillController] activeDocumentChanged];
}

- (void)fillSignFlushEdits {
    [[self existingFillController] flushPendingChanges];  // what is being typed, and lines drawn a moment ago
}

// Fill & Sign shows first, so what goes is seen going and Command-Z brings it back at once.
- (BOOL)fillShowForRemoval {
    if (![self fillSignAvailable]) return NO;
    if (![self fillSignShowing]) [self toggleFillAndSign:nil];
    return [self fillSignShowing];
}

- (void)removeAllPenLinesAndArrows:(id)sender {
    (void)sender;
    if ([self fillShowForRemoval]) [[self fillController] removeAllDrawings];
}

- (void)removeEverythingAddedWithFillSign:(id)sender {
    (void)sender;
    if ([self fillShowForRemoval]) [[self fillController] removeEverythingAdded];
}

- (void)fillSignChromeDidSync {
    SPDFMacFillController* controller = [self existingFillController];
    if (!controller.overlay) return;
    BOOL showing = [controller isShowing];
    if (controller.overlay.hidden == !showing && controller.palette.hidden == !showing) return;
    if (!showing) [controller endInteraction];
    controller.overlay.hidden = !showing;
    controller.palette.hidden = !showing;
    if (showing) [controller.overlay refresh];
}

- (void)toggleFillAndSign:(id)sender {
    (void)sender;
    if (![self fillSignAvailable]) {
        NSBeep();
        return;
    }
    SPDFMacFillController* controller = [self fillController];
    SPDFFillSession* session = [self fillReadSummaryCreatingSession:YES] ?: [controller session];
    if (session.on) {
        [controller setOn:NO];
        return;
    }
    if (session.hasSummary && session.summary.docmdp == 1) {
        [self showError:@"This PDF can't be filled in" detail:@"Whoever certified it locked it against any change."];
        return;
    }
    if (![self fillConfirmSignedPDF:session]) return;
    session.dismissed = NO;
    [controller setOn:YES];
}

- (BOOL)fillConfirmSignedPDF:(SPDFFillSession*)session {
    if (!session.hasSummary || session.summary.signed_count == 0 || session.signedNoticeAccepted) return YES;
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"This PDF was signed digitally";
    alert.informativeText = @"If you fill it in, anyone who checks that signature will see the document changed after it "
                            @"was signed.";
    [alert addButtonWithTitle:@"Fill In Anyway"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return NO;
    session.signedNoticeAccepted = YES;
    return YES;
}

- (void)saveFinalCopy:(id)sender {
    (void)sender;
    if (![self fillSignAvailable]) return;
    [self fillSignFlushEdits];
    NSString* source = [[self activeWorkingPath] copy];
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save Final Copy";
    panel.message = @"What you filled in becomes part of the pages, so it can no longer be changed.";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%@ (final).pdf",
                                                            _path.lastPathComponent.stringByDeletingPathExtension ?: @"Document"];
    panel.directoryURL = [NSURL fileURLWithPath:_path.stringByDeletingLastPathComponent];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse response) {
      if (response != NSModalResponseOK) return;
      NSString* destination = panel.URL.path;
      if ([destination.stringByStandardizingPath isEqual:source.stringByStandardizingPath]) {
          [self showError:@"Couldn't save the final copy" detail:@"Choose another name: the final copy can't replace the "
                                                                 @"document you are filling in."];
          return;
      }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char err[1024] = {0};
        BOOL ok = spdf_save_final_copy(source.fileSystemRepresentation, NULL, destination.fileSystemRepresentation, err,
                                       sizeof(err));
        NSString* detail = @(err);
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!ok) [self showError:@"Couldn't save the final copy" detail:detail];
        });
      });
    }];
}

@end

@implementation ShenzhenMacDelegate (SPDFMacFillHost)

- (spdf_document*)fillDocument { return _doc; }
- (NSString*)fillPath { return _path; }
- (NSString*)fillWorkingPath { return [self activeWorkingPath]; }
- (SPDFDocumentTab*)fillTab { return [self selectedTab]; }
- (NSScrollView*)fillScrollView { return _pageScrollView; }
- (NSView*)fillContainer { return _documentContainer; }
- (NSWindow*)fillWindow { return _window; }
- (BOOL)fillHidden { return !_doc || _presentationMode || [self isMarkdownActive]; }
- (CGFloat)fillZoom { return _zoom; }
- (NSString*)fillAuthor { return [self currentCommentAuthor]; }
- (BOOL)fillDarkPages { return _darkReadingTheme; }
- (void)fillShowError:(NSString*)title detail:(NSString*)detail { [self showError:title detail:detail]; }
- (void)fillStateDidChange { [self syncWorkspaceChrome]; }

- (BOOL)fillIsEditedCopy {
    NSString* copies = [[self pathForStateFile:@"Edited Copies"] stringByAppendingString:@"/"];
    return _path.length && [_path.stringByStandardizingPath hasPrefix:copies.stringByStandardizingPath];
}

- (BOOL)fillWillFillACopy {
    if (!_doc || !_path.length || [self isMarkdownActive]) return NO;
    return SPDFMacPathIsCollectionArchive(_path) || [self activePDFNeedsSaveAsBeforeModificationWithReason:NULL];
}

- (void)fillSetPageTopReserve:(CGFloat)reserve {
    if (!_pageView || fabs(_pageView.topReserve - reserve) < 0.5) return;
    NSClipView* clip = _pageScrollView.contentView;
    NSPoint origin = clip.bounds.origin;
    CGFloat delta = reserve - _pageView.topReserve;
    _pageView.topReserve = reserve;
    [self resizeDocumentView];
    // At the top of the document the first page moves down clear of the palette (or back up after it); further down,
    // what is on screen stays where it is.
    if (origin.y <= 0.5) return;
    origin.y = MAX(0.0, MIN(origin.y + delta, NSHeight(_pageView.bounds) - NSHeight(clip.bounds)));
    [clip scrollToPoint:origin];
    [_pageScrollView reflectScrolledClipView:clip];
}

- (spdf_document*)fillOpenReadDocumentAtPath:(NSString*)path error:(char*)err length:(size_t)len {
    return [self openSpdfDocumentAtPath:path sourcePath:_path status:NULL error:err errorLength:len];
}

- (BOOL)fillPrepareForChangeOfFieldsOnly:(BOOL)fieldsOnly {
    if (!_doc) return NO;
    SPDFFillSession* session = [self fillReadSummaryCreatingSession:YES];
    if (!session) return NO;
    spdf_form_summary summary = session.summary;
    if (summary.docmdp == 1) {
        [self showError:@"This PDF can't be filled in" detail:@"Whoever certified it locked it against any change."];
        return NO;
    }
    if (!fieldsOnly && (summary.docmdp == 2 || (!summary.can_add_items && summary.can_fill_fields))) {
        [self showError:@"This PDF can't take added text or marks" detail:@"This PDF only allows filling in its own fields."];
        return NO;
    }
    if (fieldsOnly ? !summary.can_fill_fields : !summary.can_add_items) {
        [self showError:@"This PDF can't be filled in"
                 detail:@"This PDF's owner doesn't allow filling it in. Open it with the owner password to continue."];
        return NO;
    }
    if (![self fillConfirmSignedPDF:session]) return NO;
    if (session.protectedForEdits && [session.protectedPath isEqual:_path]) return YES;
    // As -ensureActivePDFCanBeModifiedForOperation:, with Fill & Sign's own permission check above: a Collection
    // backup or a file that can't be written in place moves to a writable copy; otherwise Collection keeps the
    // version as it was before this edit.
    NSString* operation = @"filling in this document";
    BOOL ok;
    if (SPDFMacPathIsCollectionArchive(_path)) ok = [self moveActivePDFToWritableCopyForOperation:operation];
    else if (![self activePDFNeedsSaveAsBeforeModificationWithReason:NULL]) ok = [self collectionProtectPath:_path operation:operation];
    else ok = [self moveActivePDFToWritableCopyForOperation:operation];
    if (!ok || !_doc) return NO;
    // The writable copy is a new tab document: its session is the same tab's, carried over.
    SPDFFillSession* current = [[self fillController] session];
    current.protectedForEdits = YES;
    current.protectedPath = _path;
    if (current != session) {
        current.summary = session.summary;
        current.hasSummary = session.hasSummary;
        current.on = session.on;
        current.signedNoticeAccepted = session.signedNoticeAccepted;
    }
    return YES;
}

- (BOOL)fillSaveAndRedrawPages:(NSIndexSet*)pages {
    char err[1024] = {0};
    if (!spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err))) {
        [self showError:@"Couldn't save what you filled in" detail:@(err)];
        return NO;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    [self invalidateCursorRegionCache];
    // The changed pages are drawn again from the document in memory now, in this turn, so no frame shows the old
    // value; the sharper viewport tiles follow from the saved file.
    __block BOOL needsFullRender = NO;
    CGFloat scale = [self backingScale];
    NSInteger preferred = -1;
    NSArray<NSNumber*>* visible = [self visibleDocumentPageIndexesWithExtraRadius:0 preferredPage:&preferred];
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count) return;
      SPDFRenderedPage* old = self->_renderedPages[index];
      // A page not drawn yet and not in view renders from the saved file when shown.
      if (!old.image && !old.viewportImage && ![visible containsObject:@(index)]) return;
      if (![self fullPageRenderAllowedForPage:old zoom:self->_zoom displayScale:scale]) {
          needsFullRender = YES;
          return;
      }
      char renderErr[512];
      SPDFRenderedPage* page = [self renderedPageAtIndex:(NSInteger)index document:self->_doc zoom:self->_zoom
                                            displayScale:scale error:renderErr errorLength:sizeof(renderErr)];
      if (!page) {
          needsFullRender = YES;
          return;
      }
      page.highlights = old.highlights ?: @[];
      page.selectionRects = old.selectionRects ?: @[];
      [self copyMinimapThumbnailFromPage:old toPage:page];
      [self->_renderedPages replaceObjectAtIndex:index withObject:page];
      [self->_pageView refreshRenderedPages:self->_renderedPages changedPageIndex:(NSInteger)index];
    }];
    if (needsFullRender) {
        [self rerenderDocumentAfterEditOfPages:pages
                                 restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
    } else {
        [self refreshMinimapThumbnailsOfEditedPages:pages];
        [self cacheActiveRenderedPagesForSelectedTab];
        [self renderVisiblePageCropsForCurrentViewportIfNeeded];
    }
    // Collection keeps one version per burst of filling, not one per field.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fillCollectionCatchUp:) object:nil];
    [self performSelector:@selector(fillCollectionCatchUp:) withObject:[_path copy] afterDelay:5.0];
    return YES;
}

- (void)fillCollectionCatchUp:(NSString*)path {
    if (!path.length) return;
    [self collectionDidSavePath:path];
    SPDFFillSession* session = [[self existingFillController] session];
    if ([session.protectedPath isEqual:path]) session.protectedForEdits = NO;
}

@end
