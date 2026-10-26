#pragma once
#import <Cocoa/Cocoa.h>
// The card under an answer that one document backs (SPDFMacAIAnswerPresentation): the cited page's thumbnail, the
// document's title and the page, in the Collection's row style. A click anywhere on it opens the document at that
// page, through the same path as the answer's own link.
@interface SPDFMacAISourceCardView : NSView
- (instancetype)initWithSource:(NSDictionary*)source open:(void (^)(NSURL* link))open;
@property(nonatomic, strong) NSImage* thumbnail;  // nil: a document symbol
@property(nonatomic, readonly) NSURL* link;
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly) NSInteger page;
- (void)open;
@end
