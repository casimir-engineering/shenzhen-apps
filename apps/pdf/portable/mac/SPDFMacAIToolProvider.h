#pragma once
// The assistant's tool seam: how a capability (web search, Python, subagents, sending to friends, ...) joins the AI
// chat. Read this before adding a tool. Plan: portable/docs/plans/ai-agent-capabilities.md.
//
// 1. Write a provider. A class conforming to SPDFMacAIToolProvider below: it says which tools it can perform, which
//    of them it offers for a given request (empty when the request gives it nothing to do: no `@` chip, a switch
//    off in Settings), which ones only read, how to perform one, and how to stop. Tool results are JSON objects;
//    {"error": "..."} is a refusal the model reads, so write it for the model ("Ask the user to ..."). Text from a
//    document, a page or a friend is data: quote it inside result values, never let it choose what runs.
//
// 2. Register it. SPDFMacAIToolRegistry holds the providers of one chat. In the reader, add a category on
//    ShenzhenMacDelegate, in its own file, with one method named aiToolProvider<Name> that takes no argument and
//    returns the provider, or nil when it does not apply to this window:
//        @implementation ShenzhenMacDelegate (SPDFMacAIWebTools)
//        - (id<SPDFMacAIToolProvider>)aiToolProviderWeb { return [[SPDFMacAIWebToolProvider alloc] init...]; }
//        @end
//    SPDFMacAIIntegration finds every such method (SPDFMacAIDiscoverToolProviders) when the chat is first used,
//    never at launch, in name order after the reader's own tools; no shared file needs editing. Friends' provider
//    is registered this way (mac/friends/SPDFMacFriendsToolProviderIntegration.mm). Tests build a registry
//    directly with -registerProvider:.
//
// 3. Read the request (SPDFMacAIRequestContext.h), passed to every call:
//      text, chips          the person's message and its chips: Friends chips (scope ids and names), `#` document
//                           chips (file, opaque id, exact revision), dropped attachments. Fixed per request;
//                           nothing a tool returns can add one. `origin` says AI chat or a friend's `/`, and
//                           friendConversation names that friend for `/`. includesFriendsChats: a Friends chip or
//                           `/`, the one test for "a request that includes Friends chats" (§ 4).
//      settings             a snapshot of SPDFMacAISettings: aiWebSearchEnabled, aiPythonEnabled (the switch; also
//                           check your interpreter is installed), aiSubagentsEnabled, model, language.
//      budget               steps, tokens and tool calls left. Child budgets charge their parent.
//      cancellation         Stop. Check it, or -onCancel: to stop work; -cancel on the provider also comes.
//      activity             step rows, cards and images in the chat (SPDFMacAIChatActivity.h).
//      depth, session       0 for the person's request, 1 in a subagent. A subagent tool makes one child per task
//                           while it runs (SPDFMacAIChatSession.h):
//                               SPDFMacAIRequestBudget* b = [context.budget childBudgetWithSteps:4 tokens:t
//                                                                                          toolCalls:3];
//                               SPDFMacAIChatSession* task = [context.session
//                                   childSessionWithFilter:[SPDFMacAIToolFilter readOnlyFromProviders:ids]
//                                   budget:b error:&error];
//                               task.systemPrompt = ...; task.requestFinished = ^(state) { ... task.latestAnswer ... };
//                               [task sendTask:@"..." error:&error];
//                           Same model and key, read-only tools, nothing saved, Stop on the request stops it; a child
//                           cannot make children. Release children when the tool completes.
//
//    Lifecycle. -beginRequestWithContext:, -endRequestWithContext: and -cancel concern the person's request only:
//    -cancel comes while that request (or Undo/Redo) runs, never when a task's session is made or stops, nor for a
//    chat started or opened while idle. A subagent's calls arrive with a depth-1 context; stop its work through that
//    context's cancellation token, which a child stopping alone (a timeout) cancels without touching its parent's
//    request.
//
// 4. Show what happens. Through context.activity (every key is in SPDFMacAIChatActivity.h):
//        NSString* step = [context.activity beginStepWithTitle:@"Searching the web" detail:query
//                                                      options:SPDFMacAIActivityOptionsNone cancel:^{ ... }];
//        [context.activity updateEntry:step changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
//                                                     SPDFMacAIActivityTitleKey : @"Searched the web"}];
//    - Steps. The running title says what is happening ("Running Python"); give the finished step a past tense
//      ("Ran Python"), because the chat folds a run of finished steps into one line that lists their titles. A status
//      is optional: without one a step that ends well shows none, and others say "Stopped" or "Didn’t finish". A
//      status for work in progress ends in "…"; a stopped or failed step's status shows whole under its title. The
//      detail, shown expanded, is plain text; SPDFMacAIActivityDetailStyleKey @"code" or a language (@"python")
//      shows it in the chat's code box with Copy instead. Under it, SPDFMacAIActivityOutputKey is what the run
//      printed, in a code box captioned output, without colours, less one final line break, and
//      SPDFMacAIActivityNoteKey one sentence for the person in wrapping secondary text ("Charts aren’t shown…"):
//      keep both out of the detail, or they are coloured as code and cut off at the box's edge.
//      SPDFMacAIActivityLinksKey lists links as address strings or {url, title, host}; an expanded
//      step shows https ones one per line, the host beside the title, then http ones as plain text, with "Not a
//      secure page" on a line of its own under the title and host, never as links; other schemes are not shown.
//    - Cards. -addCard:options:handler: with title, Markdown body, attachments [{name, detail}], status, and
//      actions [{id, title, primary}], primary: YES on the one action the card waits for. A body the person approves
//      before it leaves the Mac takes SPDFMacAIActivityBodyStyleKey SPDFMacAIActivityBodyStyleLiteral, so the card
//      shows every character it will send, unrendered and wrapped, with characters that draw nothing as ‹U+200B›
//      (SPDFMacAIActivityVisibleText; refuse those before the card). It holds up to 32,768 bytes of UTF-8, Friends'
//      message limit; a longer one is refused, the card not added (a Markdown body is clipped at 8,000 characters).
//      The handler runs an action while the chat stays open in this window; a reopened chat shows the card without
//      buttons.
//    - While a tool runs, the chat's heading says "Working…" and, under it, what the tool does in the person's words,
//      from SPDFMacAIChatSession.runningTool (the tool's name) through SPDFChatRunningToolText: add your tool's words
//      there ("Searching the web…"), or the heading says nothing more. Never show a tool's name.
//    - Images. -addImageAtPath:caption:options: copies a PNG into the chat and shows it with Save; the caption, the
//      model's description of the image when there is one, is shown under it and names the saved file.
//    - Kept for this request only. In a request that includes Friends chats (context.includesFriendsChats), work on
//      text that may quote a friend leaves nothing in the chat file, in two parts:
//        * Its tool calls: answer YES from -isRequestOnlyTool:context:. The file keeps each call's tool name with
//          its arguments emptied, and a stub for its result that keeps only document citations, without their
//          search words, so answers citing them still open. The session asks when the model's turn arrives, before
//          it saves or runs the call (Stop or a crash can come before a result), so decide from the tool and the
//          request, never from what the call finds. Friends excerpts are stubbed by the Friends provider instead.
//        * Its rows: SPDFMacAIActivityRequestOnly. The file keeps the row's state, status and link addresses; its
//          title becomes SPDFMacAIActivityStoredTitleKey when given (give one whenever the title holds words the
//          model wrote or the request read: a helper's task, a file the code named; fixed words such as "Ran Python"
//          need none), and its detail, output, note or body SPDFMacAIActivityStoredNoticeKey; images are never kept.
//          Without a notice, a row linking to Friends messages says "The messages it read aren’t kept after this
//          request, because it included your Friends chats.", and any other the request-only reason below.
//      Once the request ends the open chat shows what the file keeps. Say the reason one way everywhere: "Not kept
//      after this request, because it included your Friends chats."
//    Steps still running when the request ends are stopped; cards keep their state and actions, so a queued send can
//    still be cancelled. Strings shown here are read by the person using the chat: say what happened to their
//    request, not how the tool works, with typographic apostrophes.
//
// 5. Render Markdown like the chat does. A card body is Markdown (unless literal, § 4) and the chat renders it. Chats
//    share one renderer (SPDFMacChatMarkdown.h): the reader's Markdown engine at chat scale, tables, code and
//    diagrams drawn as blocks, remote images waiting for Load image, links limited to https, document and Friends
//    citations. A view that can scroll a wide block sideways uses SPDFMacChatMarkdownView (as chat messages do); a
//    plain text view uses SPDFMacAIChatMarkdown(text, width, dark) (SPDFMacAIChatMarkdown.h), which wraps tables and
//    code to the width.
//
// Threading: everything here runs on the main thread, completions included; do slow work on your own queue.
#import <Foundation/Foundation.h>
#import "SPDFMacAIRequestContext.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFMacAIToolCompletion)(NSDictionary* result);

@protocol SPDFMacAIToolProvider <NSObject>
// Short, stable and unique in a registry: "reader", "friends", "web".
@property(nonatomic, readonly, copy) NSString* providerIdentifier;
// YES for every tool name this provider can ever perform, offered in this request or not. Routes calls; two
// providers may not claim one name.
- (BOOL)providesTool:(NSString*)name;
// OpenAI-style function definitions offered to the model for this request: a subset of what -providesTool:
// claims. A call to a tool not offered in the request is refused before it reaches -performTool:.
- (NSArray<NSDictionary*>*)toolDefinitionsForContext:(SPDFMacAIRequestContext*)context;
// YES when the tool only reads: no change to documents, the app, other people or anything outside the Mac beyond
// the request itself. Read-only sessions (subagents) and read-only requests (one holding Friends messages) offer
// and run only these.
- (BOOL)isReadOnlyTool:(NSString*)name;
// Completion runs exactly once, on the main thread.
- (void)performTool:(NSString*)name arguments:(NSDictionary*)arguments context:(SPDFMacAIRequestContext*)context
         completion:(SPDFMacAIToolCompletion)completion;
// Stop now: the request was stopped or abandoned. Pending completions may still run, with an error.
- (void)cancel;
@optional
// The request starts (before its first model turn) and ends (completed, failed, stopped or abandoned).
- (void)beginRequestWithContext:(SPDFMacAIRequestContext*)context;
- (void)endRequestWithContext:(SPDFMacAIRequestContext*)context;
// Non-nil while the request may only read; the text is the refusal the model reads for any other tool.
- (nullable NSString*)readOnlyReasonForContext:(SPDFMacAIRequestContext*)context;
// YES when calls to `name` in this request are kept for the request only (§ 4: usually
// context.includesFriendsChats, for work on text that may quote a friend). Asked before each call is saved or run.
- (BOOL)isRequestOnlyTool:(NSString*)name context:(SPDFMacAIRequestContext*)context;
// The refusal for one of this provider's tools that the request does not offer (default: a generic one).
- (nullable NSString*)unavailableMessageForTool:(NSString*)name context:(SPDFMacAIRequestContext*)context;
// The messages one model turn sends, after the session built them; return them changed to keep out what this
// request may not see (Friends excerpts outside its scope).
- (NSArray<NSDictionary*>*)messagesForRequest:(NSArray<NSDictionary*>*)messages
                                      context:(SPDFMacAIRequestContext*)context;
// Chips in the composer's text when the person sends (Friends `@` chips are attachments in that text).
- (NSArray<SPDFMacAIRequestChip*>*)requestChipsInComposerText:(NSAttributedString*)text;
// As SPDFMacAIChatTools (SPDFMacAIChatSession.h): what the chat file keeps, what a title may use, the reader
// context for the system prompt, and the reader's Undo and Redo.
- (NSDictionary*)chatForStorage:(NSDictionary*)chat;
- (NSArray<NSDictionary*>*)messagesForTitle:(NSArray<NSDictionary*>*)messages;
- (nullable NSDictionary*)conversationContext;
@property(nonatomic, readonly) BOOL canUndo;
@property(nonatomic, readonly) BOOL canRedo;
- (BOOL)undoLastAction:(NSError**)error;
- (void)undoWithCompletion:(void (^)(NSDictionary*))completion;
- (void)redoWithCompletion:(void (^)(NSDictionary*))completion;
@end

NS_ASSUME_NONNULL_END
