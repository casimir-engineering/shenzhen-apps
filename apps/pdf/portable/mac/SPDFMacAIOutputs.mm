#import "SPDFMacAIOutputs.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentFormats.h"
#import <AppKit/AppKit.h>

NSString* const SPDFMacAIOutputCollectionReason = @"Made by the assistant";
NSString* const SPDFMacAIOutputSavedTitle = @"Saved to Downloads";
NSString* const SPDFMacAIOutputOpenAction = @"open";
NSString* const SPDFMacAIOutputRevealAction = @"reveal";

// Said when Open or Show in Finder finds the file gone: the person moved it, deleted it, or Undo removed it.
static NSString* const kSPDFOutputGone = @"This file is no longer in Downloads.";

NSDictionary* SPDFMacAIOutputKeepInCollection(NSString* path, SPDFMacCollectionStore* store) {
    // isEnabled reads settings only, so off or not chosen creates nothing; capture checks it again under its lock.
    if (!path.length || !store.isEnabled || !SPDFReadableDocumentPath(path)) return nil;
    return [store capturePath:path reason:SPDFMacAIOutputCollectionReason error:nil];
}

NSDictionary* SPDFMacAIOutputSaveData(NSData* data, NSString* name, SPDFMacCollectionStore* store, NSError** error) {
    NSDictionary* receipt = SPDFMacAIOutputWriteData(data, SPDFMacAIDownloadsDirectory(), name, error);
    if (receipt) SPDFMacAIOutputKeepInCollection(receipt[@"path"], store);
    return receipt;
}

NSDictionary* SPDFMacAIOutputSaveDataIn(NSData* data, NSString* folder, NSString* name, SPDFMacCollectionStore* store,
                                        NSError** error) {
    NSString* problem = nil;
    NSString* directory = SPDFMacAIDownloadsSubfolder(folder, &problem);
    if (!directory) {
        if (error) *error = [NSError errorWithDomain:@"ShenzhenPDF.AI.Output" code:2
                                            userInfo:@{NSLocalizedDescriptionKey : problem ?: @"No such folder."}];
        return nil;
    }
    NSDictionary* receipt = SPDFMacAIOutputWriteData(data, directory, name, error);
    if (receipt) SPDFMacAIOutputKeepInCollection(receipt[@"path"], store);
    return receipt;
}

@implementation SPDFMacAIOutputActions
+ (instancetype)actionsOpeningWith:(SPDFMacAIOutputHandler)open {
    SPDFMacAIOutputActions* actions = [self new];
    actions.open = open ?: ^(NSString* path) { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]]; };
    actions.reveal = ^(NSString* path) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
    };
    return actions;
}
@end

static NSArray<NSDictionary*>* SavedActions(void) {
    return @[@{@"id" : SPDFMacAIOutputOpenAction, @"title" : @"Open"},
             @{@"id" : SPDFMacAIOutputRevealAction, @"title" : @"Show in Finder"}];
}

static void Attach(id<SPDFMacAIActivityReporting> activity, NSString* entryID, NSString* path,
                   SPDFMacAIOutputActions* actions) {
    __weak id<SPDFMacAIActivityReporting> weakActivity = activity;
    [activity setHandler:^(NSString* action) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            [weakActivity updateEntry:entryID changes:@{SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
                                                        SPDFMacAIActivityStatusKey : kSPDFOutputGone}];
            return;
        }
        SPDFMacAIOutputHandler handler = [action isEqual:SPDFMacAIOutputRevealAction] ? actions.reveal : actions.open;
        if (handler) handler(path);
    } forEntry:entryID];
}

NSString* SPDFMacAIOutputShowSavedCard(id<SPDFMacAIActivityReporting> activity, NSString* path,
                                       SPDFMacAIOutputActions* actions) {
    if (!activity || !path.length) return nil;
    NSString* entry = [activity addCard:@{SPDFMacAIActivityTitleKey : SPDFMacAIOutputSavedTitle,
        SPDFMacAIActivityCardKindKey : @"assistant.output", SPDFMacAIActivityStateKey : SPDFMacAIActivityStateDone,
        SPDFMacAIActivityAttachmentsKey : @[@{@"name" : path.lastPathComponent}],
        SPDFMacAIActivityActionsKey : SavedActions()} options:SPDFMacAIActivityOptionsNone handler:nil];
    if (entry) Attach(activity, entry, path, actions);
    return entry;
}

void SPDFMacAIOutputMarkEntrySaved(id<SPDFMacAIActivityReporting> activity, NSString* entryID, NSString* path,
                                   SPDFMacAIOutputActions* actions) {
    if (!activity || !entryID.length || !path.length) return;
    [activity updateEntry:entryID changes:@{SPDFMacAIActivityStatusKey : SPDFMacAIOutputSavedTitle,
                                            SPDFMacAIActivityActionsKey : SavedActions()}];
    Attach(activity, entryID, path, actions);
}

void SPDFMacAIOutputSaveChatImage(SPDFMacAIChatActivity* activity, NSString* path, NSString* caption,
                                  SPDFMacCollectionStore* store, SPDFMacAIOutputActions* actions,
                                  void (^done)(NSDictionary*, NSError*)) {
    NSString* entry = nil;
    for (NSDictionary* row in activity.entries)
        if ([row[SPDFMacAIActivityKindKey] isEqual:SPDFMacAIActivityKindImage] &&
            [row[SPDFMacAIActivityImageKey][@"path"] isEqual:path]) entry = row[SPDFMacAIActivityIDKey];
    NSString* name = SPDFMacAIOutputFileName(caption, @"Chart", @"png");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error = nil;
        NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingUncached error:&error];
        NSDictionary* receipt = data ? SPDFMacAIOutputSaveData(data, name, store, &error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (receipt && entry) SPDFMacAIOutputMarkEntrySaved(activity, entry, receipt[@"path"], actions);
            if (done) done(receipt, receipt ? nil : error);
        });
    });
}
