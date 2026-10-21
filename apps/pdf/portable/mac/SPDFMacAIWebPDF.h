#pragma once
// PDFs that open_page downloads (datasheets, most often). The bytes go to a file of their own in this Mac's temporary
// folder, never ~/Downloads, and their text comes from the reader's own engine (the core's
// spdf_extract_page_text_lines, as read_pages reads a document), a range of pages at a time, so a long datasheet is
// read in parts. Each file is named by an opaque identifier: the chat's "Open in ShenzhenPDF" link carries that, never
// a path, and opens the file through the reader's normal open path (SPDFMacAIIntegration -aiOpenCitation:).
// Pure apart from the files under the folder it is given. Any thread; one document is read by one call at a time.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDFMacAIWebDocument : NSObject
@property(nonatomic, readonly, copy) NSString* identifier; // opaque: a UUID naming the file's folder
@property(nonatomic, readonly) NSURL* fileURL;
@property(nonatomic, readonly) NSURL* sourceURL;            // where the PDF came from, after any redirects
@property(nonatomic, readonly) NSUInteger pageCount;
@property(nonatomic, readonly, copy) NSString* title;       // its own title, else its file name
@property(nonatomic, readonly) NSUInteger byteCount;
@end

// NSTemporaryDirectory()/ShenzhenPDF-AI-Web: per user, cleaned by macOS, outside the person's own folders.
NSURL* SPDFMacAIWebDocumentDefaultFolder(void);

// Writes `data` (a whole PDF) to `folder`/<new identifier>/<name from the address>.pdf and opens it once to count its
// pages. nil and an error (LockedDocument, BadDocument) when the engine cannot read it; the file is then removed.
// Folders from earlier downloads older than a week are removed first, so the folder never grows without end.
SPDFMacAIWebDocument* _Nullable SPDFMacAIWebStoreDocument(NSData* data, NSURL* sourceURL, NSURL* folder,
                                                          NSError** error);

// Pages from `firstPage` (one-based) on, at most `count`, until about `maxBytes` of UTF-8 text:
// {pages: [{page, text, scanned?}], next_page?, truncated?}. A page alone over maxBytes is cut and marked truncated.
NSDictionary* _Nullable SPDFMacAIWebDocumentPages(SPDFMacAIWebDocument* document, NSUInteger firstPage,
                                                  NSUInteger count, NSUInteger maxBytes, NSError** error);

// The text of one page's lines in reading order, [{text, x0, y0, x1, y1}] in page space, `pageWidth` wide. Table rows
// stay rows: short lines that share a baseline are one line, left to right, cells joined by " | ", where the engine
// lists a table column by column.
NSString* SPDFMacAIWebPageLinesText(NSArray<NSDictionary*>* lines, double pageWidth);

// spdf-ai://web-document?id=<identifier>&web=<source>: the link a step row shows as "Open in ShenzhenPDF".
NSURL* SPDFMacAIWebDocumentLink(SPDFMacAIWebDocument* document);
BOOL SPDFMacAIWebIsDocumentLink(NSURL* _Nullable URL);
// The file a link names, when it is still in `folder`; nil for anything else (an identifier that is not a UUID, a
// folder with no PDF, a link that is not one of these).
NSURL* _Nullable SPDFMacAIWebDocumentFileForLink(NSURL* link, NSURL* folder);
// The https address the PDF came from, to offer when the file is gone.
NSURL* _Nullable SPDFMacAIWebDocumentSourceForLink(NSURL* link);

NS_ASSUME_NONNULL_END
