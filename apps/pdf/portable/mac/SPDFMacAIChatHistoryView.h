#pragma once
#import <Cocoa/Cocoa.h>
@interface SPDFMacAIChatHistoryView : NSView <NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate>
@property(nonatomic,copy) void (^action)(NSString*);
@property(nonatomic,copy) void (^searchChanged)(NSString*);
@property(nonatomic,readonly) NSSearchField* search;
@property(nonatomic,copy) void (^renameItem)(NSString* identifier, BOOL folder, NSString* name);
- (void)beginRenamingItem:(NSString*)identifier folder:(BOOL)folder;
- (void)displayFolders:(NSArray<NSDictionary*>*)folders;
- (void)displayChats:(NSArray<NSDictionary*>*)chats selectedID:(NSString*)identifier;
@end
