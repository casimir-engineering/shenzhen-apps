#import "SPDFMacAIChatSearch.h"
#import "SPDFMacAIIntegration.h"
#import "SPDFMacCollectionPaletteModel.h"
#import "SPDFMacAIChatSession.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacAIDocumentLinks.h"
#import "SPDFMacDocumentOpening.h"
#import "SPDFMacAIChatStore.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacAIChatDock.h"
#import "SPDFMacAIChatHistoryView.h"
#import "SPDFMacSidebarWorkspace.h"
#import "SPDFMacWorkspacePanels.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacAICredentials.h"
#import "SPDFMacAISettings.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolRegistry.h"
#import "SPDFMacAIOutputs.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacPalettePresentation.h"
#import "SPDFMacUnifiedSettings.h"
#import <objc/runtime.h>
@interface ShenzhenMacDelegate (AISetupHost)
- (void)showUnifiedSettingsMode:(BOOL)wizard;
- (void)persistActiveState;
- (void)rebuildSidebar;
- (void)requestAIModels;
@end
@interface SPDFReaderAIState : NSObject
@property SPDFMacAIChatSession* session;
@property SPDFMacAIChatStore* store;
@property SPDFMacAITools* tools;
@property SPDFMacAIToolRegistry* registry;
@property SPDFMacAIChatView* view;
@property SPDFMacAIChatDock* dock;
@property SPDFMacAIChatHistoryView* historyView;
@property NSUInteger searchGeneration;
@property NSUInteger widthSaveGeneration;
@property NSMutableDictionary* drafts;
@property BOOL history;
@property NSString* submissionIssue;
@property BOOL setupRequired;
@property NSDictionary* pendingEdit; // An edit waiting for the user to authorize the saved key.
@end
@implementation SPDFReaderAIState
- (void)dealloc { [_session cancel]; }
@end
static char stateKey;
@implementation ShenzhenMacDelegate (SPDFMacAIIntegration)
- (SPDFMacAITransport*)aiChatTransport {
    return [[SPDFMacAITransport alloc] initWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
}
- (NSString*)aiAPIKeyForSending:(NSError**)error { return [SPDFMacAICredentials APIKeyWithError:error]; }
- (SPDFReaderAIState*)readerAIHistoryState {
    SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);
    if(!state) {
        state=[SPDFReaderAIState new];state.drafts=[NSMutableDictionary dictionary];
        state.store=[[SPDFMacAIChatStore alloc] initWithDirectory:SPDFMacAIChatStore.defaultDirectory];
        objc_setAssociatedObject(self,&stateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
- (SPDFReaderAIState*)readerAIState {
    SPDFReaderAIState* state=[self readerAIHistoryState];
    if(!state.session) {
        SPDFMacAITools* tools=[[SPDFMacAITools alloc] initWithReader:self]; state.tools=tools;
        // The reader's own tools first, then every provider a category registers (SPDFMacAIToolProvider.h § 2),
        // Friends among them; found now, when the chat is first used, never at launch.
        SPDFMacAIToolRegistry* registry=[SPDFMacAIToolRegistry new]; state.registry=registry;
        [registry registerProvider:[[SPDFMacAIChatToolsProvider alloc] initWithIdentifier:@"reader"
            tools:(id<SPDFMacAIChatTools>)tools definitions:SPDFMacAITools.toolDefinitions
            readOnlyTools:SPDFMacAIReaderReadOnlyToolNames()] error:nil];
        for(id<SPDFMacAIToolProvider> provider in SPDFMacAIDiscoverToolProviders(self))
            [registry registerProvider:provider error:nil];
        state.session=[[SPDFMacAIChatSession alloc] initWithTransport:[self aiChatTransport] registry:registry
            store:state.store];
        state.view=[[SPDFMacAIChatView alloc] initWithFrame:NSMakeRect(0,0,650,520)];
        objc_setAssociatedObject(self,&stateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak ShenzhenMacDelegate* owner=self; __weak SPDFReaderAIState* weakState=state;
        state.session.changed=^{
            [owner searchAIChats:weakState.historyView.search.stringValue ?: @""];
            [weakState.view refreshActivityFromSession:weakState.session];
            [weakState.view displaySession:weakState.session];
        };
        state.view.sendText=^BOOL(NSString* text) { return [owner aiSendText:text]; };
        state.view.editMessage=^BOOL(NSUInteger index,NSString* text) {
            return [owner aiResendMessageAtIndex:index text:text authorizedKey:nil];
        };
        state.view.action=^(NSString* action) { [owner aiChatAction:action]; };
        state.view.openLink=^(NSURL* URL) { [owner aiOpenCitation:URL]; };
        // A chart the person saves is a document the assistant made: Downloads and Collection (SPDFMacAIOutputs.h).
        state.view.saveImage=^(NSString* path,NSString* caption) {
            SPDFMacAIOutputSaveChatImage(weakState.session.activity,path,caption,SPDFMacCollectionStore.defaultStore,
                [SPDFMacAIOutputActions actionsOpeningWith:^(NSString* saved){ [owner openPath:saved]; }],
                ^(NSDictionary* receipt,NSError* error){
                    if(!receipt && error) [weakState.view.window presentError:error];
                });
        };
        [self friendsAttachChatView:state.view session:state.session];
    }
    return state;
}
- (BOOL)isAIChatVisible { return ((SPDFReaderAIState*)objc_getAssociatedObject(self,&stateKey)).dock.visible; }
- (CGFloat)aiChatReservedWidth {SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);return state.dock.visible ? MAX(320,NSWidth(state.view.frame))+1 : 0;}
- (NSWindow*)aiChatWindow { return nil; } // Chat is part of the reader; Cmd+W still closes a document.
- (void)preparePaletteForSearch {}
- (void)showAIChat:(id)sender { (void)sender;[self showAIChatForQuery:nil]; }
- (void)showAIChatForQuery:(NSString*)query {
    // What was typed in Cmd+K, without the col: scope or surrounding spaces.
    query=spdf_collection_palette_query(query ?: @"")[@"query"];
    SPDFReaderAIState* state=[self readerAIState];[self closePalette:nil];
    if(!state.dock && _documentContainer.superview) {
        state.dock=[[SPDFMacAIChatDock alloc] initWithReaderView:_documentContainer chatView:state.view
            width:[[self sidebarWorkspaceState][@"chatWidth"] doubleValue]];
        __weak ShenzhenMacDelegate* owner=self;
        state.dock.resized=^(CGFloat width){ [owner rememberAIChatWidth:width]; };
    }
    if(query.length) {
        state.drafts[state.session.chat[@"id"]]=[state.view.composer.string copy] ?: @"";
        [state.session newChat];state.view.composer.string=query;
    }
    [state.dock setVisible:YES];[self applyWorkspacePanelPolicy];[state.view displaySession:state.session];
    [self relayoutDocumentForViewportChange];[_window makeFirstResponder:state.view.composer];
}
- (void)rememberAIChatWidth:(CGFloat)width {
    SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);
    [self sidebarWorkspaceState][@"chatWidth"]=@(width);
    [self applyWorkspacePanelPolicy];[self relayoutDocumentForViewportChange];
    NSUInteger generation=++state.widthSaveGeneration;
    __weak ShenzhenMacDelegate* owner=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation==state.widthSaveGeneration)[owner persistActiveState];
    });
}
- (void)cancelAIChat { [((SPDFReaderAIState*)objc_getAssociatedObject(self,&stateKey)).session cancel]; }
- (void)closeAIChat {
    SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);
    [state.dock setVisible:NO];[self applyWorkspacePanelPolicy];[self relayoutDocumentForViewportChange];[_window makeFirstResponder:_pageScrollView];
}
- (void)showAIChats:(id)sender {
    (void)sender;[self readerAIHistoryState];_sidebarModeControl.spdf_selectedSidebarMode=SPDFSidebarModeChats;
    _sidebarPreferredVisible=YES;[self prioritizeWorkspaceSidebar];[self rememberSidebarWorkspaceMode];[self rebuildSidebar];
}
- (BOOL)showAIChatSidebarIfSelected {
    SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);
    BOOL selected=_sidebarModeControl.spdf_selectedSidebarMode==SPDFSidebarModeChats;
    state.historyView.hidden=!selected;if(!selected)return NO;
    if(!_sidebarPreferredVisible) {state.historyView.hidden=YES;return YES;}
    state=[self readerAIHistoryState];
    if(!state.historyView) {
        state.historyView=[SPDFMacAIChatHistoryView new];state.historyView.translatesAutoresizingMaskIntoConstraints=NO;
        [_sidebarContainer addSubview:state.historyView];
        [NSLayoutConstraint activateConstraints:@[[state.historyView.leadingAnchor constraintEqualToAnchor:_sidebarContainer.leadingAnchor],
            [state.historyView.trailingAnchor constraintEqualToAnchor:_sidebarContainer.trailingAnchor],
            [state.historyView.topAnchor constraintEqualToAnchor:_sidebarModeControl.bottomAnchor],
            [state.historyView.bottomAnchor constraintEqualToAnchor:_sidebarContainer.bottomAnchor]]];
        __weak ShenzhenMacDelegate* owner=self;
        state.historyView.action=^(NSString* action){ [owner aiChatAction:action]; };
        state.historyView.searchChanged=^(NSString* query){ [owner searchAIChats:query]; };
        __weak SPDFReaderAIState* weakState=state;
        state.historyView.renameItem=^(NSString* identifier,BOOL folder,NSString* name){
            NSError* error=nil;SPDFReaderAIState* live=weakState;
            BOOL ok=folder ? [live.store renameFolder:identifier name:name error:&error] :
                [live.store renameChat:identifier title:name error:&error];
            ShenzhenMacDelegate* reader=owner;
            if(!ok && reader)[reader->_window presentError:error ?: [NSError errorWithDomain:@"ShenzhenPDF.Chat" code:3
                userInfo:@{NSLocalizedDescriptionKey:@"Use a unique name of 1–160 characters."}]];
            [owner searchAIChats:live.historyView.search.stringValue];
        };
    }
    state.historyView.hidden=NO;[self searchAIChats:state.historyView.search.stringValue];return YES;
}
- (void)searchAIChats:(NSString*)query {
    SPDFReaderAIState* state=objc_getAssociatedObject(self,&stateKey);if(!state.historyView || state.historyView.hidden || !_sidebarPreferredVisible)return;
    NSUInteger generation=++state.searchGeneration;query=[query copy] ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(generation!=state.searchGeneration || state.historyView.hidden || !self->_sidebarPreferredVisible)return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
            NSArray* chats=[state.store chatsMatchingQuery:query];NSArray* folders=[state.store folders];
            dispatch_async(dispatch_get_main_queue(),^{if(generation==state.searchGeneration){[state.historyView displayFolders:folders];[state.historyView displayChats:chats selectedID:state.session.chat[@"id"]];}});
        });
    });
}
- (NSString*)aiAuthorizeAPIKeyForSending:(NSError**)error { return [SPDFMacAICredentials authorizeAPIKeyAccessWithError:error]; }
- (BOOL)aiSendText:(NSString*)text { return [self aiSendText:text authorizedKey:nil]; }
// Checks setup and reads the saved key before a request. Returns nil after showing why the request cannot start.
- (NSString*)aiKeyForRequest:(NSString*)authorizedKey summarizing:(BOOL)summarizing
                    settings:(SPDFMacAISettings**)result {
    SPDFReaderAIState* state=[self readerAIState];
    state.setupRequired=NO;
    BOOL (^reject)(NSString*)=^BOOL(NSString* reason) {
        state.submissionIssue=reason; [state.view showSubmissionError:reason]; return NO;
    };
    SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
    NSError* error=nil;
    if(![settings load:&error]) {
        reject(summarizing ? @"AI settings could not be read. Try again." :
            @"AI settings could not be read. Your draft is kept; try again.");
        return nil;
    }
    if(settings.onboardingRevision<SPDFUnifiedSettingsExperienceVersion) {
        state.setupRequired=YES;
        reject(summarizing ? @"Finish setup using Settings above, then try again." :
            @"Finish setup using Settings above before sending. Your draft is kept.");
        return nil;
    }
    if(!settings.enabled) {
        reject(summarizing ? @"Document chat is disabled. Enable it in Settings above." :
            @"Document chat is disabled. Enable it in Settings above. Your draft is kept.");
        return nil;
    }
    // An explicit send checks the credential itself. A stale status flag must not
    // redirect an already connected user to Settings before trying their saved key.
    NSString* key=authorizedKey ?: [self aiAPIKeyForSending:&error];
    if(!key.length) {
        BOOL needsAuthorization=error.code==errSecAuthFailed || error.code==errSecInteractionNotAllowed || error.code==errSecNotAvailable;
        NSString* reason=needsAuthorization ? @"macOS blocked the saved OpenRouter key. Authorize access to send this message." :
            @"Connect OpenRouter in AI settings to send. Your draft is kept.";
        if(summarizing) reason=needsAuthorization ?
            @"macOS blocked the saved OpenRouter key. Authorize access in AI settings, then try again." :
            @"Connect OpenRouter in AI settings, then try again.";
        state.submissionIssue=reason;
        NSString* recovery=needsAuthorization && !summarizing ? @"authorize" : @"settings";
        [state.view showSubmissionError:reason recoveryAction:recovery];
        return nil;
    }
    if(!settings.connectionConfigured) {
        settings.connectionConfigured=YES;
        if(![settings save:&error]) {
            reject(summarizing ? @"The connection could not be saved. Try again." :
                @"The connection could not be saved. Your draft is kept; try again.");
            return nil;
        }
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"ShenzhenPDFAISettingsChanged" object:nil userInfo:nil deliverImmediately:YES];
    }
    state.submissionIssue=nil; [state.view showSubmissionError:nil]; state.history=NO;
    state.session.defaultLanguage=settings.language; state.session.contextTokens=settings.modelContextTokens;
    // The model list says how much the chosen model reads at once; learn it for later requests.
    if(!settings.modelContextTokens && ![self aiModelListLoaded]) [self requestAIModels];
    if(result) *result=settings; return key;
}
- (BOOL)aiSendText:(NSString*)text authorizedKey:(NSString*)authorizedKey {
    if(![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)return NO;
    SPDFReaderAIState* state=[self readerAIState];
    if(state.session.running)return NO;
    state.pendingEdit=nil; // Authorizing now sends this draft, not an earlier edit.
    SPDFMacAISettings* settings=nil;
    NSString* key=[self aiKeyForRequest:authorizedKey summarizing:NO settings:&settings];
    if(!key) return NO;
    NSUInteger before=[state.session.chat[@"messages"] count];
    // The request as the person sent it: chips read from the composer, which still holds them until this returns.
    NSArray* chips=[state.registry requestChipsInComposerText:state.view.composer.textStorage];
    SPDFMacAIRequestContext* context=[[SPDFMacAIRequestContext alloc] initWithText:text chips:chips
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:settings.snapshot budget:nil
        activity:state.session.activity];
    [state.session sendContext:context model:settings.model apiKey:key];
    return [state.session.chat[@"messages"] count]>before;
}
- (BOOL)aiResendMessageAtIndex:(NSUInteger)index text:(NSString*)text authorizedKey:(NSString*)authorizedKey {
    SPDFReaderAIState* state=[self readerAIState];
    state.pendingEdit=@{@"index":@(index),@"text":[text copy] ?: @""};
    SPDFMacAISettings* settings=nil;
    NSString* key=[self aiKeyForRequest:authorizedKey summarizing:NO settings:&settings];
    if(!key) return NO;
    state.pendingEdit=nil;
    SPDFMacAIRequestContext* context=[[SPDFMacAIRequestContext alloc] initWithText:text chips:nil
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:settings.snapshot budget:nil
        activity:state.session.activity];
    return [state.session resendFromMessageAtIndex:index context:context model:settings.model apiKey:key];
}
- (void)aiCompactChat {
    SPDFReaderAIState* state=[self readerAIState];
    if(state.session.running || !state.session.canCompact) return;
    SPDFMacAISettings* settings=nil; NSString* key=[self aiKeyForRequest:nil summarizing:YES settings:&settings];
    if(key) [state.session compactWithModel:settings.model apiKey:key];
}
- (void)aiChatAction:(NSString*)action {
    if([self handleAIChatOrganizationAction:action])return;
    SPDFReaderAIState* state=[self readerAIState];
    if ([action isEqual:@"close"]) { [self closeAIChat]; return; }
    if ([action isEqual:@"compact"]) { [self aiCompactChat]; return; }
    if ([action isEqual:@"retry"]) { // the latest question again, in place of the answer that couldn't be used
        SPDFMacAIChatSession* session=state.session; NSUInteger index=session.retryMessageIndex;
        if (session.canRetry && index!=NSNotFound)
            [self aiResendMessageAtIndex:index text:session.chat[@"messages"][index][@"content"] authorizedKey:nil];
        return;
    }
    if ([action isEqual:@"authorize"] && state.pendingEdit) {
        NSError* error=nil; NSString* key=[self aiAuthorizeAPIKeyForSending:&error];
        NSDictionary* edit=state.pendingEdit;
        if(key.length)
            [self aiResendMessageAtIndex:[edit[@"index"] unsignedIntegerValue] text:edit[@"text"] authorizedKey:key];
        else {
            state.submissionIssue=@"Access was not authorized. "
                "Your edit is kept; authorize access or reconnect in Settings.";
            [state.view showSubmissionError:state.submissionIssue recoveryAction:@"authorize"];
        }
        return;
    }
    if ([action isEqual:@"authorize"]) {
        NSString* draft=state.view.composer.string;
        if(![draft stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length || state.session.running)return;
        SPDFMacAISettings* settings=[[SPDFMacAISettings alloc] initWithURL:SPDFMacAISettings.defaultURL];
        if(![settings load:nil] || !settings.enabled || settings.onboardingRevision<SPDFUnifiedSettingsExperienceVersion) {
            [self aiSendText:draft]; return;
        }
        NSError* error=nil; NSString* key=[self aiAuthorizeAPIKeyForSending:&error];
        BOOL (^send)(NSString*)=^BOOL(NSString* text) { return [self aiSendText:text authorizedKey:key]; };
        if(key.length) { if([self friendsSendDraft:draft using:send])state.view.composer.string=@""; }
        else {
            state.submissionIssue=@"Access was not authorized. Your message is kept; authorize access or reconnect in Settings.";
            [state.view showSubmissionError:state.submissionIssue recoveryAction:@"authorize"];
        }
        return;
    }
    if ([action isEqual:@"settings"]) {
        if(state.setupRequired)[self showUnifiedSettingsMode:YES];
        else if(state.submissionIssue.length)[self showAIConnectionSettingsWithReason:state.submissionIssue];
        else [self showUnifiedSettings:nil];
        return;
    }
    if ([action isEqual:@"current"]) { [self showAIChatForQuery:nil]; return; }
    if ([action isEqual:@"new"]) { state.drafts[state.session.chat[@"id"]]=[state.view.composer.string copy] ?: @"";[state.session newChat];state.view.composer.string=@"";[self showAIChatForQuery:nil]; return; }
    if ([action isEqual:@"stop"]) { [state.session cancel]; return; }
    if ([action isEqual:@"undo"] || [action isEqual:@"redo"]) { [state.session performHistoryAction:[action isEqual:@"redo"]]; return; }
    if ([action isEqual:@"history"]) { [self showAIChats:nil]; return; }
    if ([action hasPrefix:@"load:"]) {
        NSDictionary* chat=[state.store chatWithID:[action substringFromIndex:5]];
        if (chat) {
            NSString* query=[state.historyView.search.stringValue copy];
            state.drafts[state.session.chat[@"id"]]=[state.view.composer.string copy] ?: @"";
            [state.session loadChat:chat];state.view.composer.string=state.drafts[chat[@"id"]] ?: @"";
            [self showAIChatForQuery:nil];
            // A history content match should land at its evidence, not at the
            // newest reply. Title-only matches still open the full conversation.
            [state.view setChatSearchQuery:SPDFMacAIChatHasTextMatch(chat,query) ? query : @""];
        } return;
    }
    if ([action isEqual:@"deleteAll"] || [action hasPrefix:@"delete:"]) {
        NSAlert* alert=[NSAlert new]; alert.messageText=[action isEqual:@"deleteAll"] ? @"Delete all chats?" : @"Delete this chat?";
        alert.informativeText=@"This removes saved conversations from this Mac. Documents and document history are unchanged.";
        [alert addButtonWithTitle:@"Delete"]; [alert addButtonWithTitle:@"Cancel"];
        [alert beginSheetModalForWindow:self->_window completionHandler:^(NSModalResponse result) {
            if (result!=NSAlertFirstButtonReturn) return;
            NSString* identifier=[action hasPrefix:@"delete:"] ? [action substringFromIndex:7] : nil;
            BOOL current=!identifier || [state.session.chat[@"id"] isEqual:identifier];
            if (current) [state.session cancel];
            NSError* error=nil; BOOL ok=identifier ? [state.store deleteChatWithID:identifier error:&error] : [state.store deleteAll:&error];
            if (ok && current) [state.session newChat];
            if (error) [self->_window presentError:error];
            [self searchAIChats:state.historyView.search.stringValue];
        }];
    }
}
- (BOOL)handleAIChatOrganizationAction:(NSString*)action {
    NSArray* parts=[action componentsSeparatedByString:@":"];NSString* command=parts.firstObject;
    if(![@[@"rename",@"move",@"newFolder",@"renameFolder",@"deleteFolder",@"toggleFolder"] containsObject:command])return NO;
    SPDFReaderAIState* state=[self readerAIHistoryState];NSString* identifier=parts.count>1 ? parts[1] : @"";
    NSDictionary* folder=nil;for(NSDictionary* item in state.store.folders)if([item[@"id"] isEqual:identifier])folder=item;
    void (^refresh)(BOOL,NSError*)=^(BOOL ok,NSError* error){
        if(!ok){[self->_window presentError:error ?: [NSError errorWithDomain:@"ShenzhenPDF.Chat" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Could not update chat organization. Use a unique name of 1–160 characters and try again."}]];}
        [self searchAIChats:state.historyView.search.stringValue];
    };
    NSError* error=nil;
    if([command isEqual:@"move"]) {BOOL ok=parts.count==3 && [state.store moveChat:identifier toFolder:parts[2] error:&error];refresh(ok,error);return YES;}
    if([command isEqual:@"toggleFolder"]) {BOOL ok=folder && [state.store setFolder:identifier collapsed:![folder[@"collapsed"] boolValue] error:&error];refresh(ok,error);return YES;}
    if([command isEqual:@"deleteFolder"]) {BOOL ok=[state.store removeFolder:identifier error:&error];refresh(ok,error);return YES;}
    if([command isEqual:@"newFolder"]) {
        NSMutableSet* names=[NSMutableSet set];for(NSDictionary* item in state.store.folders)[names addObject:[item[@"name"] lowercaseString]];
        NSString* name=@"New folder";NSUInteger number=2;
        while([names containsObject:name.lowercaseString])name=[NSString stringWithFormat:@"New folder %lu",(unsigned long)number++];
        NSString* created=[state.store createFolderNamed:name error:&error];
        if(!created){refresh(NO,error);return YES;}
        state.historyView.search.stringValue=@"";++state.searchGeneration;
        [state.historyView displayFolders:state.store.folders];
        [state.historyView displayChats:state.store.chats selectedID:state.session.chat[@"id"]];
        [state.historyView beginRenamingItem:created folder:YES];return YES;
    }
    [state.historyView beginRenamingItem:identifier folder:[command isEqual:@"renameFolder"]];return YES;
}
- (void)aiOpenCitation:(NSURL*)URL {
    NSString* scheme=URL.scheme.lowercaseString;
    if ([scheme isEqual:@"https"] || [scheme isEqual:@"http"]) { [self aiOpenWebLink:URL]; return; }
    SPDFReaderAIState* state=[self readerAIState];
    if ([self friendsOpenCitation:URL chat:state.session.chat]) return;
    NSDictionary* link=SPDFMacAIDocumentLinkArguments(URL);
    NSDictionary* args=SPDFMacAIResolveCitation(state.session.chat,SPDFMacAICitationArguments(URL));
    // A link without retrieved evidence (a document the assistant found in Collection,
    // or one it named by file name) still opens what it names, without a highlight.
    if (!args) { if (![self aiOpenDocumentLink:link]) [self aiShowMissingDocumentLink]; return; }
    // Bring the cited tab forward first, in its own group, so the highlight that
    // follows is published to the tab the reader is looking at.
    NSString* open=[self aiOpenTabPathForDocumentLink:link];
    if (open) [self showDocumentsAtPaths:@[open]];
    [state.tools performTool:@"show_document" arguments:args completion:^(NSDictionary* result) {
        [state.view refreshActivityFromSession:state.session];
        if (!result[@"error"]) { [self->_window makeKeyAndOrderFront:nil]; return; }
        // The passage may have changed since it was retrieved; the document and page still open.
        if (![self aiOpenDocumentLink:link]) [self aiShowMissingDocumentLink];
    }];
}
@end
