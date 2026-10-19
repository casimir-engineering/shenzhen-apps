// Shenzhen Friends in the reader: the hooks the coordinator and its categories call.
//
// Each hook is one call at a place the reader already passes through, so the integration costs the capped files no
// lines (ShenzhenPDFMac.mm) or a handful (the others); the requests that place them are in the host adapter's
// report. This header includes only reader headers and Foundation-only Friends adapter headers, so reader files can
// import it without the Friends include path.
//
//   loadPersistentState        settings = [self friendsLaunchWithSettings:<settings.yaml>]   spawn when enabled
//   savePersistentState        writeStateObject:SPDFMacFriendsSettingsForSaving(@{...})       keep `friends`
//   after first paint          [self friendsAfterFirstPaint]                                   attach when enabled
//   the AI chat session        friendsChatTransport: / friendsChatTools: / friendsAttachChatView:session:
//   AI citations               if ([self friendsOpenCitation:URL chat:state.session.chat]) return;
//   Cmd+K                      friendsSearchPaletteQuery:... / friendsOpenPaletteResult:

#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacFriendsPalette.h"
#import "SPDFMacFriendsSettings.h"

@class SPDFMacAITransport, SPDFMacAIChatView;

NS_ASSUME_NONNULL_BEGIN

@interface ShenzhenMacDelegate (SPDFMacFriends)
// The settings.yaml dictionary loadPersistentState just parsed, returned unchanged. Disabled: nothing else happens.
// Enabled: one dispatch to a background queue that runs the client library's connect-or-spawn. Nothing waits.
- (nullable NSDictionary*)friendsLaunchWithSettings:(nullable NSDictionary*)settings;
// After the first frame: registers the Settings pane source and the cross-window observer, attaches when enabled
// (helper link, dropdown, title-bar button), and shows the Friends section of Settings once when it is due.
- (void)friendsAfterFirstPaint;
@end

@interface ShenzhenMacDelegate (SPDFMacFriendsSettingsIntroduction)
// The once-per-revision Friends introduction in Settings. YES when it showed it. Called by -friendsAfterFirstPaint
// and harmless to call again; it never shows before AI setup is complete, while another window holds the onboarding
// lock, or in restored and detached windows.
- (BOOL)friendsShowSettingsIntroductionIfNeeded;
@end

@interface ShenzhenMacDelegate (SPDFMacFriendsAssistant)
// The AI chat session's transport and tools, wrapped so Friends tools exist only for a request with an `@` scope.
- (SPDFMacAITransport*)friendsChatTransport:(SPDFMacAITransport*)transport;
- (id<SPDFMacAIChatTools>)friendsChatTools:(id<SPDFMacAIChatTools>)tools;
// Wraps the chat view's sendText and the session's changed (both already set) and adds the `@` picker and note.
- (void)friendsAttachChatView:(SPDFMacAIChatView*)view session:(SPDFMacAIChatSession*)session;
// Sends the composer's draft through `send` the way the chat view's own sendText does, chips and all: for the reader's
// other send paths (the Keychain "Authorize & send" retry), so a chip there opens its scope too.
- (BOOL)friendsSendDraft:(NSString*)draft using:(BOOL (^)(NSString* text))send;
// A Friends citation (shenzhenpdf-friends://message?...) that a Friends tool returned in `chat`: opens the dropdown
// at that message. A Friends link the tools never returned is refused like a document citation without evidence.
// NO for any other link, which the reader handles as before.
- (BOOL)friendsOpenCitation:(NSURL*)url chat:(nullable NSDictionary*)chat;
@end

@interface ShenzhenMacDelegate (SPDFMacFriendsPalette)
// Cmd+K: Friends messages matching `query`, delivered once on the main thread as palette rows (possibly none).
- (void)friendsSearchPaletteQuery:(NSString*)query progress:(NSProgress*)progress
                          publish:(void (^)(NSArray<NSDictionary*>* rows))publish;
// YES when `result` is a Friends row; it then opens the dropdown at the message.
- (BOOL)friendsOpenPaletteResult:(NSDictionary*)result;
@end

NS_ASSUME_NONNULL_END
