#pragma once
#import <Cocoa/Cocoa.h>
@class SPDFMacAIChatSession;
@interface SPDFMacAIChatView : NSView
@property(nonatomic, copy) BOOL (^sendText)(NSString*);
@property(nonatomic, copy) void (^action)(NSString*);
@property(nonatomic, copy) void (^openLink)(NSURL*);
// Save on an image in the chat (SPDFMacAIChatActivity.h). The reader saves it to Downloads and Collection
// (SPDFMacAIOutputs.h); nil: a save panel on the chat's window.
@property(nonatomic, copy) void (^saveImage)(NSString* path, NSString* caption);
// Replaces your message at `index` in the displayed chat and asks again from there. NO keeps the edit open.
@property(nonatomic, copy) BOOL (^editMessage)(NSUInteger index, NSString* text);
@property(nonatomic, readonly) NSTextView* composer;
// A strip across the top of the transcript, under the header, for something in effect for every message (Friends'
// "The assistant can read all your Friends chats" bar); nil removes it. The view sets its own height.
@property(nonatomic, strong) NSView* banner;
- (void)setChatSearchQuery:(NSString*)query;
- (void)showSubmissionError:(NSString*)message;
- (void)showSubmissionError:(NSString*)message recoveryAction:(NSString*)action;
- (void)refreshActivityFromSession:(SPDFMacAIChatSession*)session;
- (void)displaySession:(SPDFMacAIChatSession*)session;
- (void)displayChats:(NSArray<NSDictionary*>*)chats;
@end
