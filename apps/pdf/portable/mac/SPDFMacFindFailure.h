#pragma once
#import "SPDFMacDelegatePrivate.h"
@interface ShenzhenMacDelegate (SPDFMacFindFailure)
@property(nonatomic,copy) NSString* findFailureMessage;
// Matches found so far while a search runs; the counter shows "N matches…".
@property(nonatomic) NSUInteger findLiveMatchCount;
// How much of the document the running search has covered, drawn as a thin
// line under the search field. 1 (or more) hides it.
- (void)setFindProgress:(double)fraction;
@end
