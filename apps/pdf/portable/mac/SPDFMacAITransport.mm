#import "SPDFMacAITransport.h"
NSString* const SPDFMacAIDefaultModel=@"deepseek/deepseek-v4.1-flash";
// Wire ceilings sit above the session's token budget (at most ~3 MB of text for a
// 1M-token model); the session compacts long chats well before reaching them.
static const NSUInteger MaxWireMessages=4096, MaxTextBytes=8*1024*1024;
NSError* SPDFMacAIError(NSInteger code,NSString* message) {
    return [NSError errorWithDomain:@"SPDFMacAI" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL ValidModel(NSString* model) {
    return [model isKindOfClass:NSString.class] && model.length>0 && model.length<=160 &&
        [model rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location==NSNotFound;
}
static NSUInteger ImageBytes(NSArray* messages,NSUInteger* count) {
    NSUInteger bytes=0; if (count) *count=0;
    if (![messages isKindOfClass:NSArray.class]) return 0;
    for (NSDictionary* message in messages) {
        if (![message isKindOfClass:NSDictionary.class]) continue;
        if (![message[@"content"] isKindOfClass:NSArray.class]) continue;
        for (NSDictionary* part in message[@"content"]) {
            if (![part isKindOfClass:NSDictionary.class] || ![part[@"type"] isEqual:@"image_url"]) continue;
            if (count) ++*count;
            id image=part[@"image_url"]; id url=[image isKindOfClass:NSDictionary.class] ? image[@"url"] : nil;
            if (![url isKindOfClass:NSString.class] || ![url hasPrefix:@"data:image/png;base64,"]) return NSUIntegerMax;
            bytes += [url lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        }
    }
    return bytes;
}
NSURLRequest* SPDFMacAIChatRequest(NSArray<NSDictionary*>* messages,NSArray<NSDictionary*>* tools,
                                 NSString* model,NSString* apiKey,NSError** error) {
    if (error) *error=nil;
    if (![messages isKindOfClass:NSArray.class] || !messages.count || messages.count>MaxWireMessages ||
        (tools && (![tools isKindOfClass:NSArray.class] || tools.count>48)) || !ValidModel(model) ||
        ![apiKey isKindOfClass:NSString.class] || apiKey.length<12 || apiKey.length>512 ||
        [apiKey rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location!=NSNotFound) {
        if(error)*error=SPDFMacAIError(1,@"Connect OpenRouter and choose a valid model before sending."); return nil;
    }
    NSMutableDictionary* body=[@{@"model":model,@"messages":messages,@"stream":@NO,@"max_tokens":@8192,
        @"provider":@{@"data_collection":@"deny",@"zdr":@YES},@"user":@"shenzhen-pdf"} mutableCopy];
    if (tools.count) { body[@"tools"]=tools; body[@"tool_choice"]=@"auto"; }
    if (![NSJSONSerialization isValidJSONObject:body]) {
        if(error)*error=SPDFMacAIError(2,@"The conversation contains unsupported data."); return nil;
    }
    NSData* data=[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingWithoutEscapingSlashes error:nil];
    NSUInteger imageCount=0,imageBytes=ImageBytes(messages,&imageCount);
    if (!data || imageBytes==NSUIntegerMax || imageCount>4 || imageBytes>12*1024*1024+128 ||
        data.length>MaxTextBytes+12*1024*1024 || data.length-imageBytes>MaxTextBytes) {
        if(error)*error=SPDFMacAIError(3,@"This conversation is too large. Start a new chat or narrow the document context.");
        return nil;
    }
    NSMutableURLRequest* request=[NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:@"https://openrouter.ai/api/v1/chat/completions"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:90];
    request.HTTPMethod=@"POST"; request.HTTPBody=data;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:apiKey] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"Shenzhen PDF" forHTTPHeaderField:@"X-Title"];
    return request;
}
// Providers word this differently, but each names the context window or the token limit.
static BOOL ContextLengthExceeded(NSData* bytes) {
    id JSON=bytes.length ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    id error=[JSON isKindOfClass:NSDictionary.class] ? JSON[@"error"] : nil;
    if (![error isKindOfClass:NSDictionary.class]) return NO;
    NSMutableString* text=[NSMutableString string];
    id metadata=[error[@"metadata"] isKindOfClass:NSDictionary.class] ? error[@"metadata"] : nil;
    for (id value in @[error[@"message"] ?: @"",error[@"code"] ?: @"",error[@"type"] ?: @"",metadata[@"raw"] ?: @""])
        if ([value isKindOfClass:NSString.class] && [value length]<=65536) [text appendFormat:@" %@",value];
    NSString* lower=text.lowercaseString;
    for (NSString* phrase in @[@"context length",@"context_length",@"context window",@"maximum context",
        @"too many tokens",@"prompt is too long",@"input is too long",@"exceeds the maximum number of tokens"])
        if ([lower containsString:phrase]) return YES;
    return NO;
}
static NSError* ContextLengthError(void) {
    return SPDFMacAIError(SPDFMacAIContextLengthErrorCode,@"This conversation no longer fits the selected model. "
        "Start a new chat, or choose a model that can read more at once.");
}
@interface SPDFMacAIRequestToken ()
@property(nonatomic) NSURLSessionTask* task;
@property(nonatomic) BOOL cancelledValue;
@end
@implementation SPDFMacAIRequestToken
- (BOOL)isCancelled { @synchronized(self) { return _cancelledValue; } }
- (void)setTask:(NSURLSessionTask*)task { @synchronized(self) { _task=task; if(_cancelledValue)[task cancel]; } }
- (void)cancel { @synchronized(self) { _cancelledValue=YES; [_task cancel]; } }
@end
@interface SPDFMacAIResponse : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) NSMutableData* bytes;
@property(nonatomic) NSError* failure;
@property(nonatomic) NSInteger status;
@property(nonatomic) BOOL hasImages;
@property(nonatomic) SPDFMacAIRequestToken* token;
@property(nonatomic,copy) void (^completion)(NSDictionary*,NSError*);
@end
@implementation SPDFMacAIResponse
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task
 willPerformHTTPRedirection:(NSHTTPURLResponse*)response newRequest:(NSURLRequest*)request
 completionHandler:(void (^)(NSURLRequest*))completionHandler {
    (void)session;(void)task;(void)response;(void)request;
    // Never forward the credential or document to a redirected origin.
    completionHandler(nil);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task
 didReceiveResponse:(NSURLResponse*)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    (void)session;(void)task;
    self.status=[response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
    if (response.expectedContentLength>2*1024*1024) {
        self.failure=SPDFMacAIError(4,@"The model response exceeded the size limit."); completion(NSURLSessionResponseCancel);
    } else completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession*)session dataTask:(NSURLSessionDataTask*)task didReceiveData:(NSData*)data {
    (void)session;
    if(self.bytes.length+data.length>2*1024*1024) {
        self.failure=SPDFMacAIError(4,@"The model response exceeded the size limit."); [task cancel]; return;
    }
    [self.bytes appendData:data];
}
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
    (void)task;
    NSDictionary* message=nil; NSError* failure=self.failure;
    if(self.token.cancelled) failure=[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
    else if (!failure && error) failure=SPDFMacAIError(5,@"OpenRouter could not be reached. Check your connection and retry.");
    else if (!failure && (self.status<200 || self.status>=300)) {
        NSString* text=self.status==401 ? @"OpenRouter authorization expired. Connect again in Settings." :
            self.status==402 ? @"Your OpenRouter account needs credits." :
            self.status==429 ? @"OpenRouter is busy or your account limit was reached. Try again shortly." :
            @"OpenRouter could not complete the request with the required privacy settings. Try another model.";
        if (self.hasImages && (self.status==400 || self.status==404 || self.status==422))
            text=@"The selected model/provider could not accept page images with the required privacy settings. Choose an image-capable model in AI Settings and retry. Your selected model has not been changed.";
        failure=ContextLengthExceeded(self.bytes) ? ContextLengthError() : SPDFMacAIError(self.status,text);
    }
    if(!failure) {
        id JSON=[NSJSONSerialization JSONObjectWithData:self.bytes options:0 error:nil];
        id choices=[JSON isKindOfClass:NSDictionary.class] ? JSON[@"choices"] : nil;
        id first=[choices isKindOfClass:NSArray.class] && [choices count] ? choices[0] : nil;
        id candidate=[first isKindOfClass:NSDictionary.class] ? first[@"message"] : nil;
        NSString* reason=[first isKindOfClass:NSDictionary.class] && [first[@"finish_reason"] isKindOfClass:NSString.class] ? first[@"finish_reason"] : nil;
        if ([reason isEqual:@"length"]) {
            // Reasoning consumes the same output budget as the visible answer.
            // Never execute even apparently complete actions from a truncated batch.
            failure=SPDFMacAIError(7,@"The assistant's answer got cut off. Your chat is saved; try again, or ask for less at once.");
        } else if ([reason isEqual:@"content_filter"] ||
                   ([candidate isKindOfClass:NSDictionary.class] && [candidate[@"refusal"] isKindOfClass:NSString.class] && [candidate[@"refusal"] length])) {
            failure=SPDFMacAIError(9,@"The model declined this request. Your chat is saved; rephrase it or choose another model.");
        } else if ([JSON isKindOfClass:NSDictionary.class] && [JSON[@"error"] isKindOfClass:NSDictionary.class]) {
            failure=ContextLengthExceeded(self.bytes) ? ContextLengthError() : SPDFMacAIError(10,
                @"The model provider failed while generating the answer. "
                "Your chat is saved; retry or choose another model.");
        } else if ([candidate isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary* normalized=[candidate mutableCopy]; id content=candidate[@"content"];
            if ([content isKindOfClass:NSArray.class]) {
                NSMutableString* text=[NSMutableString string]; BOOL valid=YES;
                for (id part in content) {
                    if (![part isKindOfClass:NSDictionary.class] || ![part[@"type"] isEqual:@"text"] ||
                        ![part[@"text"] isKindOfClass:NSString.class]) { valid=NO; break; }
                    [text appendString:part[@"text"]];
                }
                content=valid ? text : nil; normalized[@"content"]=content ?: NSNull.null;
            }
            id calls=candidate[@"tool_calls"];
            BOOL text=[content isKindOfClass:NSString.class] &&
                [content stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length;
            BOOL actions=[calls isKindOfClass:NSArray.class] && [calls count]>0;
            if (calls==NSNull.null) [normalized removeObjectForKey:@"tool_calls"];
            if (text || actions) message=normalized;
            else failure=SPDFMacAIError(8,@"The assistant sent back an empty answer. Your chat is saved; try again or choose another model.");
        } else failure=SPDFMacAIError(6,@"The assistant's answer couldn't be read. Your chat is saved; try again or choose another model.");
    }
    void (^completion)(NSDictionary*,NSError*)=self.completion; self.completion=nil;
    self.token.task=nil; self.bytes=nil;
    [session finishTasksAndInvalidate];
    if(completion) dispatch_async(dispatch_get_main_queue(),^{
        if(self.token.cancelled) completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]);
        else completion(message,failure);
    });
}
@end
@implementation SPDFMacAITransport { NSURLSessionConfiguration* _configuration; }
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration*)configuration {
    if((self=[super init])) _configuration=[configuration copy]; return self;
}
- (SPDFMacAIRequestToken*)sendMessages:(NSArray<NSDictionary*>*)messages tools:(NSArray<NSDictionary*>*)tools
    model:(NSString*)model apiKey:(NSString*)apiKey completion:(void (^)(NSDictionary*,NSError*))completion {
    SPDFMacAIRequestToken* token=[SPDFMacAIRequestToken new];
    [self startMessages:messages tools:tools model:model apiKey:apiKey token:token recovery:NO completion:completion];
    return token;
}
- (void)startMessages:(NSArray*)messages tools:(NSArray*)tools model:(NSString*)model apiKey:(NSString*)apiKey
    token:(SPDFMacAIRequestToken*)token recovery:(BOOL)recovery completion:(void (^)(NSDictionary*,NSError*))completion {
    void (^start)(void)=^{
        if (token.cancelled) {
            dispatch_async(dispatch_get_main_queue(),^{ if(completion) completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); }); return;
        }
        NSError* error=nil;
        NSURLRequest* request=SPDFMacAIChatRequest(messages,tools,model,apiKey,&error);
        if(!request) {
            dispatch_async(dispatch_get_main_queue(),^{ if(completion) completion(nil,error); }); return;
        }
        if (recovery) {
            NSMutableURLRequest* expanded=[request mutableCopy];
            NSMutableDictionary* body=[[NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil] mutableCopy];
            body[@"max_tokens"]=@16384;
            expanded.HTTPBody=[NSJSONSerialization dataWithJSONObject:body options:NSJSONWritingWithoutEscapingSlashes error:nil];
            request=expanded;
        }
        if (token.cancelled) {
            dispatch_async(dispatch_get_main_queue(),^{ if(completion) completion(nil,[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]); }); return;
        }
        NSURLSessionConfiguration* configuration=_configuration ? [_configuration copy] : NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.URLCache=nil; configuration.HTTPCookieStorage=nil; configuration.URLCredentialStorage=nil;
        configuration.timeoutIntervalForRequest=90; configuration.timeoutIntervalForResource=120;
        SPDFMacAIResponse* response=[SPDFMacAIResponse new]; response.bytes=[NSMutableData data];
        response.token=token; response.hasImages=ImageBytes(messages,NULL)>0;
        response.completion=^(NSDictionary* reply,NSError* failure) {
            // Retry only a rejected, truncated response, once. No action from it
            // has reached the session, so recovery cannot replay completed edits.
            if (!token.cancelled && !recovery && [failure.domain isEqual:@"SPDFMacAI"] && failure.code==7)
                [self startMessages:messages tools:tools model:model apiKey:apiKey token:token recovery:YES completion:completion];
            else if (completion) completion(reply,failure);
        };
        NSURLSession* session=[NSURLSession sessionWithConfiguration:configuration delegate:response delegateQueue:nil];
        NSURLSessionDataTask* task=[session dataTaskWithRequest:request]; token.task=task; if (!token.cancelled) [task resume];
    };
    // Large multipart JSON is serialized off-main, along with the explicit request.
    if (ImageBytes(messages,NULL)) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),start);
    else start();
}
@end
