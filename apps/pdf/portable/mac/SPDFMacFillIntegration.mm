#import "SPDFMacFillIntegration.h"

#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacPageRendering.h"
#import "SPDFMacWorkspaceChrome.h"

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
- (void)copyMinimapThumbnailFromPage:(SPDFRenderedPage*)source toPage:(SPDFRenderedPage*)destination;
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
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    BOOL available = [self.reader fillSignAvailable];
    if (item.action == @selector(toggleFillAndSign:))
        item.state = [self.reader fillSignShowing] ? NSControlStateValueOn : NSControlStateValueOff;
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
    [[self existingFillController] flushEditor];
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
    if (!fieldsOnly && summary.docmdp == 2) {
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
    [pages enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
      (void)stop;
      if (index >= self->_renderedPages.count) return;
      SPDFRenderedPage* old = self->_renderedPages[index];
      if (!old.image && !old.viewportImage) return;  // not drawn yet: it renders from the saved file when shown
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
        [self renderDocumentAndScrollToPage:_pageIndex
                                   alignTop:NO
                              restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
    } else {
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
