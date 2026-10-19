#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacAITransport;
// No credential, document or network work until translateText is explicitly called.
@interface SPDFMacAITranslation : NSObject
- (instancetype)initWithTransport:(SPDFMacAITransport*)transport;
- (void)translateText:(NSString*)text language:(NSString*)language model:(NSString*)model key:(NSString*)key
    progress:(void (^)(NSUInteger completed, NSUInteger total))progress
    completion:(void (^)(NSString* translation, NSError* error))completion;
- (void)cancel;
@end
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMacAITranslationChunks(NSString* text, NSError** error);
FOUNDATION_EXPORT BOOL SPDFMacAITranslationAppendLine(NSMutableString* text, NSString* line, NSProgress* preparation, NSError** error);
