#pragma once
#import "SPDFMacAITools.h"
@interface SPDFMacAITools ()
@property(nonatomic,weak) ShenzhenMacDelegate* reader;
@property(nonatomic,strong) NSOperationQueue* queue;
@property(nonatomic,strong) NSProgress* progress;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) NSMutableArray<NSDictionary*>* actions;
@property(nonatomic,strong) NSMutableArray<NSDictionary*>* redoActions;
- (void)performInternalTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion;
- (NSDictionary*)redoGuardForAction:(NSDictionary*)action;
- (void)retainUndoneAction:(NSDictionary*)action;
@end
