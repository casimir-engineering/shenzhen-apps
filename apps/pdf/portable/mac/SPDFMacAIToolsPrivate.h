#pragma once
#import "SPDFMacAITools.h"
@protocol SPDFMacAIActivityReporting;
@interface SPDFMacAITools ()
@property(nonatomic,weak) ShenzhenMacDelegate* reader;
@property(nonatomic,strong) NSOperationQueue* queue;
@property(nonatomic,strong) NSProgress* progress;
// The chat of the request being served (SPDFMacAIRequestContext.activity), for cards about saved documents.
@property(nonatomic,weak) id<SPDFMacAIActivityReporting> activity;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) NSMutableArray<NSDictionary*>* actions;
@property(nonatomic,strong) NSMutableArray<NSDictionary*>* redoActions;
- (void)performInternalTool:(NSString*)name arguments:(NSDictionary*)arguments completion:(void (^)(NSDictionary*))completion;
- (NSDictionary*)redoGuardForAction:(NSDictionary*)action;
- (void)retainUndoneAction:(NSDictionary*)action;
- (NSDictionary*)recordResult:(NSDictionary*)result before:(NSDictionary*)snapshot;
// organize_groups move-tab with paths (SPDFMacAIToolsGroups.mm).
- (void)moveTabs:(NSDictionary*)command completion:(void (^)(NSDictionary*))completion;
@end
