#pragma once
// save_file(name, folder?, content | base64 | document): the assistant saves a file into the person's Downloads folder,
// or a folder inside it: text it wrote, bytes, or a copy of a document it can see (doc:, collection: or attachment:
// id), such as a read-only original the person wants kept. Never replaces a file there ("name 2.ext" instead),
// documents also go to Collection, and the chat shows a card with Open and Show in Finder (SPDFMacAIOutputs.h).
//
// Downloads is write-only for the assistant: no tool lists or reads it. The one way back is the id each save returns,
// a grant of this chat (SPDFMacAIChatSessionGrants.h), so this chat may read what it saved and no other chat can.
// Offered only in the person's own request: not to a part (run_subagents), not with Friends chats in the request.
#import <Foundation/Foundation.h>

#import "SPDFMacAIPythonDocuments.h"
#import "SPDFMacAIToolProvider.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAISaveFileToolName; // "save_file"
// What the model reads each turn while save_file is offered.
FOUNDATION_EXPORT NSString* const SPDFMacAISaveFilePromptGuidance;

// Saves `data` as `name` in `folder` (relative to Downloads, may be empty): the receipt ({path, …}) or nil with an
// error written for the model. Called off the main thread.
typedef NSDictionary* _Nullable (^SPDFMacAISaveFileSaver)(NSData* data, NSString* folder, NSString* name,
                                                          NSError** error);
// Shows a saved file in the chat as a card. Main thread.
typedef void (^SPDFMacAISaveFilePresenter)(id<SPDFMacAIActivityReporting> activity, NSString* path);

@interface SPDFMacAISaveFileToolProvider : NSObject <SPDFMacAIToolProvider>
@property(nonatomic, copy, nullable) SPDFMacAISaveFileSaver saver;
@property(nonatomic, copy, nullable) SPDFMacAISaveFilePresenter presenter;
// Finds the document a `document` id names, the way run_python does.
@property(nonatomic, copy, nullable) SPDFMacAIPythonDocumentResolver documentResolver;
@end

NS_ASSUME_NONNULL_END
