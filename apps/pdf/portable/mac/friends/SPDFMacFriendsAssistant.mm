#import "SPDFMacFriendsAssistant.h"
#import "SPDFMacFriendsComposerText.h"

// One running `/` command: -cancel stops preparation or the session, whichever is under way, and from then on the
// completion never runs (SZFriendsAssistantTask).
@interface SPDFMacFriendsAssistantTask : NSObject <SZFriendsAssistantTask>
@property(nonatomic) BOOL cancelled;
@property(nonatomic, nullable) SPDFMacFriendsSlashCommand* command;
@end

@implementation SPDFMacFriendsAssistantTask
- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    [self.command cancel];
    self.command = nil;
}
@end

// The proposal's Send: queues exactly `plan`, once. The views never call it twice at once; a press after Friends took
// the message (a stale button) sends nothing again, and a press after a failure tries again with a fresh token.
static void (^SPDFMacFriendsProposalSend(SPDFMacFriendsSendProvider* provider, SPDFMacFriendsSendPlan* plan))(
    void (^)(NSError*)) {
    __block BOOL sending = NO, sent = NO;
    return ^(void (^done)(NSError*)) {
        void (^finish)(NSError*) = done ? (void (^)(NSError*))[done copy] : ^(NSError* error) { (void)error; };
        if (sent) { finish(nil); return; }
        if (sending) {
            finish([NSError errorWithDomain:@"ShenzhenPDF.Friends.Send" code:2
                userInfo:@{NSLocalizedDescriptionKey : @"Still sending. Wait a moment."}]);
            return;
        }
        sending = YES;
        [provider sendProposal:plan done:^(NSError* error) {
            sending = NO;
            sent = error == nil;
            finish(error);
        }];
    };
}

@implementation SPDFMacFriendsAssistant {
    SPDFMacFriendsCommandPreparer _prepare;
}

- (instancetype)initWithPreparer:(SPDFMacFriendsCommandPreparer)prepare {
    if (!(self = [super init])) return nil;
    _prepare = [prepare copy];
    return self;
}

// The command field's tag and hint, read by the person who just typed "/" in a friend's composer. Not "send it": a
// command only ever fills the message box, and the person sends.
- (NSString*)commandLabel { return @"Ask the assistant"; }
- (NSString*)commandPlaceholder { return @"Draft a reply or summarize a document"; }
// Under the field while the person writes a command: what this request reads and where it goes, in the words of AI
// chat's composer note (SPDFMacFriendsComposerText.h), because it is the same assistant sending to the same place.
// True as written because the `/` session offers the reader's read-only tools and this conversation, nothing else
// (SPDFMacFriendsSlashRegistry): no web search, so nothing from the chat reaches a search service or a site, and no
// chat store, so nothing is kept on this Mac either.
- (NSString*)commandNote {
    return @"With this command, the assistant may read this chat and your documents. What it reads goes to "
           "OpenRouter, with no training and nothing kept.";
}
- (NSString*)proposalEditLabel { return @"Edit"; }
- (NSString*)proposalSendingStatus { return @"Sending…"; }

- (id<SZFriendsAssistantTask>)runCommand:(NSString*)command conversationID:(NSString*)conversationID
                             attachments:(NSArray<SZFriendsAttachableItem*>*)attachments
                                progress:(void (^)(NSString*))progress
                              completion:(void (^)(SZFriendsAssistantResult*, NSError*))completion {
    SPDFMacFriendsAssistantTask* task = [SPDFMacFriendsAssistantTask new];
    __block void (^once)(SZFriendsAssistantResult*, NSError*) = [completion copy];
    void (^finish)(SZFriendsAssistantResult*, NSError*) = ^(SZFriendsAssistantResult* result, NSError* error) {
        void (^call)(SZFriendsAssistantResult*, NSError*) = once;
        once = nil;
        if (call && !task.cancelled) call(result, error);
    };
    void (^report)(NSString*) = [progress copy];
    // The person's own attachments are the only files the command may use; each keeps its item, so the composer gets
    // back exactly the chips it had.
    NSMutableArray<SPDFMacAIRequestChip*>* files = [NSMutableArray array];
    NSMapTable<SPDFMacAIRequestChip*, SZFriendsAttachableItem*>* items = [NSMapTable strongToStrongObjectsMapTable];
    for (SZFriendsAttachableItem* item in attachments) {
        SPDFMacAIRequestChip* file = SPDFMacFriendsFileChip(item.fileURL, item.title, item.revision);
        if (!file) continue;
        [files addObject:file];
        [items setObject:item forKey:file];
    }
    if (!_prepare || !conversationID.length) {
        finish(nil, [NSError errorWithDomain:@"ShenzhenPDF.Friends.Assistant" code:4
            userInfo:@{NSLocalizedDescriptionKey : @"The assistant can’t help in this chat."}]);
        return task;
    }
    // The task is held until preparation answers, so a caller that keeps only the protocol's token still gets its
    // one completion.
    _prepare(conversationID, files, ^(SPDFMacFriendsSlashCommand* slash, NSString* model, NSString* key,
                                      NSError* error) {
        if (task.cancelled) return;
        if (!slash) { finish(nil, error); return; }
        task.command = slash;
        SPDFMacFriendsSendProvider* sendProvider = slash.sendProvider;
        [slash runPrompt:command model:model ?: @"" apiKey:key ?: @""
                progress:^(NSString* status) { if (report && !task.cancelled) report(status); }
              completion:^(SPDFMacFriendsSlashResult* outcome, NSError* failure) {
            task.command = nil; // the command, its session and this task stop keeping each other alive
            if (!outcome) { finish(nil, failure); return; }
            SZFriendsAssistantResult* result = [SZFriendsAssistantResult new];
            result.outcome = SZFriendsAssistantOutcomeDraft;
            result.text = outcome.text;
            NSMutableArray* back = [NSMutableArray array];
            for (SPDFMacAIRequestChip* file in outcome.files) {
                SZFriendsAttachableItem* item = [items objectForKey:file];
                if (item) [back addObject:item];
            }
            result.attachments = back;
            // The words AI chat's card uses too: a draft and a proposal both wait for the person's Send.
            result.note = SPDFMacFriendsNotSentYetNote;
            // Never Sent: a command may read the friend's chat, so what it wrote waits for the person's own Send.
            // A proposal's Send queues the plan itself, so it is offered only when the chips shown are all its files.
            if (outcome.plan && back.count == outcome.plan.files.count) {
                result.outcome = SZFriendsAssistantOutcomeProposed;
                result.send = SPDFMacFriendsProposalSend(sendProvider, outcome.plan);
            }
            finish(result, nil);
        }];
    });
    return task;
}

@end
