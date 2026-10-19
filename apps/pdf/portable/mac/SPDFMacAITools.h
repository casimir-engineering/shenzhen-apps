#pragma once
#import <Foundation/Foundation.h>
#import "SPDFMacAIChatSession.h"
@class ShenzhenMacDelegate;
NS_ASSUME_NONNULL_BEGIN
NSString* SPDFAIDocumentIdentifier(NSString* path);
@interface SPDFMacAITools : NSObject <SPDFMacAIChatTools>
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion;
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion;
- (instancetype)initWithReader:(ShenzhenMacDelegate*)reader;
+ (NSArray<NSDictionary*>*)toolDefinitions;
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments
        completion:(void (^)(NSDictionary* result))completion;
- (void)cancel;
- (BOOL)undoLastAction:(NSError**)error;
@end
NS_ASSUME_NONNULL_END
