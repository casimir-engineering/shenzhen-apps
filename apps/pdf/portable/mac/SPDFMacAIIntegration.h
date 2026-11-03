#pragma once
#import "SPDFMacDelegatePrivate.h"
#import "friends/SPDFMacFriendsIntegration.h"
@interface ShenzhenMacDelegate (SPDFMacAIIntegration)
- (void)showAIChat:(id)sender;
- (void)showAIChats:(id)sender;
- (void)closeAIChat;
- (void)cancelAIChat;
- (BOOL)showAIChatSidebarIfSelected;
- (void)searchAIChats:(NSString*)query;
- (BOOL)isAIChatVisible;
- (CGFloat)aiChatReservedWidth;
- (NSWindow*)aiChatWindow;
- (void)preparePaletteForSearch;
// Opens the chat; typed Cmd+K text (nil for none) starts a new chat about it.
- (void)showAIChatForQuery:(NSString*)query;
// A request made elsewhere in the reader (Translate): sent at once in a new chat, shown beside the document while
// the keyboard stays where it was. NO when it could not start: the assistant is still answering (never interrupted),
// or setup is missing, which the chat says, with the request left in the composer.
- (BOOL)aiSendRequestInNewChat:(NSString*)text;
@end
// Chats that keep working while another one is shown (SPDFMacAIChatBackground.mm).
@class SPDFMacAIChatSession;
@interface ShenzhenMacDelegate (SPDFMacAIChatBackground)
// A chat session for this reader, wired to the panel, the chat list and Friends; nothing loaded in it yet.
- (SPDFMacAIChatSession*)aiMakeChatSession;
// A request of this reader is running, in the chat shown or in one shown before it.
- (BOOL)aiChatRequestRunning;
// YES, after the composer says which chat is still working, while a request runs in a chat that isn't shown: the
// reader runs one request at a time.
- (BOOL)aiRefuseWhileAnotherChatWorks;
// Shows a saved chat, or a new one for nil. A request running in the chat shown keeps going.
- (void)aiShowChat:(NSDictionary*)chat;
// The chat shown has been seen: its dot goes (when the panel is open and the app in front).
- (void)aiNoteChatViewed;
// The chats whose request is running now, for the chat list's "working".
- (NSSet<NSString*>*)aiWorkingChatIDs;
@end
@interface ShenzhenMacDelegate (SPDFMacAISettingsIntegration)
- (void)showUnifiedSettings:(id)sender;
- (void)showAIConnectionSettingsWithReason:(NSString*)reason;
- (void)showUnifiedSettingsAfterFirstPaint;
// The model list was downloaded once this session; a model missing from it is not looked up again.
- (BOOL)aiModelListLoaded;
- (void)aiModelListDidLoad:(NSArray<NSDictionary*>*)models;
@end
@interface ShenzhenMacDelegate (SPDFMacAIAnalysisIntegration)
- (void)aiDocumentDidOpen:(NSString*)path;
- (void)configureAIAnalysis:(id)settings;
- (void)configureAIAnalysisForMarkdownSession:(id)session path:(NSString*)path;
- (NSDictionary*)aiAnalysisForPath:(NSString*)path;
- (NSArray<NSDictionary*>*)aiGeneratedChapterRows;
- (void)appendAIGeneratedChaptersMatchingFilter:(NSString*)filter;
@end
