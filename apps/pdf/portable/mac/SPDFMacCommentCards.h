#pragma once
// The Comments panel's cards, for PDFs and Markdown alike: who wrote the comment and when, the passage it is on, the
// comment, replies indented under it, and Resolve / Edit / Delete on hover. Pure view code: no document reads.
//
// A card's height comes from the same layout that draws it (SPDFCommentCardLayout in the .mm), measured at the
// column's width, so wrapped text can never run into the next card.
//
// Sidebar item keys a card reads (kind "comment"): author, body (the comment), date (NSDate), quote (the passage),
// quoteLines (1 or 2, at most), quoteReserved (YES: the passage takes exactly quoteLines whatever its text, so one read
// after the card is measured cannot change its height), meta (a short note after the date, e.g. "p. 3"), level (1 for
// a reply), commentIndex (none: no Edit or Delete, as for a Markdown reply), resolved (YES: drawn muted, labelled
// "Resolved", and its hover button reopens it).
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// "Today 15:42", "Yesterday 09:10", "12 Oct 15:42", "12 Oct 2024": nil without a date.
FOUNDATION_EXPORT NSString* _Nullable SPDFCommentDateText(NSDate* _Nullable date, NSDate* now);
// "RC" for "Raphaël Casimir", "D" for "Daniel", "?" for no name.
FOUNDATION_EXPORT NSString* SPDFCommentInitials(NSString* _Nullable author);

FOUNDATION_EXPORT CGFloat SPDFCommentCardRowHeight(NSDictionary* item, CGFloat width);
// `target` receives resolveComment: / editComment: / deleteComment: from the hover buttons, with an NSMenuItem sender whose
// representedObject is the item's commentIndex (the commands' existing entry points).
FOUNDATION_EXPORT NSView* SPDFCommentCardCell(NSTableView* table, NSDictionary* item, id target);
// Comment rows draw their own card, so their row view paints no hover or selection fill of its own.
FOUNDATION_EXPORT NSTableRowView* SPDFCommentCardRowView(void);

// The panel with no card to show: "No comments yet. …", or, with a filter, that nothing matches it.
FOUNDATION_EXPORT NSDictionary* SPDFCommentsEmptyItem(NSString* _Nullable filter);
FOUNDATION_EXPORT CGFloat SPDFCommentsEmptyRowHeight(NSDictionary* item, CGFloat width);
FOUNDATION_EXPORT NSView* SPDFCommentsEmptyCell(NSTableView* table, NSDictionary* item);

NS_ASSUME_NONNULL_END
