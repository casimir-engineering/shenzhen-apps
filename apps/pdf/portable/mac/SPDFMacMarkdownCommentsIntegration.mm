// Comments on Markdown documents, in the reader (SPDFMacCommentActions.h). The comments of "Guide.md" live in
// "Guide - comments.md" beside it (format and anchoring: SPDFMacMarkdownComments.h). They are read the first time
// the document's sidebar is built, re-anchored after every render (an edit to the document moves them), and the
// file is rewritten on every change and removed with the last comment, so no empty file is left behind.
//
// A document without comments costs one stat of the comments file's path when its sidebar is built.

#import "SPDFMacCommentActions.h"
#import "SPDFMacMarkdownComments.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacMarkdownSession.h"
#import "SPDFMacMarkdownSidebarModel.h"
#import "SPDFMacMarkdownRouting.h"
#import "SPDFMacModels.h"
#import "SPDFMacUIHelpers.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "markdown/SPDFMarkdown.h"

#import <objc/runtime.h>

@interface SPDFMacMarkdownCommentState : NSObject
@property(nonatomic) NSMutableArray<SPDFMarkdownComment*>* comments;
@property(nonatomic) BOOL loaded;
@property(nonatomic, copy) NSDate* fileStamp;
@property(nonatomic, weak) id anchoredRender;
@property(nonatomic) SPDFMarkdownCommentAnchors* anchors;
@end
@implementation SPDFMacMarkdownCommentState
@end

static NSDate* ModificationDate(NSString* path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

// No SF Symbol shows a document with a comment: `doc` with a small `bubble.left.fill` at its bottom right, the doc
// cut away around the badge so the two read apart. A template, so it tints like the menu's other icons.
static NSImage* DocumentWithCommentsImage(void) {
    NSImage* doc = [NSImage imageWithSystemSymbolName:@"doc" accessibilityDescription:nil];
    NSImage* bubble = [NSImage imageWithSystemSymbolName:@"bubble.left.fill" accessibilityDescription:nil];
    if (!doc || !bubble) return doc;
    NSSize size = NSMakeSize(doc.size.width + 3, doc.size.height);
    NSImage* image = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect rect) {
      (void)rect;
      [doc drawInRect:NSMakeRect(0, 0, doc.size.width, doc.size.height)];
      NSRect badge = NSMakeRect(size.width - 10, 0, 10, 10 * bubble.size.height / bubble.size.width);
      [[NSColor blackColor] set];
      NSRectFillUsingOperation(NSInsetRect(badge, -1.2, -1.2), NSCompositingOperationClear);
      [bubble drawInRect:badge];
      return YES;
    }];
    [image setTemplate:YES];
    image.accessibilityDescription = @"Document and comments";
    return image;
}

static NSString* SidebarTitle(SPDFMarkdownComment* comment) {
    NSString* title = comment.text.length ? comment.text : comment.quote;
    return comment.author.length ? [NSString stringWithFormat:@"%@: %@", comment.author, title] : title;
}

@interface ShenzhenMacDelegate (SPDFMacMarkdownCommentsSidebar)
- (BOOL)sidebarSearchText:(NSString*)text matchesFilter:(NSString*)filter;
@end

@implementation ShenzhenMacDelegate (SPDFMacMarkdownComments)
static char kStatesKey, kContextLocationKey;

- (NSMutableDictionary<NSString*, SPDFMacMarkdownCommentState*>*)markdownCommentStates {
    NSMutableDictionary* states = objc_getAssociatedObject(self, &kStatesKey);
    if (!states) {
        states = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(self, &kStatesKey, states, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return states;
}

- (BOOL)markdownPathTakesComments:(NSString*)path {
    return path.length && !SPDFMarkdownIsCommentsFilePath(path) && !SPDFMacPathIsCollectionArchive(path);
}

// The active document's comments, read from its file when that changed (another window may have written it) and
// placed on the current render.
- (SPDFMacMarkdownCommentState*)activeMarkdownCommentState {
    if (![self isMarkdownActive]) return nil;
    NSString* path = _path.stringByStandardizingPath;
    if (![self markdownPathTakesComments:path]) return nil;
    SPDFMacMarkdownCommentState* state = self.markdownCommentStates[path];
    if (!state) state = self.markdownCommentStates[path] = [SPDFMacMarkdownCommentState new];
    NSString* file = SPDFMarkdownCommentsFilePath(path);
    NSDate* stamp = ModificationDate(file);
    if (!state.loaded || !(stamp == state.fileStamp || [stamp isEqualToDate:state.fileStamp])) {
        NSString* text = stamp ? [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] : nil;
        state.comments = [(text ? SPDFMarkdownCommentsParseFile(text) : @[]) mutableCopy];
        state.fileStamp = stamp;
        state.loaded = YES;
        state.anchoredRender = nil;
    }
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    SPDFMarkdownRenderedDocument* rendered = session.renderedDocument;
    if (rendered && state.anchoredRender != rendered && state.comments.count) {
        BOOL changed = NO;
        for (SPDFMarkdownComment* comment in state.comments) changed |= [[self anchorsForState:state] placeComment:comment];
        state.comments = [SPDFMarkdownCommentsSorted(state.comments) mutableCopy];
        if (changed) [self writeMarkdownCommentState:state path:path];
    }
    [self applyMarkdownCommentHighlights:state];
    return state;
}

- (SPDFMarkdownCommentAnchors*)anchorsForState:(SPDFMacMarkdownCommentState*)state {
    SPDFMarkdownRenderedDocument* rendered = self.activeMarkdownSession.renderedDocument;
    if (!rendered) return nil;
    if (state.anchoredRender != rendered || !state.anchors) {
        NSString* source = [NSString stringWithContentsOfFile:_path encoding:NSUTF8StringEncoding error:nil] ?: @"";
        state.anchors = [[SPDFMarkdownCommentAnchors alloc] initWithSource:source
                                                                   rendered:rendered.attributedString.string ?: @""];
        state.anchoredRender = rendered;
    }
    return state.anchors;
}

- (void)applyMarkdownCommentHighlights:(SPDFMacMarkdownCommentState*)state {
    NSMutableArray* highlights = [NSMutableArray array];
    for (SPDFMarkdownComment* comment in state.comments) {
        if (!comment.placed) continue;
        NSString* title = comment.author.length ? comment.author : @"Comment";
        [highlights addObject:@{@"range" : [NSValue valueWithRange:comment.renderedRange], @"title" : title,
                                @"text" : comment.text ?: @""}];
    }
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    if (session && ![session.commentHighlights isEqualToArray:highlights]) session.commentHighlights = highlights;
}

- (BOOL)writeMarkdownCommentState:(SPDFMacMarkdownCommentState*)state path:(NSString*)path {
    NSString* file = SPDFMarkdownCommentsFilePath(path);
    NSError* error = nil;
    BOOL ok = YES;
    if (state.comments.count) {
        NSString* text = SPDFMarkdownCommentsFileText(path.lastPathComponent, state.comments);
        ok = [text writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:&error];
    } else if ([NSFileManager.defaultManager fileExistsAtPath:file]) {
        ok = [NSFileManager.defaultManager removeItemAtPath:file error:&error];
    }
    state.fileStamp = ModificationDate(file);
    if (!ok) [self showError:@"Could not save comments" detail:error.localizedDescription ?: file];
    return ok;
}

- (NSInteger)markdownCommentCount {
    return (NSInteger)[self activeMarkdownCommentState].comments.count;
}

- (void)appendMarkdownCommentSidebarItemsMatchingFilter:(NSString*)filter {
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    SPDFMacMarkdownSidebarModel* model = self.activeMarkdownSession.sidebarModel;
    BOOL unplacedShown = NO;
    for (NSUInteger i = 0; i < state.comments.count; i++) {
        SPDFMarkdownComment* comment = state.comments[i];
        NSString* title = SidebarTitle(comment);
        NSString* haystack = [NSString stringWithFormat:@"%@ %@ %@", title, comment.quote,
                                                        [comment.headingPath componentsJoinedByString:@" "]];
        if (![self sidebarSearchText:haystack matchesFilter:filter]) continue;
        if (!comment.placed && !unplacedShown) {
            unplacedShown = YES;
            [_sidebarItems addObject:@{@"kind" : @"findDivider", @"title" : @"Unplaced", @"page" : @(-1)}];
        }
        NSMutableDictionary* item = [@{@"title" : title, @"level" : @0, @"kind" : @"comment", @"commentIndex" : @(i),
                                       @"page" : @(comment.placed ? [model pageIndexForRange:comment.renderedRange] : -1)}
            mutableCopy];
        if (comment.placed) item[@"range"] = [NSValue valueWithRange:comment.renderedRange];
        [_sidebarItems addObject:item];
    }
}

- (void)revealMarkdownCommentAtIndex:(NSInteger)index {
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    if (index < 0 || index >= (NSInteger)state.comments.count) return;
    SPDFMarkdownComment* comment = state.comments[(NSUInteger)index];
    if (comment.placed) [self.activeMarkdownSession revealRange:comment.renderedRange];
    else _statusLabel.stringValue = @"This passage is no longer in the document.";
}

- (void)noteMarkdownContextMenuAtLocation:(NSUInteger)location {
    objc_setAssociatedObject(self, &kContextLocationKey, @(location), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    _contextCommentIndex = -1;
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    for (NSUInteger i = 0; i < state.comments.count && location != NSNotFound; i++) {
        NSRange range = state.comments[i].renderedRange;
        if (state.comments[i].placed && location >= range.location && location < NSMaxRange(range)) {
            _contextCommentIndex = (NSInteger)i;
            break;
        }
    }
}

- (NSUInteger)markdownContextLocation {
    NSNumber* location = objc_getAssociatedObject(self, &kContextLocationKey);
    return location ? location.unsignedIntegerValue : NSNotFound;
}

- (BOOL)canAddMarkdownComment {
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    if (!session.renderedDocument || ![self markdownPathTakesComments:_path.stringByStandardizingPath]) return NO;
    return session.selectedRange.length > 0 || _contextPageIndex >= 0;
}

- (BOOL)canAddCommentNow {
    if ([self isMarkdownActive]) return [self canAddMarkdownComment];
    return _doc != NULL && [self hasActiveDocument] && (_selectedText.length > 0 || _contextPageIndex >= 0);
}

- (BOOL)canEditCommentForSender:(id)sender {
    NSInteger index = [self commentIndexForEditAction:sender];
    if ([self isMarkdownActive]) return index >= 0 && index < [self markdownCommentCount];
    return _doc != NULL && [self hasActiveDocument] && index >= 0;
}

- (void)addMarkdownComment:(id)sender {
    (void)sender;
    SPDFMacMarkdownSession* session = self.activeMarkdownSession;
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    SPDFMarkdownCommentAnchors* anchors = state ? [self anchorsForState:state] : nil;
    NSRange range = session.selectedRange;
    // No selection: the paragraph under the click, cut to its first words so the quote stays short.
    if (!range.length && [self markdownContextLocation] != NSNotFound) {
        range = [anchors blockRangeAtRenderedLocation:[self markdownContextLocation]];
        NSString* text = range.location == NSNotFound ? nil : [session.renderedDocument.attributedString.string
                                                                  substringWithRange:range];
        if (text.length > 120) {
            NSRange space = [text rangeOfString:@" " options:NSBackwardsSearch range:NSMakeRange(60, 60)];
            range.length = space.location != NSNotFound ? space.location : 120;
        }
    }
    SPDFMarkdownComment* comment = [SPDFMarkdownComment new];
    if (!anchors || range.location == NSNotFound || ![anchors anchorComment:comment toRenderedRange:range]) {
        NSBeep();
        return;
    }
    NSString* path = _path.stringByStandardizingPath;
    [self openCommentEditorWithTitle:@"Add Comment"
                              button:@"Add"
                              author:[self currentCommentAuthor]
                                text:@""
                            draftKey:[NSString stringWithFormat:@"%@#%@", path, NSStringFromRange(comment.renderedRange)]
                          completion:^(NSString* text) {
                            // The tab changed while the editor was open: the comment belongs to the other document.
                            if (![self->_path.stringByStandardizingPath isEqualToString:path]) return;
                            comment.text = text;
                            comment.author = [self currentCommentAuthor];
                            comment.date = NSDate.date;
                            [state.comments addObject:comment];
                            state.comments = [SPDFMarkdownCommentsSorted(state.comments) mutableCopy];
                            if (![self writeMarkdownCommentState:state path:path]) return;
                            self->_statusLabel.stringValue = @"Comment added.";
                            [self applyMarkdownCommentHighlights:state];
                            [self rebuildSidebar];
                          }];
}

- (void)editMarkdownCommentAtIndex:(NSInteger)index {
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    if (index < 0 || index >= (NSInteger)state.comments.count) {
        NSBeep();
        return;
    }
    SPDFMarkdownComment* comment = state.comments[(NSUInteger)index];
    NSString* path = _path.stringByStandardizingPath;
    [self openCommentEditorWithTitle:@"Edit Comment"
                              button:@"Save"
                              author:comment.author.length ? comment.author : [self currentCommentAuthor]
                                text:comment.text
                            draftKey:[NSString stringWithFormat:@"%@#edit#%@", path, NSStringFromRange(comment.renderedRange)]
                          completion:^(NSString* text) {
                            if (![self->_path.stringByStandardizingPath isEqualToString:path]) return;
                            comment.text = text;
                            if (![self writeMarkdownCommentState:state path:path]) return;
                            self->_statusLabel.stringValue = @"Comment updated.";
                            [self applyMarkdownCommentHighlights:state];
                            [self rebuildSidebar];
                          }];
}

- (void)deleteMarkdownCommentAtIndex:(NSInteger)index {
    SPDFMacMarkdownCommentState* state = [self activeMarkdownCommentState];
    if (index < 0 || index >= (NSInteger)state.comments.count) {
        NSBeep();
        return;
    }
    SPDFMarkdownComment* comment = state.comments[(NSUInteger)index];
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Delete Comment?";
    NSString* preview = comment.text.length > 180 ? [[comment.text substringToIndex:180] stringByAppendingString:@"..."]
                                                  : comment.text;
    alert.informativeText = preview ?: @"";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self documentViewEndHoverComment];
    [state.comments removeObjectAtIndex:(NSUInteger)index];
    if (![self writeMarkdownCommentState:state path:_path.stringByStandardizingPath]) return;
    _statusLabel.stringValue = @"Comment deleted.";
    [self applyMarkdownCommentHighlights:state];
    [self rebuildSidebar];
}

- (NSString*)existingCommentsFileForPath:(NSString*)path {
    if (!spdf_mac_path_is_markdown(path) || ![self markdownPathTakesComments:path]) return nil;
    NSString* file = SPDFMarkdownCommentsFilePath(path.stringByStandardizingPath);
    return [NSFileManager.defaultManager fileExistsAtPath:file] ? file : nil;
}

- (NSString*)copyDocumentTitleForPath:(NSString*)path {
    BOOL comments = NO;
    if (spdf_mac_path_is_markdown(path)) comments = [self existingCommentsFileForPath:path] != nil;
    else
        for (SPDFDocumentTab* tab in _tabs)
            if ([tab.path isEqualToString:path]) {
                comments = tab.cachedCommentsLoaded && tab.cachedComments.count > 0;
                break;
            }
    return comments ? @"Copy Document and Comments" : @"Copy Document";
}

- (BOOL)validateCopyDocumentItem:(NSMenuItem*)item {
    item.title = [self copyDocumentTitleForPath:_path];
    return [self hasActiveDocument] && _path.length > 0;
}

- (void)moveCommentsFileFrom:(NSString*)source to:(NSString*)destination {
    NSString* file = [self existingCommentsFileForPath:source];
    NSString* target = SPDFMarkdownCommentsFilePath(destination.stringByStandardizingPath);
    [self.markdownCommentStates removeObjectForKey:source.stringByStandardizingPath];
    if (!file || [NSFileManager.defaultManager fileExistsAtPath:target]) return;
    NSString* text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    NSRange firstLine = [text lineRangeForRange:NSMakeRange(0, 0)];
    if ([[text substringWithRange:firstLine] hasPrefix:@"# Comments on "])
        text = [text stringByReplacingCharactersInRange:firstLine
                                             withString:[SPDFMarkdownCommentsHeader(destination.lastPathComponent)
                                                            stringByAppendingString:@"\n"]];
    if (text && [text writeToFile:target atomically:YES encoding:NSUTF8StringEncoding error:nil])
        [NSFileManager.defaultManager removeItemAtPath:file error:nil];
}

- (void)decorateDocumentMenu:(NSMenu*)menu {
    for (NSMenuItem* item in menu.itemArray) {
        if (item.action == NSSelectorFromString(@"openMarkdownInEditor:")) spdf_set_menu_item_system_symbol(item, @"pencil");
        if ([item.title isEqualToString:@"Copy Document and Comments"]) item.image = DocumentWithCommentsImage();
    }
}

- (void)copyCommentsFile:(id)sender {
    id represented = [sender isKindOfClass:NSMenuItem.class] ? ((NSMenuItem*)sender).representedObject : nil;
    NSString* path = [represented isKindOfClass:NSString.class] ? represented : _path;
    NSString* file = [self existingCommentsFileForPath:path];
    NSPasteboard* pasteboard = NSPasteboard.generalPasteboard;
    if (!file) {
        NSBeep();
        return;
    }
    [pasteboard clearContents];
    if (![pasteboard writeObjects:@[ [NSURL fileURLWithPath:file] ]]) {
        NSBeep();
        return;
    }
    _statusLabel.stringValue = @"Comments file copied.";
}

- (void)addCopyCommentsFileItemToMenu:(NSMenu*)menu path:(NSString*)path {
    if (!spdf_mac_path_is_markdown(path) || ![self markdownPathTakesComments:path]) return;
    NSMenuItem* item = [menu addItemWithTitle:@"Copy Comments File" action:@selector(copyCommentsFile:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = path;
    item.enabled = [self existingCommentsFileForPath:path] != nil;
    if (!item.enabled) item.action = nil;
    item.image = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:nil];
}
@end
