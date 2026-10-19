#pragma once
#import <Foundation/Foundation.h>
// Disk access is explicit. Each chat has its own atomic file, so different windows
// cannot overwrite unrelated conversations. Credentials never enter this store.

// YES on a chat whose answers quote material the assistant may read only in a request the person brought it into
// (Friends chats, mac/friends/SPDFMacFriendsChatHistory.h). The assistant's own chat search then matches such a chat
// by its title alone, so another request never receives those answers as snippets.
FOUNDATION_EXPORT NSString* const SPDFMacAIChatTitleSearchOnlyKey;

@interface SPDFMacAIChatStore : NSObject
- (instancetype)initWithDirectory:(NSURL*)directory;
+ (NSURL*)defaultDirectory;
- (NSArray<NSDictionary*>*)chats;
// The person's own chat search: titles, then what each message says.
- (NSArray<NSDictionary*>*)chatsMatchingQuery:(NSString*)query;
// forAssistant: the list_chats tool's search, which honours SPDFMacAIChatTitleSearchOnlyKey.
- (NSArray<NSDictionary*>*)chatsMatchingQuery:(NSString*)query forAssistant:(BOOL)forAssistant;
- (NSDictionary*)chatWithID:(NSString*)identifier;
- (BOOL)saveChat:(NSDictionary*)chat error:(NSError**)error;
// Rewrites earlier messages (an edited question or a compacted history). Refused when the
// saved chat is not what the caller last saw, so another window's answer is never erased.
- (BOOL)saveChat:(NSDictionary*)chat replacingMessages:(NSArray*)expected error:(NSError**)error;
- (BOOL)deleteChatWithID:(NSString*)identifier error:(NSError**)error;
- (BOOL)deleteAll:(NSError**)error;
// Organization is stored separately: stale conversation saves cannot undo a rename or move.
- (NSArray<NSDictionary*>*)folders;
- (NSString*)createFolderNamed:(NSString*)name error:(NSError**)error;
- (BOOL)renameFolder:(NSString*)identifier name:(NSString*)name error:(NSError**)error;
- (BOOL)removeFolder:(NSString*)identifier error:(NSError**)error;
- (BOOL)setFolder:(NSString*)folderID collapsed:(BOOL)collapsed error:(NSError**)error;
- (BOOL)moveChat:(NSString*)identifier toFolder:(NSString*)folderID error:(NSError**)error;
- (BOOL)renameChat:(NSString*)identifier title:(NSString*)title error:(NSError**)error;
- (BOOL)shouldSuggestTitleForChatID:(NSString*)identifier;
- (BOOL)setSuggestedTitle:(NSString*)title forChatID:(NSString*)identifier error:(NSError**)error;
- (NSDictionary*)organizationSnapshot;
- (NSDictionary*)organizeChats:(NSArray*)operations expectedRevision:(NSString*)revision progress:(NSProgress*)progress error:(NSError**)error;
- (NSDictionary*)swapOrganizationReceipt:(NSDictionary*)receipt progress:(NSProgress*)progress error:(NSError**)error;
- (NSDictionary*)savePreview:(NSDictionary*)preview chatID:(NSString*)identifier;
- (NSData*)previewData:(NSDictionary*)preview chatID:(NSString*)identifier;
// Removes the chat's saved page pictures that none of its saved messages shows any more,
// after an edit discards the replies that showed them.
- (void)removeUnusedPreviewsForChatID:(NSString*)identifier;
// Removes a tool's temporary image folder (NSTemporaryDirectory()/ShenzhenPDF-AI-<UUID>/ holding render_page's
// page.png or current_view's viewport.png) and nothing else.
+ (void)discardTemporaryPreview:(NSDictionary*)preview;
@end

// What the chat file keeps of tool calls made for one request only (-[SPDFMacAIToolProvider isRequestOnlyTool:
// context:]): `messages` with each listed call's arguments emptied and its result replaced by a notice the model
// reads, keeping only the document citations the result held, without their search words, so links in answers that
// cite them still open. A stub stubs to itself, so saving it again is never a conflict.
NSArray<NSDictionary*>* SPDFMacAIChatStoredRequestOnlyMessages(NSArray<NSDictionary*>* messages,
                                                               NSSet<NSString*>* callIDs);
FOUNDATION_EXPORT NSString* const SPDFMacAIChatRequestOnlyNotice;
