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
