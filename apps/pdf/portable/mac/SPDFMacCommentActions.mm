// Comment commands shared by PDFs and Markdown: the comment editor, the author new comments carry, and Add / Edit /
// Delete Comment. A PDF keeps its comments as annotations inside the file; a Markdown document keeps them beside it
// (SPDFMacMarkdownCommentsIntegration.mm), and these commands route there when a Markdown tab is active. Moved out of
// ShenzhenPDFMac.mm whole.

#import "SPDFMacCommentActions.h"
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacCommentEditor.h"
#import "SPDFMacMarkdownPageCanvas.h"
#import "SPDFMacPageRendering.h"
#import "SPDFMacUIHelpers.h"

#import <objc/runtime.h>

static NSView* SPDFFindCanvas(NSView* root) {
    if ([root isKindOfClass:SPDFMacMarkdownPageCanvas.class]) return root;
    for (NSView* sub in root.subviews) {
        NSView* found = SPDFFindCanvas(sub);
        if (found) return found;
    }
    return nil;
}

NSDictionary* SPDFMacPageMenuCommentContext(NSInteger pageIndex, NSPoint pagePoint) {
    return @{@"commentContextPage" : @(pageIndex), @"commentContextPoint" : [NSValue valueWithPoint:pagePoint]};
}

static NSDictionary* SPDFPageMenuContextOfSender(id sender) {
    id context = [sender respondsToSelector:@selector(representedObject)] ? [sender representedObject] : nil;
    return [context isKindOfClass:NSDictionary.class] && context[@"commentContextPage"] ? context : nil;
}

NSString* SPDFDefaultCommentAuthor(void) {
    NSString* name = NSFullUserName();
    if (name.length == 0) name = NSUserName();
    return name ?: @"";
}

// Implemented by the coordinator and its other categories.
@interface ShenzhenMacDelegate (SPDFMacCommentActionsHost)
- (NSArray<NSValue*>*)currentSelectionRects;
- (void)collectionDidSavePath:(NSString*)path;
- (void)refreshActiveTabCachedFileAttributesAfterSelfSave;
- (void)reloadCommentsFromActiveDocument;
@end

@implementation ShenzhenMacDelegate (SPDFMacCommentActions)

- (NSString*)currentCommentAuthor {
    NSString* author = [_commentAuthor stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return author.length > 0 ? author : SPDFDefaultCommentAuthor();
}

// Settings shows an empty name field as "use the Mac's name", so a name equal to that default is stored as empty:
// the comments then follow the account name if it changes.
- (void)rememberCommentAuthor:(NSString*)author {
    author = [author stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    _commentAuthor = [author isEqualToString:SPDFDefaultCommentAuthor()] ? @"" : author;
    [self savePersistentState];
}

static char kEditorAnchorKey;

- (void)noteCommentEditorAnchorAtWindowPoint:(NSPoint)point {
    objc_setAssociatedObject(self, &kEditorAnchorKey, @[ [NSValue valueWithPoint:point], NSDate.date ],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Where the editor opens: where the page's menu was just opened, else under the selection, else mid-page.
- (NSPoint)commentEditorAnchorInView:(NSView*)host {
    NSArray* anchor = objc_getAssociatedObject(self, &kEditorAnchorKey);
    if (anchor && -[anchor[1] timeIntervalSinceNow] < 30)
        return [host convertPoint:[anchor[0] pointValue] fromView:nil];
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? self.activeMarkdownSession : nil;
    NSView* canvas = session.selectedRange.length ? SPDFFindCanvas(host) : nil;
    NSRect inWindow = NSZeroRect;
    if (canvas) {
        NSRect rect = [(SPDFMacMarkdownPageCanvas*)canvas firstRectForRange:session.selectedRange];
        inWindow = [canvas convertRect:rect toView:nil];
    } else if (!session && _pageView && _selectedText.length && _selectionPageIndex >= 0 &&
               _selectionPageIndex < (NSInteger)_renderedPages.count) {
        NSRect pageRect = [_pageView rectForPageAtIndex:_selectionPageIndex];
        for (NSValue* value in [self currentSelectionRects]) {
            NSRect rect = spdf_mac_page_rect_to_view_rect(value.rectValue, pageRect, _renderedPages[(NSUInteger)_selectionPageIndex]);
            inWindow = NSIsEmptyRect(inWindow) ? rect : NSUnionRect(inWindow, rect);
        }
        if (!NSIsEmptyRect(inWindow)) inWindow = [_pageView convertRect:inWindow toView:nil];
    }
    if (!NSIsEmptyRect(inWindow)) {
        NSRect inHost = [host convertRect:inWindow fromView:nil];
        return NSMakePoint(NSMinX(inHost), host.isFlipped ? NSMaxY(inHost) : NSMinY(inHost));
    }
    return NSMakePoint(NSMidX(host.bounds), NSMidY(host.bounds) + 80);
}

// Text typed and left by a click outside, per passage (draftKey), until it is saved or discarded with Esc.
- (NSMutableDictionary<NSString*, NSString*>*)commentDrafts {
    static char key;
    NSMutableDictionary* drafts = objc_getAssociatedObject(self, &key);
    if (!drafts) objc_setAssociatedObject(self, &key, drafts = [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN);
    return drafts;
}

// The window's one comment box, built once and reused (SPDFMacCommentEditor.h).
- (SPDFMacCommentEditorView*)commentEditor {
    static char key;
    SPDFMacCommentEditorView* editor = objc_getAssociatedObject(self, &key);
    if (!editor) {
        editor = [[SPDFMacCommentEditorView alloc] initWithTitle:@"" button:@"" author:@"" text:@""];
        objc_setAssociatedObject(self, &key, editor, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return editor;
}

// Builds and draws the box once while nothing else happens, and puts it, hidden, in the window, so the first comment
// of the session opens as fast as the next ones.
- (void)warmCommentEditor {
    NSView* host = _window.contentView;
    SPDFMacCommentEditorView* editor = [self commentEditor];
    if (!host || editor.superview || editor.isOpen) return;
    [editor warmUp];
    editor.hidden = YES;
    [host addSubview:editor positioned:NSWindowAbove relativeTo:nil];
}

// Once the app has launched, the box is warmed while nothing else happens.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
                                                  (void)note;
                                                  id reader = NSApp.delegate;
                                                  if ([reader isKindOfClass:ShenzhenMacDelegate.class])
                                                      [(ShenzhenMacDelegate*)reader scheduleCommentEditorWarmUp];
                                                }];
}

- (void)scheduleCommentEditorWarmUp {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(warmCommentEditor) object:nil];
    [self performSelector:@selector(warmCommentEditor) withObject:nil afterDelay:1.5];
    dispatch_async(dispatch_get_main_queue(), ^{ [self installAddCommentMenuItem]; });
}

- (void)warmCommentEditorWhileMenuIsOpen {
    if ([self commentEditor].superview) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(warmCommentEditor) object:nil];
    [self performSelector:@selector(warmCommentEditor) withObject:nil afterDelay:0
                  inModes:@[ NSEventTrackingRunLoopMode, NSDefaultRunLoopMode ]];
}

// Edit ▸ Add Comment… (⌘J): the box for the selection, with no menu in between. Put just above Set Author.
- (void)installAddCommentMenuItem {
    NSMenu* edit = nil;
    NSInteger index = -1;
    for (NSMenuItem* top in NSApp.mainMenu.itemArray)
        for (NSMenuItem* item in top.submenu.itemArray) {
            if (item.action == @selector(addComment:)) return;
            if (item.action == @selector(setCommentAuthor:)) edit = top.submenu, index = [edit indexOfItem:item];
        }
    if (!edit) return;
    NSMenuItem* add = [[NSMenuItem alloc] initWithTitle:@"Add Comment..." action:@selector(addComment:) keyEquivalent:@"j"];
    add.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    spdf_set_menu_item_system_symbol(add, @"text.bubble");
    [edit insertItem:add atIndex:index];
}

- (void)openCommentEditorWithTitle:(NSString*)title
                            button:(NSString*)button
                            author:(NSString*)author
                              text:(NSString*)text
                          draftKey:(NSString*)draftKey
                        completion:(void (^)(NSString* text))completion {
    NSView* host = _window.contentView;
    SPDFMacCommentEditorView* editor = [self commentEditor];
    if (editor.isOpen) [editor closeKeepingDraft];
    NSString* draft = draftKey ? self.commentDrafts[draftKey] : nil;
    [editor resetWithTitle:title button:button author:author text:draft ?: text ?: @""];
    if ([title isEqualToString:@"Add Comment"]) [self letCommentEditorChangeAuthor:editor];
    __weak ShenzhenMacDelegate* weakSelf = self;
    editor.finished = ^(NSString* result, BOOL saved) {
      ShenzhenMacDelegate* reader = weakSelf;
      if (draftKey) reader.commentDrafts[draftKey] = saved ? nil : result;
      if (saved) completion(result);
    };
    [editor showInView:host near:[self commentEditorAnchorInView:host]];
    objc_setAssociatedObject(self, &kEditorAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)addComment:(id)sender {
    // Not from a page's menu (the Edit menu, ⌘J): the box goes under the selection, not where a menu was last opened.
    if (!SPDFPageMenuContextOfSender(sender) && _contextPageIndex < 0)
        objc_setAssociatedObject(self, &kEditorAnchorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([self isMarkdownActive]) {
        [self addMarkdownComment:sender];
        return;
    }
    if (!_doc || !_path.length) {
        NSBeep();
        return;
    }
    // Read the selection and the clicked point now: a PDF that cannot be written in place (a temporary or read-only
    // folder) is reopened from a writable copy when the comment is added, which clears them. The page's menu hands
    // its point over with the item (else the point of a menu still open); from the Edit menu or ⌘J there is no point,
    // only the selection.
    NSDictionary* menuContext = SPDFPageMenuContextOfSender(sender);
    BOOL hasSelection = _selectedText.length > 0 && _selectionPageIndex >= 0 && [self currentSelectionRects].count > 0;
    NSInteger contextPage = menuContext ? [menuContext[@"commentContextPage"] integerValue] : _contextPageIndex;
    NSInteger pageIndex = hasSelection ? _selectionPageIndex : contextPage;
    NSArray<NSValue*>* values = hasSelection ? [self currentSelectionRects] : @[];
    NSString* selectedText = hasSelection ? [_selectedText copy] : nil;
    NSPoint point = menuContext ? [menuContext[@"commentContextPoint"] pointValue] : _contextPagePoint;
    if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) {
        NSBeep();
        return;
    }
    if (pageIndex >= spdf_page_count(_doc) || ![self activePDFAllowsCommentChangesFor:@"adding a comment"]) {
        if (pageIndex >= spdf_page_count(_doc)) NSBeep();
        return;
    }
    spdf_document* doc = _doc;
    NSString* draftKey = [NSString stringWithFormat:@"%@#%ld#%@", _path, (long)pageIndex,
                                                    selectedText ?: NSStringFromPoint(point)];
    // The box opens before anything touches the file: the Collection's copy of this version, or the move of a PDF
    // that cannot be written in place, happen when Add is pressed.
    [self openCommentEditorWithTitle:@"Add Comment"
                              button:@"Add"
                              author:[self currentCommentAuthor]
                                text:@""
                            draftKey:draftKey
                          completion:^(NSString* comment) {
                            if (self->_doc != doc) return;  // the tab changed while the editor was open
                            if (![self ensureActivePDFCanBeModifiedForOperation:@"adding a comment"] || !self->_doc ||
                                pageIndex >= spdf_page_count(self->_doc)) {
                                self.commentDrafts[draftKey] = comment;  // not added: the words stay for next time
                                return;
                            }
                            [self addPDFComment:comment page:pageIndex rects:values point:point];
                          }];
}

// What -ensureActivePDFCanBeModifiedForOperation: refuses without touching the file: a password-protected PDF whose
// permissions do not allow comments. Said before the box opens rather than after the comment is typed.
- (BOOL)activePDFAllowsCommentChangesFor:(NSString*)operation {
    if (!spdf_is_password_protected(_doc) || spdf_has_permission(_doc, 'n')) return YES;
    [self showError:@"Operation is not allowed"
             detail:[NSString stringWithFormat:@"This PDF's user permissions do not allow %@. Open it with the owner "
                                               @"password to continue.",
                                               operation]];
    return NO;
}

- (void)addPDFComment:(NSString*)comment page:(NSInteger)pageIndex rects:(NSArray<NSValue*>*)values point:(NSPoint)point {
    BOOL hasSelection = values.count > 0;
    char err[1024];
    BOOL ok = NO;
    if (hasSelection) {
        int count = (int)MIN((NSUInteger)256, values.count);
        spdf_rect rects[256];
        for (int i = 0; i < count; ++i) {
            NSRect r = values[(NSUInteger)i].rectValue;
            rects[i].x0 = NSMinX(r);
            rects[i].y0 = NSMinY(r);
            rects[i].x1 = NSMaxX(r);
            rects[i].y1 = NSMaxY(r);
        }
        ok = spdf_add_highlight_comment(_doc, (int)pageIndex, rects, count, comment.UTF8String,
                                        [self currentCommentAuthor].UTF8String, err, sizeof(err));
    } else {
        ok = spdf_add_text_comment(_doc, (int)pageIndex, (float)point.x, (float)point.y,
                                   comment.UTF8String, [self currentCommentAuthor].UTF8String, err, sizeof(err));
    }
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not add comment" detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    // Refresh cached mtime/size so the active-file watcher treats this as our
    // own write and does not self-trigger a reload.
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    _statusLabel.stringValue = @"Comment added.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex
                               alignTop:NO
                          restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
}

- (void)setCommentAuthor:(id)sender {
    (void)sender;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Set Author for Comments";
    alert.informativeText = @"New comments will use this author.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 360, 24)];
    field.stringValue = [self currentCommentAuthor];
    alert.accessoryView = field;
    [_window makeFirstResponder:field];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self rememberCommentAuthor:field.stringValue];
    _statusLabel.stringValue = _commentAuthor.length ? @"Comment author saved." : @"Comment author reset.";
}

- (spdf_comment_item*)commentItemForIndex:(NSInteger)commentIndex {
    if (commentIndex < 0) return NULL;
    for (int i = 0; i < _comments.count; ++i) {
        if (_comments.items[i].index == commentIndex) return &_comments.items[i];
    }
    return NULL;
}

- (NSNumber*)commentIndexForSidebarRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)_sidebarItems.count) return nil;
    NSDictionary* item = _sidebarItems[(NSUInteger)row];
    if (![item[@"kind"] isEqualToString:@"comment"]) return nil;
    NSNumber* commentIndex = item[@"commentIndex"];
    return [commentIndex isKindOfClass:NSNumber.class] ? commentIndex : nil;
}

- (NSInteger)commentIndexForSidebarContextRow {
    NSNumber* commentIndex = [self commentIndexForSidebarRow:_sidebarTable.clickedRow];
    return commentIndex ? commentIndex.integerValue : -1;
}

- (NSInteger)commentIndexAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint {
    if (pageIndex < 0) return -1;
    for (NSDictionary* comment in [self commentAnnotationsForPage:pageIndex]) {
        NSValue* boundsValue = comment[@"bounds"];
        if (!boundsValue) continue;
        NSRect bounds = NSInsetRect(boundsValue.rectValue, -3.0, -3.0);
        if (NSPointInRect(pagePoint, bounds)) return [comment[@"commentIndex"] integerValue];
    }
    return -1;
}

- (NSInteger)commentIndexForEditAction:(id)sender {
    if ([sender isKindOfClass:NSMenuItem.class]) {
        id represented = ((NSMenuItem*)sender).representedObject;
        if ([represented isKindOfClass:NSNumber.class]) return [represented integerValue];
    }
    NSInteger sidebarIndex = [self commentIndexForSidebarContextRow];
    if (sidebarIndex >= 0) return sidebarIndex;
    return _contextCommentIndex;
}

- (void)editComment:(id)sender {
    if ([self isMarkdownActive]) {
        [self editMarkdownCommentAtIndex:[self commentIndexForEditAction:sender]];
        return;
    }
    if (!_doc || !_path.length) return;
    // The index first: moving a PDF from a temporary folder to a writable copy (when the edit is saved) reopens it and
    // clears what was clicked.
    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    if (![self activePDFAllowsCommentChangesFor:@"editing a comment"]) return;
    if (![self commentItemForIndex:commentIndex]) [self reloadCommentsFromActiveDocument];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }

    NSString* author =
        item->author && *item->author ? [NSString stringWithUTF8String:item->author] : [self currentCommentAuthor];
    NSString* text = item->text && *item->text ? [NSString stringWithUTF8String:item->text] : @"";
    spdf_document* doc = _doc;
    NSString* draftKey = [NSString stringWithFormat:@"%@#edit#%ld", _path, (long)commentIndex];
    // As for Add: the box first, the Collection copy or writable copy when Save is pressed.
    [self openCommentEditorWithTitle:@"Edit Comment"
                              button:@"Save"
                              author:author
                                text:text
                            draftKey:draftKey
                          completion:^(NSString* edited) {
                            if (self->_doc != doc) return;
                            if (![self ensureActivePDFCanBeModifiedForOperation:@"editing a comment"]) {
                                self.commentDrafts[draftKey] = edited;
                                return;
                            }
                            // The reopened copy has the same comments, loaded in the background: read them now.
                            if (![self commentItemForIndex:commentIndex]) [self reloadCommentsFromActiveDocument];
                            if (![self commentItemForIndex:commentIndex]) {
                                NSBeep();
                                return;
                            }
                            [self savePDFComment:commentIndex text:edited author:author];
                          }];
}

- (void)savePDFComment:(NSInteger)commentIndex text:(NSString*)text author:(NSString*)author {
    char err[1024];
    BOOL ok = spdf_update_comment(_doc, (int)commentIndex, text.UTF8String, author.UTF8String, err, sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not edit comment"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    [self savePersistentState];
    _statusLabel.stringValue = @"Comment updated.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex
                               alignTop:NO
                          restoreOrigin:[NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin]];
}

- (void)resolveComment:(id)sender {
    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    if ([self isMarkdownActive]) {
        [self setMarkdownCommentAtIndex:commentIndex resolved:![self markdownCommentIsResolvedAtIndex:commentIndex]];
        return;
    }
    if (!_doc || !_path.length) return;
    if (![self ensureActivePDFCanBeModifiedForOperation:@"resolving a comment"]) return;
    if (![self commentItemForIndex:commentIndex]) [self reloadCommentsFromActiveDocument];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }
    BOOL resolve = !item->resolved;
    char err[1024];
    BOOL ok = spdf_set_comment_resolved(_doc, (int)commentIndex, resolve, [self currentCommentAuthor].UTF8String, err,
                                        sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:resolve ? @"Could not resolve comment" : @"Could not reopen comment"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];
    _statusLabel.stringValue = resolve ? @"Comment resolved." : @"Comment reopened.";
    [self reloadCommentsFromActiveDocument];
}

- (void)deleteComment:(id)sender {
    if ([self isMarkdownActive]) {
        [self deleteMarkdownCommentAtIndex:[self commentIndexForEditAction:sender]];
        return;
    }
    if (!_doc || !_path.length) return;
    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    if (![self ensureActivePDFCanBeModifiedForOperation:@"deleting a comment"]) return;
    if (![self commentItemForIndex:commentIndex]) [self reloadCommentsFromActiveDocument];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }

    NSString* text = item->text && *item->text ? [NSString stringWithUTF8String:item->text] : @"";
    NSString* detail = @"This will permanently remove the comment from the PDF.";
    if (text.length > 0) {
        NSString* preview = text.length > 180 ? [[text substringToIndex:180] stringByAppendingString:@"..."] : text;
        detail = [NSString stringWithFormat:@"%@\n\n%@", detail, preview];
    }

    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Delete Comment?";
    alert.informativeText = detail;
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;

    [self documentViewEndHoverComment];
    NSValue* restoreOrigin = [NSValue valueWithPoint:_pageScrollView.contentView.bounds.origin];
    char err[1024];
    BOOL ok = spdf_delete_comment(_doc, (int)commentIndex, err, sizeof(err));
    if (ok) ok = spdf_save_document(_doc, _path.fileSystemRepresentation, err, sizeof(err));
    if (ok) [self collectionDidSavePath:_path];
    if (!ok) {
        [self showError:@"Could not delete comment"
                 detail:[NSString stringWithUTF8String:err[0] ? err : "Unknown error"]];
        return;
    }
    [self refreshActiveTabCachedFileAttributesAfterSelfSave];

    _statusLabel.stringValue = @"Comment deleted.";
    [self reloadCommentsFromActiveDocument];
    [self renderDocumentAndScrollToPage:_pageIndex alignTop:NO restoreOrigin:restoreOrigin];
}

@end
