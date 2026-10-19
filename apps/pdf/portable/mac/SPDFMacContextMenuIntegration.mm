#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacMarkdownPageCanvas.h"
#import "SPDFMacMarkdownDelegatePrivate.h"
#import "SPDFMacContextPage.h"
#import "SPDFMacCollectionPathPolicy.h"
#import "SPDFMacTranslationEnablement.h"

#import <objc/runtime.h>

@interface SPDFMacContextMenuCloseTarget : NSObject <NSMenuDelegate>
@property(nonatomic, copy) void (^closeHandler)(void);
@end

@implementation SPDFMacContextMenuCloseTarget
- (void)menuDidClose:(NSMenu*)menu {
    (void)menu;
    if (self.closeHandler) self.closeHandler();
}
@end

@interface ShenzhenMacDelegate (SPDFMacContextMenuPrivate)
- (NSInteger)commentIndexAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
- (NSString*)shortSelectedTextForMenuTitle;
@end

@implementation ShenzhenMacDelegate (SPDFMacContextMenuIntegration)

- (NSMenu*)contextMenuForDocumentView:(NSView*)view event:(NSEvent*)event {
    [self documentViewEndHoverComment];
    _contextPageIndex = -1;
    _contextPagePoint = NSZeroPoint;
    _contextCommentIndex = -1;
    if ([view isKindOfClass:SPDFDocumentView.class]) {
        SPDFDocumentView* documentView = (SPDFDocumentView*)view;
        NSPoint point = [documentView convertPoint:event.locationInWindow fromView:nil];
        [documentView point:point fallsInPage:&_contextPageIndex pagePoint:&_contextPagePoint];
        _contextCommentIndex = [self commentIndexAtPageIndex:_contextPageIndex pagePoint:_contextPagePoint];
    } else if ([view isKindOfClass:SPDFMacMarkdownPageCanvas.class]) {
        SPDFMacMarkdownPageCanvas* canvas = (SPDFMacMarkdownPageCanvas*)view;
        NSPoint point = [canvas convertPoint:event.locationInWindow fromView:nil];
        _contextPageIndex = [canvas pageIndexAtPoint:point];
    }

    BOOL markdown = [self isMarkdownActive];
    NSString* selectedText = markdown ? [self markdownSelectedText] : (_selectedText ?: @"");
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    SPDFMacContextMenuCloseTarget* closeTarget = [SPDFMacContextMenuCloseTarget new];
    __weak ShenzhenMacDelegate* weakSelf = self;
    closeTarget.closeHandler = ^{
      ShenzhenMacDelegate* strongSelf = weakSelf;
      if (!strongSelf) return;
      strongSelf->_contextPageIndex = -1;
      strongSelf->_contextPagePoint = NSZeroPoint;
      strongSelf->_contextCommentIndex = -1;
    };
    menu.delegate = closeTarget;
    objc_setAssociatedObject(menu, @selector(contextMenuForDocumentView:event:), closeTarget,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (selectedText.length > 0) {
        NSString* preview = [self shortSelectedTextForMenuTitle];
        NSMenuItem* translateSelection =
            [menu addItemWithTitle:preview.length ? [NSString stringWithFormat:@"Translate \"%@\"", preview]
                                                  : @"Translate Selection"
                            action:@selector(showSelectionTranslationPanel:)
                     keyEquivalent:@""];
        translateSelection.target = self;
        translateSelection.enabled = spdf_translation_selection_enabled([self translationContext]);
        NSMenuItem* webSearch =
            [menu addItemWithTitle:preview.length ? [NSString stringWithFormat:@"Search Web for \"%@\"", preview]
                                                  : @"Search Web"
                            action:@selector(searchSelectedTextInBrowser:)
                     keyEquivalent:@""];
        webSearch.target = self;
        [menu addItem:[NSMenuItem separatorItem]];
    }
    NSMenuItem* copy = [menu addItemWithTitle:@"Copy" action:@selector(copySelection:) keyEquivalent:@""];
    copy.target = self;
    copy.enabled =
                   (selectedText.length > 0 || (markdown && [self.activeMarkdownSession selectionContainsImage]));
    if (!markdown && _contextCommentIndex >= 0) {
        NSMenuItem* editComment = [menu addItemWithTitle:@"Edit Comment..."
                                                  action:@selector(editComment:)
                                           keyEquivalent:@""];
        editComment.target = self;
        editComment.representedObject = @(_contextCommentIndex);
        NSMenuItem* deleteComment = [menu addItemWithTitle:@"Delete Comment..."
                                                    action:@selector(deleteComment:)
                                             keyEquivalent:@""];
        deleteComment.target = self;
        deleteComment.representedObject = @(_contextCommentIndex);
    }
    NSMenuItem* addComment = [menu addItemWithTitle:@"Add Comment..." action:@selector(addComment:) keyEquivalent:@""];
    addComment.enabled = !markdown && _doc != NULL && (selectedText.length > 0 || _contextPageIndex >= 0);
    NSMenuItem* favorite = [menu addItemWithTitle:@"Favorite Page"
                                           action:@selector(favoriteCurrentPage:)
                                    keyEquivalent:@""];
    favorite.enabled = !markdown && _doc != NULL;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Fit Width" action:@selector(fitWidth:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Fit Page" action:@selector(fitPage:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem* showInFolder = [menu addItemWithTitle:@"Show in Folder"
                                               action:@selector(showInFolder:)
                                        keyEquivalent:@""];
    showInFolder.enabled = [self hasActiveDocument] && _path.length > 0;
    if (markdown) {
        NSMenuItem* openInEditor = [menu addItemWithTitle:@"Open in Editor"
                                                   action:@selector(openMarkdownInEditor:)
                                            keyEquivalent:@""];
        openInEditor.target = self;
        openInEditor.enabled = _path.length > 0 && !SPDFMacPathIsCollectionArchive(_path);
    }
    NSMenuItem* copyDocument = [menu addItemWithTitle:@"Copy Document"
                                               action:@selector(copyCurrentDocumentFile:)
                                        keyEquivalent:@""];
    copyDocument.enabled = [self hasActiveDocument] && _path.length > 0;
    NSInteger currentPage = markdown ? self.activeMarkdownSession.currentPageIndex : _pageIndex;
    NSInteger copyPageIndex = _contextPageIndex >= 0 ? _contextPageIndex : currentPage;
    NSMenuItem* copyPage = [menu addItemWithTitle:SPDFMacCopyPageMenuTitle(copyPageIndex, NO)
                                           action:@selector(copyCurrentPageAsPDF:)
                                    keyEquivalent:@""];
    copyPage.enabled = [self canCopyPageAsPDFAtIndex:copyPageIndex];
    if (_contextPageIndex >= 0) copyPage.representedObject = @(_contextPageIndex);
    NSMenuItem* copyImage = [menu addItemWithTitle:SPDFMacCopyPageMenuTitle(copyPageIndex, YES)
                                            action:@selector(copyCurrentPageImage:)
                                     keyEquivalent:@""];
    NSInteger imagePageIndex = copyPageIndex;
    copyImage.enabled = markdown ? [self canCopyCurrentPageImage]
                                 : imagePageIndex >= 0 && imagePageIndex < (NSInteger)_renderedPages.count &&
                                       _renderedPages[(NSUInteger)imagePageIndex].image != nil;
    if (_contextPageIndex >= 0) copyImage.representedObject = @(_contextPageIndex);
    NSMenuItem* copyPath = [menu addItemWithTitle:@"Copy Path"
                                           action:@selector(copyCurrentDocumentPath:)
                                    keyEquivalent:@""];
    copyPath.enabled = [self hasActiveDocument] && _path.length > 0;
    NSMenuItem* properties = [menu addItemWithTitle:@"Properties..."
                                             action:@selector(showProperties:)
                                      keyEquivalent:@""];
    properties.enabled = [self selectedTab].path.length > 0;
    spdf_apply_system_icons_to_menu(menu);
    return menu;
}

@end
