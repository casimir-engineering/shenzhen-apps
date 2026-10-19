// ShenzhenPDF's assistant for `/` in a friend's composer (portable/friends/mac/SZFriendsHost.h, SZFriendsAssistant).
//
// Each command runs SPDFMacFriendsSlashCommand: it may read that conversation and the person's documents, and its
// message is for that conversation's friend only, with only the files the composer held. A command that asks to send
// comes back as a proposal (SZFriendsAssistantOutcomeProposed): the views show it above the composer exactly as it
// will go, with Send and Edit, and only the person's Send calls the result's `send`, which queues exactly that text
// and those files with via_assistant. Any other command comes back as a draft for the composer. A command never sends
// by itself, because it works inside the friend's chat and may read it. `prepare` resolves what only the reader
// knows (the friend's name, AI settings and key, a fresh session) and may fail with a sentence for the person ("Turn
// on the assistant in Settings to use / here.").

#import <Foundation/Foundation.h>
#import "mac/SZFriendsHost.h"
#import "SPDFMacFriendsSlashCommand.h"

NS_ASSUME_NONNULL_BEGIN

typedef void (^SPDFMacFriendsCommandReady)(SPDFMacFriendsSlashCommand* _Nullable command, NSString* _Nullable model,
                                           NSString* _Nullable apiKey, NSError* _Nullable error);
// Builds one command for `conversationID` with these files. `ready` runs once, on the main thread.
typedef void (^SPDFMacFriendsCommandPreparer)(NSString* conversationID, NSArray<SPDFMacAIRequestChip*>* files,
                                              SPDFMacFriendsCommandReady ready);

@interface SPDFMacFriendsAssistant : NSObject <SZFriendsAssistant>
- (instancetype)initWithPreparer:(SPDFMacFriendsCommandPreparer)prepare NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// Under the command field while a command is being written: what the assistant reads for it and where that goes.
@property(nonatomic, readonly, copy) NSString* commandNote;
// A proposal's Edit button, and the words beside its spinner while Send is under way.
@property(nonatomic, readonly, copy) NSString* proposalEditLabel;
@property(nonatomic, readonly, copy) NSString* proposalSendingStatus;
@end

NS_ASSUME_NONNULL_END
