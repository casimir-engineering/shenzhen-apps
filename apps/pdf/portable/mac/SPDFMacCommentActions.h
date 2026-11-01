#pragma once
// Comments on PDFs and Markdown documents: the shared commands (SPDFMacCommentActions.mm) and the Markdown side,
// which keeps its comments in "<title> - comments.md" beside the document (SPDFMacMarkdownCommentsIntegration.mm).
#import "SPDFMacDelegatePrivate.h"

// The name new comments carry when none is set: the Mac account's full name, else its short name.
FOUNDATION_EXPORT NSString* SPDFDefaultCommentAuthor(void);

@interface ShenzhenMacDelegate (SPDFMacCommentActions)
- (void)rememberCommentAuthor:(NSString*)author;
// The inline comment editor (SPDFMacCommentEditor.h), opened where the page's menu was, or under the selection.
// `completion` runs only when the comment is saved, with its non-empty text.
- (void)openCommentEditorWithTitle:(NSString*)title
                            button:(NSString*)button
                            author:(NSString*)author
                              text:(NSString*)text
                          draftKey:(NSString*)draftKey
                        completion:(void (^)(NSString* text))completion;
- (void)noteCommentEditorAnchorAtWindowPoint:(NSPoint)point;
- (NSInteger)commentIndexForEditAction:(id)sender;
- (NSInteger)commentIndexAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
@end

@interface ShenzhenMacDelegate (SPDFMacMarkdownComments)
// Comments of the active Markdown document, loading its comments file and re-anchoring after a render as needed.
- (NSInteger)markdownCommentCount;
- (void)appendMarkdownCommentSidebarItemsMatchingFilter:(NSString*)filter;
- (void)revealMarkdownCommentAtIndex:(NSInteger)index;
// The document context menu over a Markdown page: remembers where it was opened, and which comment is there.
- (void)noteMarkdownContextMenuAtLocation:(NSUInteger)location;
- (BOOL)canAddMarkdownComment;
- (void)addMarkdownComment:(id)sender;
- (void)editMarkdownCommentAtIndex:(NSInteger)index;
- (void)deleteMarkdownCommentAtIndex:(NSInteger)index;
// Validation shared by the Edit menu and the context menus, for PDFs and Markdown alike.
- (BOOL)canAddCommentNow;
- (BOOL)canEditCommentForSender:(id)sender;
// The comments file of a Markdown document when it exists on disk, else nil.
- (NSString*)existingCommentsFileForPath:(NSString*)path;
// "Copy Document and Comments" when the document has comments (a PDF's travel inside it), else "Copy Document".
- (NSString*)copyDocumentTitleForPath:(NSString*)path;
- (BOOL)validateCopyDocumentItem:(NSMenuItem*)item;
// After a Markdown document is renamed: its comments file follows, and names the new document.
- (void)moveCommentsFileFrom:(NSString*)source to:(NSString*)destination;
// Icons the generic symbol table cannot give: a pencil on Open in Editor, a document with a bubble on Copy Document
// and Comments. Run after the menu's other icons are set.
- (void)decorateDocumentMenu:(NSMenu*)menu;
// "Copy Comments File": the active document, or the path a menu item carries.
- (void)copyCommentsFile:(id)sender;
// A "Copy Comments File" item for a document's menu: present for Markdown, disabled while it has no comments.
- (void)addCopyCommentsFileItemToMenu:(NSMenu*)menu path:(NSString*)path;
@end
