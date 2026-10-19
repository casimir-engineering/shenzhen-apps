#pragma once
#import <Cocoa/Cocoa.h>
// An NSTextView keeps answer text selectable and searchable with existing chat search.
@interface SPDFMacAIAnswerCardView : NSTextView
- (instancetype)initWithCard:(NSDictionary*)card width:(CGFloat)width openLink:(void (^)(NSURL*))openLink;
@end
