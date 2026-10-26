#pragma once
// Every document the assistant makes (a job's PDF, a chart from Python the person saves, an AI translation they
// save) goes to two places: their Downloads folder (SPDFMacAIOutputFiles.h), and Collection, captured at once with
// reason "Made by the assistant" the way received files are captured with "Received". Collection's own rules hold:
// off or not yet chosen, nothing is captured and no Collection is created. The chat then says "Saved to Downloads"
// with Open and Show in Finder.
#import <Foundation/Foundation.h>
#import "SPDFMacAIOutputFiles.h"

@class SPDFMacCollectionStore, SPDFMacAIChatActivity;
@protocol SPDFMacAIActivityReporting;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString* const SPDFMacAIOutputCollectionReason;  // "Made by the assistant"
FOUNDATION_EXPORT NSString* const SPDFMacAIOutputSavedTitle;        // "Saved to Downloads"
FOUNDATION_EXPORT NSString* const SPDFMacAIOutputOpenAction;        // "open", titled "Open"
FOUNDATION_EXPORT NSString* const SPDFMacAIOutputRevealAction;      // "reveal", titled "Show in Finder"

// Captures the saved file into `store` while Collection is on and the file is a document ShenzhenPDF reads; the
// Collection document, or nil (off, not chosen, excluded, failed). Synchronous: call it off the main thread for
// anything large. The file's later removal (Undo) leaves this history in Collection, as removing any original does.
NSDictionary* _Nullable SPDFMacAIOutputKeepInCollection(NSString* path, SPDFMacCollectionStore* store);

// Bytes saved to Downloads and kept in Collection: the install receipt ({path, identity}), or nil with `error`.
NSDictionary* _Nullable SPDFMacAIOutputSaveData(NSData* data, NSString* name, SPDFMacCollectionStore* store,
                                                NSError** error);
// The same in a folder inside Downloads (`folder`, relative, may be empty; SPDFMacAIDownloadsSubfolder).
NSDictionary* _Nullable SPDFMacAIOutputSaveDataIn(NSData* data, NSString* _Nullable folder, NSString* name,
                                                  SPDFMacCollectionStore* store, NSError** error);

typedef void (^SPDFMacAIOutputHandler)(NSString* path);
// What Open and Show in Finder do. Production: the reader opens the file, Finder selects it.
@interface SPDFMacAIOutputActions : NSObject
@property(nonatomic, copy) SPDFMacAIOutputHandler open;
@property(nonatomic, copy) SPDFMacAIOutputHandler reveal;
// reveal: NSWorkspace selects the file in Finder. open: the reader's -openPath:, else the file's default app.
+ (instancetype)actionsOpeningWith:(nullable SPDFMacAIOutputHandler)open;
@end

// A card in the chat for a saved document: "Saved to Downloads", its file name, Open and Show in Finder. Once the
// file is gone (Undo removed it), either button says so instead. The card's id, or nil.
NSString* _Nullable SPDFMacAIOutputShowSavedCard(id<SPDFMacAIActivityReporting> activity, NSString* path,
                                                 SPDFMacAIOutputActions* actions);
// The same on an existing entry (a chart's row): its status becomes "Saved to Downloads", with the two buttons.
void SPDFMacAIOutputMarkEntrySaved(id<SPDFMacAIActivityReporting> activity, NSString* entryID, NSString* path,
                                   SPDFMacAIOutputActions* actions);

// Save on a picture in the chat (a chart Python drew): the PNG at `path` saved to Downloads as `caption` and kept
// in Collection, off the main thread; then, on the main thread, the picture's row says "Saved to Downloads" with
// Open and Show in Finder, and `done` gets the receipt, or nil and why.
void SPDFMacAIOutputSaveChatImage(SPDFMacAIChatActivity* activity, NSString* path, NSString* caption,
                                  SPDFMacCollectionStore* store, SPDFMacAIOutputActions* actions,
                                  void (^_Nullable done)(NSDictionary* _Nullable receipt, NSError* _Nullable error));

NS_ASSUME_NONNULL_END
