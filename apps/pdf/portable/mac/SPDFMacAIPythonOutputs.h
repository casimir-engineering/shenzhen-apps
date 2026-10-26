#pragma once
// Files Python saves in ./out for the person to keep (SPDFMacAIPythonToolProvider.h): each one goes to their
// Downloads folder, documents also to Collection (SPDFMacAIOutputs.h, through the provider's saveOutput), and the chat
// shows each one with Open and Show in Finder; a PNG is also shown as a picture.
#import <Foundation/Foundation.h>

#import "SPDFMacAIChatActivity.h"

NS_ASSUME_NONNULL_BEGIN

// Saves one file, `name` relative to Downloads ("chart.png", "Reports/chart.png"): the install receipt ({path, …}) or
// nil with an error. Called off the main thread.
typedef NSDictionary* _Nullable (^SPDFMacAIPythonOutputSaver)(NSData* data, NSString* name, NSError** error);
// Shows a saved file in the chat: a card, or, with `imageEntry`, that picture's row marked as saved. Main thread.
typedef void (^SPDFMacAIPythonOutputPresenter)(id<SPDFMacAIActivityReporting> activity, NSString* path,
                                               NSString* _Nullable imageEntry);

// At most this many files from ./out are kept per run; the rest are reported to the model.
FOUNDATION_EXPORT const NSUInteger SPDFMacAIPythonMaxOutputs;

// The helper's result split in two: files under out/ (returned), and the result without them (`rest`).
NSArray<NSDictionary*>* SPDFMacAIPythonOutputFiles(NSDictionary* result, NSDictionary* _Nullable* _Nullable rest);

// Saves `files` (helper entries named out/…, data in base64) with `saver` off the main thread, then on the main thread
// shows each in `activity` with `presenter` and calls `completion` with what the model reads: [{"file": "out/x.csv",
// "saved_as": "x.csv", "folder": "Downloads", "_path": where it is} or {"file", "error"}]. Folders inside out/ are
// kept: out/Reports/x.csv goes to Downloads/Reports.
void SPDFMacAIPythonKeepOutputs(NSArray<NSDictionary*>* files, SPDFMacAIPythonOutputSaver saver,
                                SPDFMacAIPythonOutputPresenter _Nullable presenter,
                                id<SPDFMacAIActivityReporting> _Nullable activity,
                                void (^completion)(NSArray<NSDictionary*>* report));

NS_ASSUME_NONNULL_END
