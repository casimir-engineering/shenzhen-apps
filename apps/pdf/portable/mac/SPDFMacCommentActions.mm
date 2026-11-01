// Comment commands shared by PDFs and Markdown: the comment editor, the author new comments carry, and Add / Edit /
// Delete Comment. A PDF keeps its comments as annotations inside the file; a Markdown document keeps them beside it
// (SPDFMacMarkdownCommentsIntegration.mm), and these commands route there when a Markdown tab is active. Moved out of
// ShenzhenPDFMac.mm whole.

#import "SPDFMacCommentActions.h"
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacCommentEditor.h"
#import "SPDFMacMarkdownPageCanvas.h"

#import <objc/runtime.h>

static NSView* SPDFFindCanvas(NSView* root) {
    if ([root isKindOfClass:SPDFMacMarkdownPageCanvas.class]) return root;
    for (NSView* sub in root.subviews) {
        NSView* found = SPDFFindCanvas(sub);
        if (found) return found;
    }
    return nil;
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

// Where the editor opens: where the page's menu was just opened, else under the Markdown selection, else mid-page.
- (NSPoint)commentEditorAnchorInView:(NSView*)host {
    NSArray* anchor = objc_getAssociatedObject(self, &kEditorAnchorKey);
    if (anchor && -[anchor[1] timeIntervalSinceNow] < 30)
        return [host convertPoint:[anchor[0] pointValue] fromView:nil];
    SPDFMacMarkdownSession* session = [self isMarkdownActive] ? self.activeMarkdownSession : nil;
    NSView* canvas = session.selectedRange.length ? SPDFFindCanvas(host) : nil;
    if (canvas) {
        NSRect rect = [(SPDFMacMarkdownPageCanvas*)canvas firstRectForRange:session.selectedRange];
        NSRect inHost = [host convertRect:[canvas convertRect:rect toView:nil] fromView:nil];
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

- (void)openCommentEditorWithTitle:(NSString*)title
                            button:(NSString*)button
                            author:(NSString*)author
                              text:(NSString*)text
                          draftKey:(NSString*)draftKey
                        completion:(void (^)(NSString* text))completion {
    NSView* host = _window.contentView;
    for (NSView* view in [host.subviews copy])
        if ([view isKindOfClass:SPDFMacCommentEditorView.class]) [(SPDFMacCommentEditorView*)view closeKeepingDraft];
    NSString* draft = draftKey ? self.commentDrafts[draftKey] : nil;
    SPDFMacCommentEditorView* editor =
        [[SPDFMacCommentEditorView alloc] initWithTitle:title button:button author:author text:draft ?: text ?: @""];
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
    if ([self isMarkdownActive]) {
        [self addMarkdownComment:sender];
        return;
    }
    if (!_doc || !_path.length) {
        NSBeep();
        return;
    }
    if (![self ensureActivePDFCanBeModifiedForOperation:@"adding a comment"]) return;

    BOOL hasSelection = _selectedText.length > 0 && _selectionPageIndex >= 0 && [self currentSelectionRects].count > 0;
    NSInteger pageIndex = hasSelection ? _selectionPageIndex : _contextPageIndex;
    if (pageIndex < 0 || pageIndex >= (NSInteger)_renderedPages.count) {
        NSBeep();
        return;
    }

    NSArray<NSValue*>* values = hasSelection ? [self currentSelectionRects] : @[];
    NSPoint point = _contextPagePoint;
    spdf_document* doc = _doc;
    NSString* draftKey = [NSString stringWithFormat:@"%@#%ld#%@", _path, (long)pageIndex,
                                                    hasSelection ? _selectedText : NSStringFromPoint(point)];
    [self openCommentEditorWithTitle:@"Add Comment"
                              button:@"Add"
                              author:[self currentCommentAuthor]
                                text:@""
                            draftKey:draftKey
                          completion:^(NSString* comment) {
                            if (self->_doc != doc) return;  // the tab changed while the editor was open
                            [self addPDFComment:comment page:pageIndex rects:values point:point];
                          }];
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
    if (![self ensureActivePDFCanBeModifiedForOperation:@"editing a comment"]) return;

    NSInteger commentIndex = [self commentIndexForEditAction:sender];
    spdf_comment_item* item = [self commentItemForIndex:commentIndex];
    if (!item) {
        NSBeep();
        return;
    }

    NSString* author =
        item->author && *item->author ? [NSString stringWithUTF8String:item->author] : [self currentCommentAuthor];
    NSString* text = item->text && *item->text ? [NSString stringWithUTF8String:item->text] : @"";
    spdf_document* doc = _doc;
    [self openCommentEditorWithTitle:@"Edit Comment"
                              button:@"Save"
                              author:author
                                text:text
                            draftKey:[NSString stringWithFormat:@"%@#edit#%ld", _path, (long)commentIndex]
                          completion:^(NSString* edited) {
                            if (self->_doc == doc) [self savePDFComment:commentIndex text:edited author:author];
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

- (void)deleteComment:(id)sender {
    if ([self isMarkdownActive]) {
        [self deleteMarkdownCommentAtIndex:[self commentIndexForEditAction:sender]];
        return;
    }
    if (!_doc || !_path.length) return;
    if (![self ensureActivePDFCanBeModifiedForOperation:@"deleting a comment"]) return;

    NSInteger commentIndex = [self commentIndexForEditAction:sender];
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
