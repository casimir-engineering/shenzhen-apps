#import <Cocoa/Cocoa.h>

// The plain text a Markdown selection puts on the pasteboard.
//
// The canonical string already carries the document's structure: every block
// and every table row ends in "\n", every table cell begins with "\t", a code
// fence keeps its own line breaks. What it does not carry is the reader's
// expectation of how that structure reads as plain text -- and the
// whitespace-collapsing copy transform written for PDFs (whose line breaks are
// visual wraps) flattened all of it into one line. This builds the text a
// person expects:
//
//   - paragraphs, headings, code blocks and tables are separated by a blank
//     line; the lines of one block stay together;
//   - list items and table rows follow one another on consecutive lines;
//   - a table row is its cells joined by tabs, with no leading tab;
//   - `transform` (the collapse-whitespace preference) is applied INSIDE each
//     cell or line, so it can tidy runs of spaces but never a line or column
//     break;
//   - trailing spaces are dropped from every line; a selection that ends on a
//     line break keeps exactly that one break, one that stops mid-line none.
NS_ASSUME_NONNULL_BEGIN
NSString* SPDFMacMarkdownCopyText(NSAttributedString* canonical, NSRange range,
                                  NSString* _Nullable (^_Nullable transform)(NSString* text));
NS_ASSUME_NONNULL_END
