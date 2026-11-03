// Chats keep working while another one is shown. Showing another chat, or a new one, while the assistant is still
// answering used to load it into the same session, which stopped that answer without a word. Now the chat that is
// working keeps its own session (SPDFReaderAIState.background) until it is done; the chat list says "working" beside
// it, and a dot marks an answer that arrived while the person wasn't looking (another chat shown, the chat panel
// closed, or ShenzhenPDF not in front), until they look at that chat.
//
// The reader still runs one request at a time: Friends chats are scoped per request by one gate for the reader
// (mac/friends/SPDFMacFriendsChatScopeGate), so a second request at once could close or widen the first one's scope.
// A message sent in another chat meanwhile is refused with the working chat's name, and kept in the composer.
#import "SPDFMacAIReaderAIState.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacAIChatDock.h"
#import "SPDFMacAIChatHistoryView.h"

@implementation ShenzhenMacDelegate (SPDFMacAIChatBackground)

- (SPDFMacAIChatSession*)aiMakeChatSession {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:[self aiChatTransport]
        registry:state.registry store:state.store];
    __weak ShenzhenMacDelegate* owner=self; __weak SPDFReaderAIState* weakState=state;
    __weak SPDFMacAIChatSession* weakSession=session;
    session.changed=^{
        SPDFReaderAIState* live=weakState; SPDFMacAIChatSession* changed=weakSession;
        [owner searchAIChats:live.historyView.search.stringValue ?: @""];
        if (changed && changed==live.session) {
            [live.view refreshActivityFromSession:changed]; [live.view displaySession:changed];
        } else if (changed==live.background && !changed.running && live.waitingNotice) {
            live.waitingNotice=NO; [live.view showSubmissionError:nil];
        }
    };
    session.requestFinished=^(SPDFMacAIChatActivityState finished) {
        [owner aiChatSession:weakSession finished:finished];
    };
    [self friendsAttachChatSession:session];
    return session;
}

- (BOOL)aiChatRequestRunning {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    return state.session.running || state.background.running;
}

- (NSSet<NSString*>*)aiWorkingChatIDs {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    NSMutableSet* working=[NSMutableSet set];
    for (SPDFMacAIChatSession* session in @[state.session ?: NSNull.null, state.background ?: NSNull.null])
        if ([session isKindOfClass:SPDFMacAIChatSession.class] && session.running && session.chat[@"id"])
            [working addObject:session.chat[@"id"]];
    return working;
}

- (BOOL)aiRefuseWhileAnotherChatWorks {
    SPDFReaderAIState* state=[self readerAIState];
    SPDFMacAIChatSession* other=state.background;
    if (!other.running) return NO;
    NSString* identifier=other.chat[@"id"];
    NSString* title=[state.store chatWithID:identifier][@"title"] ?: other.chat[@"title"];
    if (title.length>40) title=[[title substringToIndex:[title rangeOfComposedCharacterSequenceAtIndex:39].location]
        stringByAppendingString:@"…"];
    NSString* name=title.length ? [NSString stringWithFormat:@"“%@”",title] : @"Another chat";
    state.waitingNotice=YES;
    [state.view showSubmissionError:[NSString stringWithFormat:@"%@ is still working. Send this when it’s done; your "
        "message is kept.",name] recoveryAction:[@"load:" stringByAppendingString:identifier]];
    return YES;
}

- (void)aiShowChat:(NSDictionary*)chat {
    SPDFReaderAIState* state=[self readerAIState];
    NSString* identifier=chat[@"id"];
    if (state.waitingNotice) { state.waitingNotice=NO; [state.view showSubmissionError:nil]; }
    if (state.session.running) {
        // Its answer keeps coming: the chat list says "working", then shows the dot.
        state.background=state.session; state.session=[self aiMakeChatSession];
    } else if (state.background.running && identifier && [state.background.chat[@"id"] isEqual:identifier]) {
        state.session=state.background; state.background=nil;
        [state.view refreshActivityFromSession:state.session];
        return;
    } else if (!state.background.running) {
        state.background=nil;
    }
    if (chat) [state.session loadChat:chat]; else [state.session newChat];
}

// Seen: the chat shown, with the panel open, while ShenzhenPDF is in front and its window isn't in the Dock.
- (BOOL)aiChatInView:(SPDFMacAIChatSession*)session {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    return session && session==state.session && state.dock.visible && NSApp.isActive && !_window.miniaturized;
}

- (void)aiChatSession:(SPDFMacAIChatSession*)session finished:(SPDFMacAIChatActivityState)finished {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    NSDictionary* last=[session.chat[@"messages"] lastObject];
    BOOL answered=[last[@"role"] isEqual:@"assistant"] && [last[@"content"] length];
    if (!session || finished==SPDFMacAIChatActivityStopped || !answered || [self aiChatInView:session]) return;
    if ([state.store setChat:session.chat[@"id"] unread:YES error:nil])
        [self searchAIChats:state.historyView.search.stringValue ?: @""];
}

- (void)aiNoteChatViewed {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    NSString* identifier=state.session.chat[@"id"];
    if (![self aiChatInView:state.session] || ![state.store chatIsUnread:identifier]) return;
    if ([state.store setChat:identifier unread:NO error:nil])
        [self searchAIChats:state.historyView.search.stringValue ?: @""];
}

@end
