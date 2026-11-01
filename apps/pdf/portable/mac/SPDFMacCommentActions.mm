// Comment commands shared by PDFs and Markdown: the comment editor, the author new comments carry, and Add / Edit /
// Delete Comment. A PDF keeps its comments as annotations inside the file; a Markdown document keeps them beside it
// (SPDFMacMarkdownCommentsIntegration.mm), and these commands route there when a Markdown tab is active. Moved out of
// ShenzhenPDFMac.mm whole.

#import "SPDFMacCommentActions.h"
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownDelegatePrivate.h"

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

- (NSDictionary*)promptForCommentEditorWithTitle:(NSString*)title
                                     buttonTitle:(NSString*)buttonTitle
                                          author:(NSString*)author
                                            text:(NSString*)text {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = title ?: @"Comment";
    alert.informativeText = @"Edit the comment author and text.";
    [alert addButtonWithTitle:buttonTitle ?: @"Save"];
    [alert addButtonWithTitle:@"Cancel"];

    NSView* accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 188)];
    NSTextField* authorLabel = [NSTextField labelWithString:@"Author"];
    authorLabel.frame = NSMakeRect(0, 164, 420, 18);
    NSTextField* authorField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 136, 420, 24)];
    authorField.stringValue = author ?: @"";

    NSTextField* commentLabel = [NSTextField labelWithString:@"Comment"];
    commentLabel.frame = NSMakeRect(0, 112, 420, 18);
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 108)];
    scroll.hasVerticalScroller = YES;
    NSTextView* textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 108)];
    textView.string = text ?: @"";
    textView.font = [NSFont systemFontOfSize:13.0];
    textView.verticallyResizable = YES;
    textView.horizontallyResizable = NO;
    textView.textContainer.widthTracksTextView = YES;
    scroll.documentView = textView;

    [accessory addSubview:authorLabel];
    [accessory addSubview:authorField];
    [accessory addSubview:commentLabel];
    [accessory addSubview:scroll];
    alert.accessoryView = accessory;
    NSRange commentRange = NSMakeRange(0, textView.string.length);
    [textView setSelectedRange:commentRange];
    [alert.window setInitialFirstResponder:textView];
    [alert.window makeFirstResponder:textView];
    dispatch_async(dispatch_get_main_queue(), ^{
      [alert.window makeFirstResponder:textView];
      [textView setSelectedRange:commentRange];
    });
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;

    NSString* trimmedText =
        [textView.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString* trimmedAuthor =
        [authorField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedText.length == 0) return nil;
    return @{@"author" : trimmedAuthor ?: @"", @"text" : trimmedText};
}

- (NSString*)promptForCommentTextWithDefault:(NSString*)defaultText {
    NSDictionary* result = [self promptForCommentEditorWithTitle:@"Add Comment"
                                                     buttonTitle:@"Add"
                                                          author:[self currentCommentAuthor]
                                                            text:defaultText ?: @""];
    if (result[@"author"]) [self rememberCommentAuthor:result[@"author"]];
    return result[@"text"];
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

    NSString* comment = [self promptForCommentTextWithDefault:hasSelection ? _selectedText : @""];
    if (!comment) return;
    comment = [comment stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (comment.length == 0) {
        NSBeep();
        return;
    }

    char err[1024];
    BOOL ok = NO;
    if (hasSelection) {
        NSArray<NSValue*>* values = [self currentSelectionRects];
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
        ok = spdf_add_text_comment(_doc, (int)pageIndex, (float)_contextPagePoint.x, (float)_contextPagePoint.y,
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
    NSDictionary* result = [self promptForCommentEditorWithTitle:@"Edit Comment"
                                                     buttonTitle:@"Save"
                                                          author:author
                                                            text:text];
    if (!result) return;

    [self rememberCommentAuthor:result[@"author"]];
    char err[1024];
    BOOL ok = spdf_update_comment(_doc, (int)commentIndex, [result[@"text"] UTF8String], [result[@"author"] UTF8String],
                                  err, sizeof(err));
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
