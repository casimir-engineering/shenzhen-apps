#pragma once
// The Comments panel's rows for a PDF: cards (SPDFMacCommentCards.h) built from the loaded comments.
#import "SPDFMacDelegatePrivate.h"

@interface ShenzhenMacDelegate (SPDFMacCommentPanel)
// Appends the cards matching `filter` to the sidebar items, replies under the comment they answer; the empty-state row
// when none matches.
- (void)appendPDFCommentSidebarItemsMatchingFilter:(NSString*)filter;
// The row's item, with the passage it marks read from the page if this is the first time it is shown.
- (NSDictionary*)pdfCommentCardItemForRow:(NSInteger)row;
@end
