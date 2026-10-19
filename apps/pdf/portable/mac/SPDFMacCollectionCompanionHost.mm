#import "SPDFMacCollectionCompanion.h"
#import "SPDFMacCollectionPipe.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacPassword.h"
#import "SPDFMacCollectionCredentialIntegration.h"
@implementation SPDFCollectionCompanionHost {
    SPDFMacCollectionStore* _store;
    SPDFCollectionOpenHandler _open;
    SPDFCollectionNavigateHandler _navigate;
    NSTask* _task;
    SPDFCollectionPipe* _pipe;
    BOOL _refreshPending;
}
- (instancetype)initWithStore:(SPDFMacCollectionStore*)store open:(SPDFCollectionOpenHandler)open
                     navigate:(SPDFCollectionNavigateHandler)navigate {
    if ((self=[super init])) {
        _store=store; _open=[open copy]; _navigate=[navigate copy];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:)
            name:SPDFCollectionStoreDidChangeNotification object:store];
    }
    return self;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)storeChanged:(NSNotification*)notification {
    (void)notification;
    @synchronized(self) { if (_refreshPending) return; _refreshPending=YES; }
    dispatch_async(dispatch_get_main_queue(), ^{
        @synchronized(self) { self->_refreshPending=NO; }
        // Never starts or activates the helper for a background capture.
        [self->_pipe send:@{@"kind":@"refresh"}];
    });
}
- (void)receive:(NSDictionary*)message {
    NSString* kind=message[@"kind"];
    if ([kind isEqual:@"credential"]) {
        NSString* password=nil;
        NSArray* paths=[message[@"paths"] isKindOfClass:NSArray.class] ? message[@"paths"] : @[];
        for (id path in paths) {
            if (![path isKindOfClass:NSString.class]) continue;
            if (![_store documentForPath:path] && ![_store archiveInfoForPath:path]) continue;
            SPDFPasswordCredential* credential=[SPDFPasswordCredentialStore.sharedStore credentialForSourcePath:path];
            if (!credential) credential=[SPDFMacCollectionCredentials credentialForSourcePath:path];
            __block NSString* value=nil;
            [credential withUTF8Password:^(const char* bytes) { value=[NSString stringWithUTF8String:bytes]; }];
            if (value) { password=value; break; }
        }
        [_pipe send:@{@"kind":@"credential",@"request":message[@"request"] ?: @"",@"password":password ?: NSNull.null}];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([kind isEqual:@"open"] && [message[@"path"] isKindOfClass:NSString.class]) {
            self->_open(message[@"path"],[message[@"archived"] boolValue]);
            [NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateAllWindows];
        } else if ([kind isEqual:@"navigate"]) {
            // Resolve IDs against the store instead of trusting stale helper metadata.
            NSString* docID=message[@"documentID"], *versionID=message[@"versionID"];
            NSDictionary* document=nil; NSDictionary* version=nil;
            for (NSDictionary* doc in [self->_store documents]) if ([doc[@"id"] isEqual:docID]) { document=doc; break; }
            for (NSDictionary* row in [self->_store versionsForDocumentID:docID])
                if ([row[@"id"] isEqual:versionID]) { version=row; break; }
            if (document) self->_navigate(document,version,[message[@"page"] unsignedIntegerValue],
                [message[@"query"] isKindOfClass:NSString.class] ? message[@"query"] : nil,[message[@"history"] boolValue]);
            [NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateAllWindows];
        } else if ([kind isEqual:@"activateReader"]) {
            [NSRunningApplication.currentApplication activateWithOptions:NSApplicationActivateAllWindows];
        } else if ([kind isEqual:@"settings"]) {
            [NSNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionSettingsChanged" object:nil
                userInfo:@{@"storageLimitOnly":@([message[@"storageLimitOnly"] boolValue])}];
        }
    });
}
- (BOOL)showSettingsWithError:(NSError**)error {
    BOOL sent=[_pipe send:@{@"kind":@"destination",@"destination":@"Settings"}];
    if (!sent && error) *error=[NSError errorWithDomain:@"SPDFCollectionCompanion" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Collection Settings could not receive the request. Please try again."}];
    return sent;
}
- (BOOL)showDocumentID:(NSString*)documentID query:(NSString*)query error:(NSError**)error {
    if (!_task.running) {
        [_pipe close];
        NSURL* bundle=[NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:
            @"Contents/Helpers/ShenzhenPDF Collection.app"];
        NSTask* task=[NSTask new];
        task.executableURL=[bundle URLByAppendingPathComponent:@"Contents/MacOS/ShenzhenPDFCollection"];
        task.arguments=@[@"--collection-companion"];
        NSPipe* input=[NSPipe pipe], *output=[NSPipe pipe];
        task.standardInput=input; task.standardOutput=output; task.standardError=NSFileHandle.fileHandleWithStandardError;
        SPDFCollectionPipe* pipe=[[SPDFCollectionPipe alloc] initWithReader:output.fileHandleForReading
                                                                  writer:input.fileHandleForWriting];
        __weak SPDFCollectionCompanionHost* weakSelf=self;
        pipe.messageHandler=^(NSDictionary* message) { [weakSelf receive:message]; };
        if (![task launchAndReturnError:error]) { [pipe close]; return NO; }
        // Parent must release the child's pipe ends so EOF follows either exit.
        [input.fileHandleForReading closeFile]; [output.fileHandleForWriting closeFile];
        _task=task; _pipe=pipe; [_pipe start];
    }
    BOOL sent=[_pipe send:@{@"kind":@"show",@"root":_store.rootURL.path,
        @"documentID":documentID ?: @"",@"query":query ?: NSNull.null}];
    if (!sent && error) *error=[NSError errorWithDomain:@"SPDFCollectionCompanion" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Collection could not receive the request. Please try again."}];
    if (sent) [[NSRunningApplication runningApplicationWithProcessIdentifier:_task.processIdentifier]
        activateWithOptions:NSApplicationActivateAllWindows];
    return sent;
}
@end
