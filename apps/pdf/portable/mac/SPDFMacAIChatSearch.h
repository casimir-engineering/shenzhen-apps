#pragma once
#import <Cocoa/Cocoa.h>
// Local rendered-text navigation. No provider request or stored-chat mutation.
@interface SPDFMacAIChatSearch : NSObject
- (instancetype)initWithScrollView:(NSScrollView*)scroll messages:(NSStackView*)messages;
- (void)updateQuery:(NSString*)query;
- (void)moveBy:(NSInteger)delta;
@end
FOUNDATION_EXPORT BOOL SPDFMacAIChatHasTextMatch(NSDictionary* chat,NSString* query);
