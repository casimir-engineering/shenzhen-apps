#pragma once
#import "SPDFMacAITools.h"
NSArray* SPDFChatOrganizationToolDefinitions(void);
@interface SPDFMacAITools (ChatOrganization)
- (void)performChatOrganizationTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion;
- (void)swapChatOrganizationAction:(BOOL)redo completion:(void (^)(NSDictionary*))completion;
@end
