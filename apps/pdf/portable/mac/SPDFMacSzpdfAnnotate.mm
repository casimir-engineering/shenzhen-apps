// `szpdf annotate`, `szpdf canvas`, and the reader's side of them (SPDFMacAnnotateAgents.h).
//
// WAVE 0 STUB (Agents implements): the commands answer not_implemented; nothing is registered with szpdf yet.
#import "SPDFMacAnnotateAgents.h"

#import "SPDFMacSzpdfInternal.h"

int SPDFMacSzpdfAnnotate(NSDictionary* command) {
    (void)command;
    return SPDFMacSzpdfFinish(SPDFMacSzpdfFailure(@"not_implemented", @"Annotate is not built yet.", nil));
}

int SPDFMacSzpdfCanvas(NSDictionary* command) {
    (void)command;
    return SPDFMacSzpdfFinish(SPDFMacSzpdfFailure(@"not_implemented", @"Annotate is not built yet.", nil));
}

NSArray<NSDictionary*>* SPDFMacSzpdfAnnotateCommandRows(void) {
    return @[];
}

@implementation ShenzhenMacDelegate (SPDFMacAnnotateAgentServer)

+ (void)agentAnnotate:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                reply:(void (^)(NSDictionary*))reply {
    (void)request; (void)readers;
    reply(SPDFMacSzpdfFailure(@"not_implemented", @"Annotate is not built yet.", nil));
}

+ (void)agentCanvasNew:(NSDictionary*)request readers:(NSArray<ShenzhenMacDelegate*>*)readers
                 reply:(void (^)(NSDictionary*))reply {
    (void)request; (void)readers;
    reply(SPDFMacSzpdfFailure(@"not_implemented", @"Annotate is not built yet.", nil));
}

@end
