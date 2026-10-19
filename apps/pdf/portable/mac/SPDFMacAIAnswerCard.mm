#import "SPDFMacAIAnswerCard.h"
#import "SPDFMacAICitations.h"
NSDictionary* SPDFMacAIAnswerCardTool(void) {
    return @{@"type":@"function",@"function":@{@"name":@"present_answer",
        @"description":@"Finish with a prominent answer card when the supported answer is one number, range or a few words. Supply a short descriptive label, a brief value including units, and an exact retrieved citation URL. Include any essential qualification in the label/value; use prose instead if it cannot fit honestly. Call alone, after gathering evidence. This displays the final answer; no repeated prose is needed.",
        @"parameters":@{@"type":@"object",@"additionalProperties":@NO,
            @"properties":@{@"label":@{@"type":@"string",@"minLength":@1,@"maxLength":@80},
                @"value":@{@"type":@"string",@"minLength":@1,@"maxLength":@48},
                @"citation":@{@"type":@"string",@"description":@"Copy an exact citation URL returned by a document tool."}},
            @"required":@[@"label",@"value",@"citation"]}}};
}
NSDictionary* SPDFMacAIValidatedAnswerCard(NSDictionary* arguments,NSDictionary* chat) {
    if (![arguments isKindOfClass:NSDictionary.class] || arguments.count!=3) return nil;
    NSMutableDictionary* card=[NSMutableDictionary dictionary];
    for (NSString* key in @[@"label",@"value",@"citation"]) {
        id raw=arguments[key]; if (![raw isKindOfClass:NSString.class]) return nil;
        NSString* text=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSUInteger limit=[key isEqual:@"label"] ? 80 : [key isEqual:@"value"] ? 48 : 4096;
        if (!text.length || text.length>limit || [text rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound) return nil;
        card[key]=text;
    }
    if (!SPDFMacAIChatContainsCitation(chat,SPDFMacAICitationArguments([NSURL URLWithString:card[@"citation"]]))) return nil;
    return card;
}
NSString* SPDFMacAIAnswerCardText(NSDictionary* card) {
    return [NSString stringWithFormat:@"%@: %@\n[View evidence](%@)",card[@"label"],card[@"value"],card[@"citation"]];
}
