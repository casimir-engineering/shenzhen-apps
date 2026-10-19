#import "SPDFMacAIChatStore.h"

NSString* const SPDFMacAIChatRequestOnlyNotice=@"Not kept: this call belonged to a request that included the user's "
    "Friends chats, so its input and result were kept for that request only. Run it again if it is needed.";
// Document citations in a result, minus their `query` (search words, which may quote a friend). Keys are walked in
// sorted order so the same result always gives the same stub, which the store's conflict check relies on.
static void CollectCitations(id value, NSMutableArray* found, NSUInteger depth) {
    if (depth>20 || found.count>=32) return;
    if ([value isKindOfClass:NSArray.class]) { for (id item in value) CollectCitations(item,found,depth+1); return; }
    if (![value isKindOfClass:NSDictionary.class]) return;
    for (id key in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id item=value[key];
        if ([key isEqual:@"citation"] && [item isKindOfClass:NSString.class] &&
            [item hasPrefix:@"spdf-ai://document?"]) {
            NSURLComponents* link=[NSURLComponents componentsWithString:item];
            link.queryItems=[link.queryItems filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"name != %@",@"query"]];
            NSDictionary* source=link.string ? @{@"citation":link.string} : nil;
            if (source && ![found containsObject:source]) [found addObject:source];
        } else CollectCitations(item,found,depth+1);
    }
}
static NSString* RequestOnlyResult(NSString* content) {
    NSData* data=[content dataUsingEncoding:NSUTF8StringEncoding];
    id result=data.length<=100000 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([result isKindOfClass:NSDictionary.class] && [result[@"notice"] isEqual:SPDFMacAIChatRequestOnlyNotice])
        return content;
    NSMutableArray* sources=[NSMutableArray array]; CollectCitations(result,sources,0);
    NSDictionary* stub=sources.count ? @{@"notice":SPDFMacAIChatRequestOnlyNotice,@"sources":sources} :
        @{@"notice":SPDFMacAIChatRequestOnlyNotice};
    NSData* stored=[NSJSONSerialization dataWithJSONObject:stub options:NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:stored encoding:NSUTF8StringEncoding];
}
NSArray<NSDictionary*>* SPDFMacAIChatStoredRequestOnlyMessages(NSArray<NSDictionary*>* messages,
                                                               NSSet<NSString*>* callIDs) {
    if (!callIDs.count) return messages;
    NSMutableArray* stored=[NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary* message in messages) {
        NSMutableDictionary* stub=[message mutableCopy];
        if ([message[@"role"] isEqual:@"tool"] && [message[@"content"] isKindOfClass:NSString.class] &&
            [callIDs containsObject:message[@"tool_call_id"] ?: @""])
            stub[@"content"]=RequestOnlyResult(message[@"content"]);
        if ([message[@"tool_calls"] isKindOfClass:NSArray.class]) {
            NSMutableArray* calls=[NSMutableArray array];
            for (NSDictionary* call in message[@"tool_calls"]) {
                if (![call isKindOfClass:NSDictionary.class] || ![callIDs containsObject:call[@"id"] ?: @""] ||
                    ![call[@"function"] isKindOfClass:NSDictionary.class]) { [calls addObject:call]; continue; }
                // The name stays, so the history still says which tool ran; what it was given does not.
                NSMutableDictionary* function=[call[@"function"] mutableCopy]; function[@"arguments"]=@"{}";
                NSMutableDictionary* emptied=[call mutableCopy]; emptied[@"function"]=function;
                [calls addObject:emptied];
            }
            stub[@"tool_calls"]=calls;
        }
        [stored addObject:[stub isEqual:message] ? message : [stub copy]];
    }
    return stored;
}
