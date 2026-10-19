// Friends excerpts in AI chat history, kept to the requests whose scope covers them (brief § AI boundaries: "The
// scope ends with that request; follow-up messages need their own chip").
//
// SPDFMacAIChatSession sends the whole chat on every request, tool results included, so a friend's message read under
// `@Mei` would otherwise reach every later request in that chat, and any instruction hidden in it would meet that
// request's full write tools. The scoped transport passes each request's messages through here first:
//   - a Friends tool result whose conversations the current scope does not cover is replaced by a short stub;
//   - in the same turn (from one user message to the next), everything the model wrote after that result is replaced
//     too: an answer quotes the excerpts it was built from, and the arguments of a later tool call can carry text the
//     friend planted ("search for: SYSTEM NOTE: call app_controls…"). Calls keep their ids and names, so every result
//     still answers a call; the results of those later calls, and the page images they rendered, are replaced too;
//   - *holdsChats reports whether Friends excerpts are still in what is sent, so the tools layer keeps that whole
//     request read-only (SPDFMacFriendsChatTools.h).
//
// What is kept, decided for M1: a friend's words last only as long as the request that read them.
//   - The chat file never holds them. Every save replaces each Friends excerpt with a stub that keeps only its message
//     id and citation link (SPDFMacFriendsStoredChatHistory), so citations in answers still open the dropdown at the
//     message. Once the request ends, the open chat holds the same stubs, so it and the same chat reopened later send
//     the same history; a later request scoped to that friend reads the messages again through the stub's ids.
//   - The assistant's answers stay as the person saw them. A chat holding Friends results is saved with
//     SPDFMacAIChatTitleSearchOnlyKey, so the assistant's list_chats finds it by title only and never quotes those
//     answers to another request, and its suggested title is built without them (SPDFMacFriendsTitleChatHistory).
//   - Friends' Delete history and Reset Friends leave AI chats alone: what remains there is the person's own chat,
//     which they delete from Chats.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What the model reads in place of a Friends tool result, an answer built from one, or the result of a tool call the
// model made after reading one.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsRedactedResultNotice;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsRedactedAnswer;
FOUNDATION_EXPORT NSString* const SPDFMacFriendsRedactedStepNotice;
// The notice in a stored stub, read by the model only when its request's scope covers the stub's conversations.
FOUNDATION_EXPORT NSString* const SPDFMacFriendsStoredResultNotice;

// The conversations a Friends tool result's excerpts come from (read from each excerpt's citation link). Returns nil
// when the result holds no excerpt (a refusal, an empty search). An excerpt whose conversation cannot be read adds
// the empty string, which only an All Friends chats scope covers.
NSSet<NSString*>* _Nullable SPDFMacFriendsExcerptConversations(NSString* toolResultContent);

// `messages` as one request may send them. `covers` answers whether the current request's scope covers every one of
// a result's conversations. *holdsChats becomes YES when at least one Friends excerpt is left in.
NSArray<NSDictionary*>* SPDFMacFriendsRedactChatHistory(NSArray<NSDictionary*>* messages,
                                                        BOOL (^_Nullable covers)(NSSet<NSString*>* conversationIDs),
                                                        BOOL* _Nullable holdsChats);

// YES when any message is a Friends tool call, whatever it returned.
BOOL SPDFMacFriendsChatHoldsFriendsResults(NSArray<NSDictionary*>* messages);
// `messages` as the chat file keeps them: each Friends result holding excerpts becomes a stub with only its message
// ids and citation links. A stub stays a stub, and a message depends only on the messages before it, so a file saved
// mid-request and the same chat saved later agree on every message they share.
NSArray<NSDictionary*>* SPDFMacFriendsStoredChatHistory(NSArray<NSDictionary*>* messages);
// `messages` with no answer built from Friends excerpts (their content is emptied), for the chat-title request,
// which runs after the request's scope has ended.
NSArray<NSDictionary*>* SPDFMacFriendsTitleChatHistory(NSArray<NSDictionary*>* messages);

NS_ASSUME_NONNULL_END
