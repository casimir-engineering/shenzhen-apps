// The assistant's Annotate tools (SPDFMacAnnotateAgents.h): annotate_apply, annotate_state, annotate_look and
// canvas_new.
//
// WAVE 0 STUB (Agents implements): no tool is defined, so the assistant offers none yet.
#import "SPDFMacAnnotateAgents.h"

NSArray<NSDictionary*>* SPDFMacAIAnnotateToolDefinitions(void) {
    return @[];
}

@implementation SPDFMacAITools (Annotate)

- (BOOL)performAnnotateTool:(NSString*)name arguments:(NSDictionary*)arguments
                 completion:(void (^)(NSDictionary*))completion {
    (void)name; (void)arguments; (void)completion;
    return NO;
}

@end
