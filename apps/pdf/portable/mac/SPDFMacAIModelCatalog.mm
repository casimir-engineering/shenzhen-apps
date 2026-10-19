#import "SPDFMacAIModelCatalog.h"
static NSError* Error(NSString* text) { return [NSError errorWithDomain:@"ShenzhenPDF.AI.Model" code:1 userInfo:@{NSLocalizedDescriptionKey:text}]; }
// The window the routed provider serves: the smaller of the model's and its top provider's, when given.
static NSUInteger ContextTokens(NSDictionary* model) {
    id provider=model[@"top_provider"]; NSUInteger tokens=0;
    id routed=[provider isKindOfClass:NSDictionary.class] ? provider[@"context_length"] : nil;
    NSArray* values=@[model[@"context_length"] ?: NSNull.null,routed ?: NSNull.null];
    for (id value in values) {
        if (![value isKindOfClass:NSNumber.class] || [value doubleValue]<1 || [value doubleValue]>100000000) continue;
        NSUInteger count=[value unsignedIntegerValue]; tokens=tokens ? MIN(tokens,count) : count;
    }
    return tokens;
}
NSArray<NSDictionary*>* SPDFMacAIModelsFromCatalog(NSData* data,NSError** error) {
    if(error)*error=nil;
    if (!data.length || data.length>8*1024*1024) { if(error)*error=Error(@"Model list unavailable. Try again."); return nil; }
    id value=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSArray* models=[value isKindOfClass:NSDictionary.class] ? value[@"data"] : nil;
    if (![models isKindOfClass:NSArray.class] || models.count>20000) { if(error)*error=Error(@"Invalid model list."); return nil; }
    NSMutableArray* result=[NSMutableArray array]; NSMutableSet* seen=[NSMutableSet set];
    NSCharacterSet* invalid=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.:~"].invertedSet;
    for (id model in models) {
        if (![model isKindOfClass:NSDictionary.class]) continue;
        NSString* identifier=model[@"id"]; NSArray* parameters=model[@"supported_parameters"];
        if (![identifier isKindOfClass:NSString.class] || !identifier.length || identifier.length>160 ||
            [identifier rangeOfCharacterFromSet:invalid].location!=NSNotFound || [seen containsObject:identifier] ||
            ![parameters isKindOfClass:NSArray.class] || ![parameters containsObject:@"tools"]) continue;
        NSString* name=[model[@"name"] isKindOfClass:NSString.class] ? model[@"name"] : identifier;
        if (name.length>200) name=identifier;
        id architecture=model[@"architecture"];
        id inputs=[architecture isKindOfClass:NSDictionary.class] ? architecture[@"input_modalities"] : nil;
        BOOL images=[inputs isKindOfClass:NSArray.class] && [inputs containsObject:@"image"];
        NSMutableDictionary* entry=[@{@"id":identifier,
            @"name":images ? [name stringByAppendingString:@" · Images"] : name,
            @"supportsImages":@(images),@"supported_parameters":@[@"tools"]} mutableCopy];
        NSUInteger context=ContextTokens(model);
        if (context) entry[@"contextTokens"]=@(context);
        [seen addObject:identifier]; [result addObject:entry];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return result;
}
NSDictionary* SPDFMacAIModelFromCatalog(NSData* data,NSString* identifier,NSError** error) {
    NSArray* models=SPDFMacAIModelsFromCatalog(data,error); if(!models)return nil;
    for(NSDictionary* model in models) if([model[@"id"] isEqual:identifier])return model;
    if(error)*error=Error(@"This model is unavailable or does not support document tools. Choose another model."); return nil;
}
NSURLSessionDataTask* SPDFMacAIFetchModels(void (^completion)(NSArray<NSDictionary*>*,NSError*)) {
    NSURLSessionConfiguration* config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest=20; config.timeoutIntervalForResource=25; config.URLCache=nil;
    config.HTTPCookieStorage=nil; config.URLCredentialStorage=nil;
    NSURLSession* session=[NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask* task=[session dataTaskWithURL:[NSURL URLWithString:@"https://openrouter.ai/api/v1/models"]
        completionHandler:^(NSData* data,NSURLResponse* response,NSError* error) {
            NSError* failure=error;
            if (!failure && (![response isKindOfClass:NSHTTPURLResponse.class] || [(NSHTTPURLResponse*)response statusCode]!=200))
                failure=Error(@"Model list unavailable. Try again.");
            NSArray* models=failure ? nil : SPDFMacAIModelsFromCatalog(data,&failure);
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(),^{ if(completion)completion(models,failure); });
        }];
    [task resume]; return task;
}
NSURLSessionDataTask* SPDFMacAIValidateModel(NSString* identifier,void (^completion)(NSDictionary*,NSError*)) {
    return SPDFMacAIFetchModels(^(NSArray<NSDictionary*>* models,NSError* error) {
        for(NSDictionary* model in models) if([model[@"id"] isEqual:identifier]) { if(completion)completion(model,nil);return; }
        if(completion)completion(nil,error ?: Error(@"This model is unavailable or does not support document tools. Choose another model."));
    });
}
