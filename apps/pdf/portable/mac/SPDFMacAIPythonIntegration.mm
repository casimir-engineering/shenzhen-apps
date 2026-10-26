// The assistant's Python in the reader. run_python joins the AI chat's tool registry (SPDFMacAIToolProvider.h § 2):
// SPDFMacAIIntegration finds aiToolProviderPython by its aiToolProvider prefix when the chat is first used, never at
// launch. Settings' AI page asks aiPythonSandboxSettings for its Python row each time it opens
// (SPDFMacAICapabilitiesSettingsIntegration.h). Neither installs or runs Python: only a run or an Install does.
//
// The reader also tells run_python which documents an id names (SPDFMacAIPythonDocuments.h): an open document by its
// doc: id, a Collection document by its collection: id, and a file or folder given to the chat by its attachment:
// id, found only among the request's own chips, so one chat's attachments are never another's. And it keeps what the
// code saves in ./out the way every output is kept (SPDFMacAIOutputs.h).
#import "SPDFMacDelegatePrivate.h"
#import "SPDFMacAICapabilitiesSettingsIntegration.h"
#import "SPDFMacAIDocumentAvailability.h"
#import "SPDFMacAIOutputs.h"
#import "SPDFMacAIChatSessionGrants.h"
#import "SPDFMacAIPythonSettingsSource.h"
#import "SPDFMacAIPythonToolProvider.h"
#import "SPDFMacAISaveFileToolProvider.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAIToolsReader.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacDocumentFormats.h"

// A Collection document's readable file: the original while it is there, else its latest saved version.
static BOOL SPDFInsideDownloads(NSString* path) {
    NSString* downloads = SPDFMacAIDownloadsDirectory().stringByResolvingSymlinksInPath;
    NSString* real = path.stringByResolvingSymlinksInPath;
    return [path isKindOfClass:NSString.class] && downloads.length &&
        ([real isEqual:downloads] || [real hasPrefix:[downloads stringByAppendingString:@"/"]]);
}

static SPDFMacAIPythonDocument* SPDFCollectionDocument(NSString* identifier, NSSet* savedPaths, NSString** problem) {
    NSString* raw = [identifier substringFromIndex:@"collection:".length];
    SPDFMacCollectionStore* store = SPDFMacCollectionStore.defaultStore;
    NSDictionary* document = nil;
    for (NSDictionary* row in [store documents]) if ([row[@"id"] isEqual:raw]) { document = row; break; }
    if (!document) { *problem = [identifier stringByAppendingString:@" is not in Collection. Use list_collection."]; return nil; }
    NSString* title = document[@"title"] ?: [document[@"path"] lastPathComponent] ?: @"Document";
    // A file the assistant saved to Downloads from another chat: Downloads is never read, through Collection either.
    if ([document[@"reason"] isEqual:SPDFMacAIOutputCollectionReason] && SPDFInsideDownloads(document[@"path"]) &&
        ![savedPaths containsObject:document[@"path"]]) {
        *problem = [identifier stringByAppendingString:@" was saved to Downloads from another chat and can't be read here."];
        return nil;
    }
    if (SPDFCollectionOriginalAvailable(document) && [NSFileManager.defaultManager isReadableFileAtPath:document[@"path"]])
        return [SPDFMacAIPythonDocument documentWithIdentifier:identifier title:title path:document[@"path"]];
    NSString* version = document[@"latestVersionID"];
    if (!version.length) version = [document[@"versions"] lastObject][@"id"];
    NSURL* copy = version.length ? [store materializeVersionID:version documentID:raw error:nil] : nil;
    if (!copy) { *problem = [title stringByAppendingString:@" has no copy that can be read."]; return nil; }
    return [SPDFMacAIPythonDocument documentWithIdentifier:identifier title:title path:copy.path];
}

@implementation ShenzhenMacDelegate (SPDFMacAIPythonTools)

// What a doc:, collection: or attachment: id names, for run_python and save_file alike.
- (SPDFMacAIPythonDocumentResolver)aiDocumentResolver {
    __weak ShenzhenMacDelegate* weakReader = self;
    return ^(NSArray<NSDictionary*>* requests, SPDFMacAIRequestContext* context,
             void (^completion)(NSArray<SPDFMacAIPythonDocument*>*, NSString*)) {
        // The open documents now, on the main thread; Collection is read on a worker, as its tools do.
        NSMutableDictionary* open = [NSMutableDictionary dictionary], *closed = [NSMutableDictionary dictionary];
        for (NSDictionary* candidate in [weakReader aiDocumentCandidates] ?: @[])
            open[SPDFAIDocumentIdentifier(candidate[@"path"])] = candidate;
        // A doc: id that is no longer an open tab gets the reader tools' own words (closed, or gone).
        for (NSDictionary* request in requests)
            if ([request[@"id"] hasPrefix:@"doc:"] && !open[request[@"id"]])
                closed[request[@"id"]] = [weakReader aiClosedDocumentMessage:request[@"id"]] ?: @"";
        NSArray* chips = SPDFMacAIRequestReadableAttachments(context); // given to this chat, or saved by it
        NSMutableSet* savedPaths = [NSMutableSet set];
        for (SPDFMacAIRequestChip* chip in chips)
            if (SPDFMacAIChatGrantIsSaved(chip.identifier) && chip.fileURL.path) [savedPaths addObject:chip.fileURL.path];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray* documents = [NSMutableArray array];
            NSString* problem = nil;
            for (NSDictionary* request in requests) {
                NSString* identifier = request[@"id"];
                SPDFMacAIPythonDocument* document = nil;
                if ([identifier hasPrefix:@"doc:"]) {
                    NSDictionary* candidate = open[identifier];
                    if (candidate)
                        document = [SPDFMacAIPythonDocument documentWithIdentifier:identifier
                            title:candidate[@"title"] ?: [candidate[@"path"] lastPathComponent]
                             path:candidate[@"readPath"] ?: candidate[@"path"]];
                    else problem = [closed[identifier] length] ? closed[identifier] :
                        [identifier stringByAppendingString:@" is not an open document. Use a doc: id from list_workspace."];
                } else if ([identifier hasPrefix:@"collection:"]) {
                    document = SPDFCollectionDocument(identifier, savedPaths, &problem);
                } else {
                    document = SPDFMacAIPythonAttachmentDocument(request, chips, &problem);
                }
                if (!document) break;
                [documents addObject:document];
            }
            dispatch_async(dispatch_get_main_queue(), ^{ completion(problem ? nil : documents, problem); });
        });
    };
}

// Open shows a document in the reader, anything else in the app the Mac opens it with.
- (SPDFMacAIOutputActions*)aiOutputActionsForPath:(NSString*)path {
    __weak ShenzhenMacDelegate* weakReader = self;
    SPDFMacAIOutputHandler open = nil;
    if (SPDFReadableDocumentPath(path)) open = ^(NSString* file) { [weakReader openPath:file]; };
    return [SPDFMacAIOutputActions actionsOpeningWith:open];
}

- (id<SPDFMacAIToolProvider>)aiToolProviderSaveFile {
    SPDFMacAISaveFileToolProvider* provider = [SPDFMacAISaveFileToolProvider new];
    provider.documentResolver = [self aiDocumentResolver];
    provider.saver = ^NSDictionary*(NSData* data, NSString* folder, NSString* name, NSError** error) {
        return SPDFMacAIOutputSaveDataIn(data, folder, name, SPDFMacCollectionStore.defaultStore, error);
    };
    __weak ShenzhenMacDelegate* weakReader = self;
    provider.presenter = ^(id<SPDFMacAIActivityReporting> activity, NSString* path) {
        SPDFMacAIOutputActions* actions = [weakReader aiOutputActionsForPath:path];
        if (actions) SPDFMacAIOutputShowSavedCard(activity, path, actions);
    };
    return provider;
}

- (id<SPDFMacAIToolProvider>)aiToolProviderPython {
    NSString* helper = SPDFMacAIPythonHelperPath(NSBundle.mainBundle);
    if (!helper) return nil; // a build without the helper (the headless suites) has no Python tool
    SPDFMacAIPythonToolProvider* provider =
        [[SPDFMacAIPythonToolProvider alloc] initWithRunner:[[SPDFMacAIPythonSandboxRunner alloc]
                                                                initWithHelperPath:helper]
                                                environment:SPDFMacAIPythonInstaller.sharedInstaller];
    __weak ShenzhenMacDelegate* weakReader = self;
    provider.documentResolver = [self aiDocumentResolver];
    provider.saveOutput = ^NSDictionary*(NSData* data, NSString* name, NSError** error) {
        return SPDFMacAIOutputSaveDataIn(data, name.stringByDeletingLastPathComponent, name.lastPathComponent,
                                         SPDFMacCollectionStore.defaultStore, error);
    };
    provider.writeOnlyDirectories = @[ SPDFMacAIDownloadsDirectory() ];
    provider.showOutput = ^(id<SPDFMacAIActivityReporting> activity, NSString* path, NSString* imageEntry) {
        SPDFMacAIOutputActions* actions = [weakReader aiOutputActionsForPath:path];
        if (!actions) return;
        if (imageEntry) SPDFMacAIOutputMarkEntrySaved(activity, imageEntry, path, actions);
        else SPDFMacAIOutputShowSavedCard(activity, path, actions);
    };
    return provider;
}

@end

@implementation ShenzhenMacDelegate (SPDFMacAIPythonSandboxSettingsSource)

// The shared installer's status, so Settings and the chat's install card always agree on what is installed.
- (id<SPDFMacAIPythonSandboxSettings>)aiPythonSandboxSettings {
    return SPDFMacAIPythonSettingsSource.sharedSource;
}

@end
