#pragma once
#import <Cocoa/Cocoa.h>
@interface SPDFGroupManagementController : NSViewController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate>
@property(nonatomic, copy) void (^actionHandler)(NSString* action, NSString* groupID, NSString* value);
@property(nonatomic, copy) NSMenu* (^documentMenuProvider)(NSString* path, NSString* groupID);
@property(nonatomic, copy) void (^stateHandler)(NSDictionary* state);
- (void)updateGroups:(NSArray<NSDictionary*>*)groups state:(NSDictionary*)state;
- (NSDictionary*)viewState;
- (void)revealSelectedDocument;
@end
