#import "SPDFMacAIChatBudget.h"
const NSUInteger SPDFMacAIDefaultContextTokens=128000;
const NSUInteger SPDFMacAIOutputReserveTokens=16384;
static const NSUInteger MinimumContextTokens=16384, MaximumContextTokens=1000000, ImageTokens=1600;
NSUInteger SPDFMacAIContextTokens(NSUInteger modelContextTokens) {
    if(!modelContextTokens) return SPDFMacAIDefaultContextTokens;
    return MIN(MaximumContextTokens,MAX(MinimumContextTokens,modelContextTokens));
}
NSUInteger SPDFMacAIInputBudget(NSUInteger contextTokens) {
    contextTokens=SPDFMacAIContextTokens(contextTokens);
    // Keep room for the reply (the transport may retry a cut-off reply with 16K tokens)
    // and for provider-side message framing that the estimate cannot see.
    return contextTokens-MIN(SPDFMacAIOutputReserveTokens,contextTokens/4)-MIN(2048UL,contextTokens/16);
}
NSUInteger SPDFMacAICompactionThreshold(NSUInteger inputBudget) { return inputBudget/4*3; }
NSUInteger SPDFMacAIToolResultLimit(NSUInteger inputBudget) {
    // About 40% of the budget (3 bytes per estimated token), so one result never fills a small window.
    return MIN(400000UL,MAX(16000UL,inputBudget*6/5));
}
NSUInteger SPDFMacAIEstimateTokens(id value) {
    NSUInteger bytes=0;
    if([value isKindOfClass:NSString.class]) bytes=[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    else if(value && [NSJSONSerialization isValidJSONObject:value])
        bytes=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil].length;
    // About 4 bytes per token for English and 3 for CJK text; stay on the safe side.
    return (bytes+2)/3+4;
}
NSUInteger SPDFMacAIEstimateMessageTokens(NSDictionary* message) {
    NSString* role=message[@"role"];
    if([role isEqual:@"preview"]) return ImageTokens;
    if([role isEqual:@"compaction"]) return SPDFMacAIEstimateTokens(message[@"summary"]);
    if(!message[@"answerCard"]) return SPDFMacAIEstimateTokens(message);
    NSMutableDictionary* wire=[message mutableCopy]; [wire removeObjectForKey:@"answerCard"];
    return SPDFMacAIEstimateTokens(wire);
}
NSUInteger SPDFMacAICompactionStart(NSArray<NSDictionary*>* messages) {
    for(NSUInteger i=messages.count;i>0;i--) if([messages[i-1][@"role"] isEqual:@"compaction"]) return i;
    return 0;
}
NSString* SPDFMacAICompactionSummary(NSArray<NSDictionary*>* messages) {
    NSUInteger start=SPDFMacAICompactionStart(messages);
    NSString* summary=start ? messages[start-1][@"summary"] : nil;
    return [summary isKindOfClass:NSString.class] && summary.length ? summary : nil;
}
NSUInteger SPDFMacAICompactionCut(NSArray<NSDictionary*>* messages, NSUInteger keepTokens) {
    NSUInteger start=SPDFMacAICompactionStart(messages), suffix=0;
    NSUInteger userCut=NSNotFound, stepCut=NSNotFound, latest=NSNotFound;
    for(NSUInteger index=messages.count;index>start+1;) {
        index--; suffix+=SPDFMacAIEstimateMessageTokens(messages[index]);
        NSString* role=messages[index][@"role"];
        BOOL user=[role isEqual:@"user"], step=[role isEqual:@"assistant"];
        if(!user && !step) continue;
        if(latest==NSNotFound) latest=index;
        if(suffix>keepTokens) continue;
        if(user) userCut=index; else stepCut=index;
    }
    if(userCut!=NSNotFound) return userCut;
    return stepCut!=NSNotFound ? stepCut : latest;
}
NSUInteger SPDFMacAIManualCompactionCut(NSArray<NSDictionary*>* messages) {
    NSUInteger start=SPDFMacAICompactionStart(messages);
    for(NSUInteger index=messages.count;index>start+1;) if([messages[--index][@"role"] isEqual:@"user"]) return index;
    return NSNotFound;
}
static NSString* Clip(id value, NSUInteger limit) {
    if(![value isKindOfClass:NSString.class]) return @"";
    NSString* text=value; if(text.length<=limit) return text;
    NSRange kept=[text rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,limit)];
    return [[text substringWithRange:kept] stringByAppendingFormat:@" …[%lu more characters omitted]",
        (unsigned long)(text.length-NSMaxRange(kept))];
}
NSString* SPDFMacAICompactionInput(NSArray<NSDictionary*>* messages, NSUInteger cut, NSUInteger maxTokens) {
    NSUInteger start=SPDFMacAICompactionStart(messages);
    if(cut==NSNotFound || cut<=start || cut>messages.count) return nil;
    NSString* previous=SPDFMacAICompactionSummary(messages);
    for(NSNumber* limit in @[@16000,@6000,@2000,@600,@200]) {
        NSUInteger toolLimit=limit.unsignedIntegerValue, textLimit=MAX(toolLimit*2,1000UL);
        NSMutableArray* items=[NSMutableArray array];
        for(NSUInteger i=start;i<cut;i++) {
            NSDictionary* message=messages[i]; NSString* role=message[@"role"];
            if([role isEqual:@"preview"]) {
                id preview=[message[@"preview"] isKindOfClass:NSDictionary.class] ? message[@"preview"] : @{};
                NSMutableDictionary* image=[@{@"role":@"page_image"} mutableCopy];
                for(NSString* key in @[@"caption",@"title",@"page",@"citation"])
                    if(preview[key]) image[key]=preview[key];
                if([NSJSONSerialization isValidJSONObject:image]) [items addObject:image];
                continue;
            }
            if(![@[@"user",@"assistant",@"tool"] containsObject:role]) continue;
            NSMutableDictionary* item=[@{@"role":role,
                @"content":Clip(message[@"content"],[role isEqual:@"tool"] ? toolLimit : textLimit)} mutableCopy];
            NSMutableArray* calls=[NSMutableArray array];
            for(NSDictionary* call in message[@"tool_calls"]) {
                NSDictionary* function=[call isKindOfClass:NSDictionary.class] ? call[@"function"] : nil;
                if(![function isKindOfClass:NSDictionary.class]) continue;
                [calls addObject:@{@"name":Clip(function[@"name"],80),
                    @"arguments":Clip(function[@"arguments"],MIN(toolLimit,2000UL))}];
            }
            if(calls.count) item[@"actions"]=calls;
            [items addObject:item];
        }
        NSMutableDictionary* input=[@{@"messages":items} mutableCopy];
        if(previous) input[@"previous_summary"]=previous;
        NSData* data=[NSJSONSerialization dataWithJSONObject:input
            options:NSJSONWritingWithoutEscapingSlashes error:nil];
        NSString* text=data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if(text && SPDFMacAIEstimateTokens(text)<=maxTokens) return text;
    }
    return nil;
}
static void CollectCitations(id value, NSMutableOrderedSet* citations, NSUInteger depth) {
    if(depth>20 || citations.count>=200) return;
    if([value isKindOfClass:NSDictionary.class]) {
        for(id key in value) {
            id item=value[key];
            if([key isEqual:@"citation"] && [item isKindOfClass:NSString.class] && [item length]<=2048)
                [citations addObject:item];
            else CollectCitations(item,citations,depth+1);
        }
    } else if([value isKindOfClass:NSArray.class]) for(id item in value) CollectCitations(item,citations,depth+1);
}
static NSDictionary* SummarizedToolResult(NSDictionary* message) {
    NSString* content=message[@"content"];
    if(![content isKindOfClass:NSString.class] || content.length<=600) return message;
    NSData* bytes=[content dataUsingEncoding:NSUTF8StringEncoding];
    id result=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    NSMutableOrderedSet* citations=[NSMutableOrderedSet orderedSet]; CollectCitations(result,citations,0);
    NSMutableDictionary* stub=[@{@"summarized":@YES,
        @"note":@"Full result removed after the conversation was summarized. Request it again if the detail is needed."}
        mutableCopy];
    NSMutableArray* evidence=[NSMutableArray array];
    for(NSString* citation in citations) [evidence addObject:@{@"citation":citation}];
    if(evidence.count) stub[@"evidence"]=evidence;
    NSData* data=[NSJSONSerialization dataWithJSONObject:stub options:NSJSONWritingWithoutEscapingSlashes error:nil];
    NSMutableDictionary* slim=[message mutableCopy];
    slim[@"content"]=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"summarized\":true}";
    return slim;
}
NSArray<NSDictionary*>* SPDFMacAICompactedMessages(NSArray<NSDictionary*>* messages, NSUInteger cut,
                                                   NSString* summary) {
    NSUInteger start=SPDFMacAICompactionStart(messages);
    if(cut==NSNotFound || cut<=start || cut>=messages.count || !summary.length) return nil;
    NSMutableArray* result=[NSMutableArray arrayWithCapacity:messages.count+1];
    for(NSUInteger i=0;i<cut;i++) {
        NSDictionary* message=messages[i];
        [result addObject:i>=start && [message[@"role"] isEqual:@"tool"] ? SummarizedToolResult(message) : message];
    }
    [result addObject:@{@"role":@"compaction",@"local":@YES,@"summary":summary}];
    [result addObjectsFromArray:[messages subarrayWithRange:NSMakeRange(cut,messages.count-cut)]];
    return result;
}
