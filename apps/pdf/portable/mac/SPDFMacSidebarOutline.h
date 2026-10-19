#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The chapter list's hierarchy, derived from the flat rows the sidebar already
// builds. Both sources -- a PDF's outline and a Markdown document's headings --
// hand the sidebar rows carrying a `level`, and nothing else describes the
// nesting: a row's children are simply the rows after it with a deeper level,
// up to the next row at its own level or shallower.
//
// Kept pure (levels in, indexes out) so the collapse rules can be tested
// without a table view, a document, or a window.

// Does this row have at least one child? Only such a row draws a disclosure
// triangle.
BOOL spdf_sidebar_outline_has_children(NSArray<NSNumber*>* levels, NSUInteger index);

// A row's identity for remembering collapse state across launches: the ordinal
// of each ancestor among its siblings, joined by dots ("0.2.1"). Deliberately
// positional rather than title-based -- a document with two identically named
// sections still gets one key each. If the document is edited so its structure
// shifts, stale keys simply stop matching and those rows come back expanded,
// which is the documented default.
NSString* spdf_sidebar_outline_key(NSArray<NSNumber*>* levels, NSUInteger index);

// The rows to display: every row except those with a collapsed ancestor. A
// collapsed row is itself visible -- it is what the reader clicks to expand.
NSIndexSet* spdf_sidebar_outline_visible_indexes(NSArray<NSNumber*>* levels, NSSet<NSString*>* collapsedKeys);

// Every row that has children, by key: what "collapse all" stores. "Expand all"
// stores nothing, which is also the default for a document never touched.
NSSet<NSString*>* spdf_sidebar_outline_collapsible_keys(NSArray<NSNumber*>* levels);

NS_ASSUME_NONNULL_END
