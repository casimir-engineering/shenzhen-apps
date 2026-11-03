#pragma once
// Comments on PDFs and Markdown documents: the shared commands (SPDFMacCommentActions.mm) and the Markdown side,
// which keeps its comments in "<title> - comments.md" beside the document (SPDFMacMarkdownCommentsIntegration.mm).
#import "SPDFMacDelegatePrivate.h"

// The name new comments carry when none is set: the Mac account's full name, else its short name.
FOUNDATION_EXPORT NSString* SPDFDefaultCommentAuthor(void);
// What Add Comment… in a page's menu carries: the page and the point on it where the menu was opened (page -1 when
// the menu was not over a page), so the comment goes there whenever the action arrives.
FOUNDATION_EXPORT NSDictionary* SPDFMacPageMenuCommentContext(NSInteger pageIndex, NSPoint pagePoint);

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
// Builds the comment box shortly after launch (done by itself), so the first one opens at once too.
- (void)scheduleCommentEditorWarmUp;
// For a page's menu opened before that: builds the box while the menu is on screen.
- (void)warmCommentEditorWhileMenuIsOpen;
- (NSInteger)commentIndexForEditAction:(id)sender;
// The card's Resolve / Reopen button: marks the comment resolved, or open again, in the PDF or the comments file.
- (void)resolveComment:(id)sender;
- (NSInteger)commentIndexAtPageIndex:(NSInteger)pageIndex pagePoint:(NSPoint)pagePoint;
@end

@class SPDFMacCommentEditorView;

// Your name on comments, changed where it is shown (SPDFMacCommentAuthorIntegration.mm).
@interface ShenzhenMacDelegate (SPDFMacCommentAuthor)
// Stores `name` as Settings does and shows it everywhere; NO (nothing changes) when it is empty or the same.
- (BOOL)changeCommentAuthorTo:(NSString*)name;
// After the name was stored here (Settings): shows it everywhere, in this window and the others.
- (void)commentAuthorChanged;
- (void)letCommentEditorChangeAuthor:(SPDFMacCommentEditorView*)editor;
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
// Resolve / Reopen on a comment card (the shared "resolved" state, SPDFMacMarkdownComments.h).
- (void)setMarkdownCommentAtIndex:(NSInteger)index resolved:(BOOL)resolved;
- (BOOL)markdownCommentIsResolvedAtIndex:(NSInteger)index;
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
