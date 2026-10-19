#pragma once
#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString* const SPDFMacAIDefaultModel;
FOUNDATION_EXPORT NSError* SPDFMacAIError(NSInteger code, NSString* message);
// The provider said the request is longer than the model can read at once.
static const NSInteger SPDFMacAIContextLengthErrorCode=11;
// Pure construction boundary, also used by offline tests. Never logs request contents.
FOUNDATION_EXPORT NSURLRequest* SPDFMacAIChatRequest(NSArray<NSDictionary*>* messages,
    NSArray<NSDictionary*>* tools, NSString* model, NSString* apiKey, NSError** error);

@interface SPDFMacAIRequestToken : NSObject
@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (void)cancel;
@end

@interface SPDFMacAITransport : NSObject
// Construction is inert. Session creation and credentials access occur only on explicit send.
- (instancetype)initWithConfiguration:(NSURLSessionConfiguration*)configuration;
- (SPDFMacAIRequestToken*)sendMessages:(NSArray<NSDictionary*>*)messages
    tools:(NSArray<NSDictionary*>*)tools model:(NSString*)model apiKey:(NSString*)apiKey
    completion:(void (^)(NSDictionary* assistantMessage, NSError* error))completion;
@end
