#pragma once
// Versions of a document, for reviewing what an agent (or anyone) rewrites: v1 is commented, v2 is written, and v1's
// comments stay on v1.
//
// The document's own file is always the newest version, so editors and agents keep writing to the same path. Each
// earlier version is a frozen copy beside it, "Report v1.md", "Report v2.md", ..., which any tool can read or diff
// without the app. A Markdown version keeps its comments in its own "Report v1 - comments.md" (the same sidecar every
// Markdown document has, SPDFMacMarkdownComments.h), so opening v1 shows exactly the comments made on it; a PDF's
// comments are inside the PDF. Nothing here depends on Collection (Version History), which may be off, and whose
// cleanup may remove old versions to save space.
//
// Foundation and the core only, no AppKit: these are the hooks the command-line tool calls, and they are tested
// headlessly (SPDFMacDocumentVersionsTests.mm).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFDocumentVersion : NSObject
// 1-based. The current file has the highest number.
@property(nonatomic, readonly) NSInteger number;
@property(nonatomic, readonly, copy) NSString* path;
// A Markdown version's comments file when it exists on disk.
@property(nonatomic, readonly, copy, nullable) NSString* commentsPath;
// When this version's content was last written.
@property(nonatomic, readonly, copy) NSDate* date;
@property(nonatomic, readonly, getter=isCurrent) BOOL current;
// "v2"
@property(nonatomic, readonly, copy) NSString* name;
// {"number", "name", "path", "commentsPath" (when present), "date" (ISO 8601), "current"}, for JSON.
- (NSDictionary<NSString*, id>*)dictionaryRepresentation;
@end

// Which comments the new current version keeps. The frozen version always keeps all of them.
typedef NS_ENUM(NSInteger, SPDFDocumentVersionCarry) {
    SPDFDocumentVersionCarryNone = 0,
    SPDFDocumentVersionCarryOpen,  // the ones not marked resolved (the default)
    SPDFDocumentVersionCarryAll,
};

// The current file of the family `path` belongs to: "Report.md" for "Report v1.md" when "Report.md" exists, else
// `path` itself.
FOUNDATION_EXPORT NSString* SPDFDocumentVersionsCurrentPath(NSString* path);
// YES for "Report v1.md" when "Report.md" is beside it.
FOUNDATION_EXPORT BOOL SPDFDocumentVersionsIsFrozenPath(NSString* path);
// Every version, oldest first, the current file last. A document with no earlier versions lists itself as v1.
FOUNDATION_EXPORT NSArray<SPDFDocumentVersion*>* SPDFDocumentVersionsList(NSString* path);
// YES for a kind of document that can have versions (Markdown and PDF).
FOUNDATION_EXPORT BOOL SPDFDocumentVersionsSupportsPath(NSString* path);

// "New Version": freezes the current content as the next version number, with all its comments, and leaves the
// current file at its path for the next version to be written into. Returns the frozen version.
FOUNDATION_EXPORT SPDFDocumentVersion* _Nullable SPDFDocumentVersionsCreate(NSString* path, SPDFDocumentVersionCarry carry,
                                                                            NSError** error);
// Same, when the file was already overwritten: `previousContent` is a copy of what it held (written `previousDate`),
// and the comments beside the document are the ones made on that content. A Markdown document's open comments follow
// to the new content when `carry` says so, and are placed on it by their words and heading the next time it is shown
// (those whose words are gone are listed under "Unplaced"). A PDF's comments stay on the frozen version.
FOUNDATION_EXPORT SPDFDocumentVersion* _Nullable SPDFDocumentVersionsKeepPrevious(NSString* path,
                                                                                  NSString* previousContent,
                                                                                  NSDate* previousDate,
                                                                                  SPDFDocumentVersionCarry carry,
                                                                                  NSError** error);
// The document's comments: how many, and how many of those are not resolved. Markdown reads its comments file, a PDF
// its annotations.
FOUNDATION_EXPORT NSUInteger SPDFDocumentVersionsCommentCount(NSString* path, NSUInteger* _Nullable openCount);

NS_ASSUME_NONNULL_END
