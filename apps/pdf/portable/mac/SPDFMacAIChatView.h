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
// Whether a document link in an answer can still be opened (SPDFMacAIAnswerPresentation); nil: every one can.
@property(nonatomic, copy) BOOL (^documentLinkAvailable)(NSURL* link);
// The cited page's thumbnail for an answer's source card, delivered on the main thread; nil: a document symbol.
@property(nonatomic, copy) void (^sourceThumbnail)(NSURL* link, NSInteger page, void (^done)(NSImage* image));
// Files and folders dropped on the chat or chosen with Attach files: they become this chat's (SPDFMacAIChatGrants.h).
// Returns what could not be attached, in words for the person, or nil. The view shows the chat's grants as chips
// above the composer; removing one calls removeAttachment with its id.
@property(nonatomic, copy) NSString* (^attachFiles)(NSArray<NSURL*>* URLs);
@property(nonatomic, copy) void (^removeAttachment)(NSString* identifier);
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
@interface SPDFMacAIChatView (Answers)
// An assistant answer, and under it the source card when one document backs it (SPDFMacAISourceCardView.h).
- (void)addAnswer:(NSString*)text;
// Draws the transcript again where it is, as when a cited document has been deleted.
- (void)redisplayAnswers;
@end

// SPDFMacAIChatAttachments.mm
@interface SPDFMacAIChatView (Attachments)
// Called once from -initWithFrame: after the composer row exists.
- (void)setUpAttachments;
// The chips: grants as SPDFMacAIChatSession -grants keeps them ({id, name, kind}).
- (void)showAttachments:(NSArray<NSDictionary*>*)grants;
// What Attach files and a drop do with these items (the suites and the offscreen harness call it, as a drop would).
- (BOOL)attachURLs:(NSArray<NSURL*>*)URLs;
@end
