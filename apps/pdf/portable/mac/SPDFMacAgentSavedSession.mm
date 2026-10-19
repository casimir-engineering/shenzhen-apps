#import "SPDFMacAgentSavedSession.h"
#import "SPDFMacAgentGroups.h"
#import "SPDFMacTabGroupIntegration.h"
#import "SPDFMacSidebarWorkspace.h"
#import "spdf_yaml.h"
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>

// The existing group operations and tab codec, with no window, document open,
// render, or per-operation disk writes. The outer transaction owns persistence.
@interface SPDFSavedGroupHost : ShenzhenMacDelegate
@property NSMutableDictionary* savedWorkspace;
- (void)loadWindow:(NSDictionary*)window;
- (NSDictionary*)saveWindow:(NSDictionary*)window;
@end
@implementation SPDFSavedGroupHost
- (void)loadWindow:(NSDictionary*)window {
    _windowSessionID=window[@"id"]; _tabs=[NSMutableArray array];
    for (NSDictionary* raw in window[@"tabs"]) {
        SPDFDocumentTab* tab=spdf_tab_from_dictionary(raw); if (tab) [_tabs addObject:tab];
    }
    spdf_tab_groups_normalize(_tabs);
    _selectedTabIndex=MIN(MAX(0,[window[@"selectedTab"] integerValue]),(NSInteger)_tabs.count-1);
    self.savedWorkspace=[window[@"sidebar"] mutableCopy] ?: [NSMutableDictionary dictionary];
}
- (NSMutableDictionary*)sidebarWorkspaceState { return self.savedWorkspace; }
- (void)rememberActiveTabState {}
- (void)collectionRememberGroups {
    // Offline edits commit only the locked session YAML. The live reader
    // reconciles these saved groups with Collection on document consultation;
    // starting its asynchronous store writes here would escape the transaction.
}
- (void)updateTabStrip {}
- (void)refreshSidebarWorkspacePanel {}
- (void)savePersistentState {}
- (void)selectTabAtIndex:(NSInteger)index { _selectedTabIndex=index; [self activateSelectedTabGroup]; }
- (NSDictionary*)saveWindow:(NSDictionary*)window {
    NSMutableDictionary* byPath=[NSMutableDictionary dictionary];
    for (NSDictionary* raw in window[@"tabs"]) byPath[[raw[@"path"] stringByStandardizingPath]]=raw;
    NSMutableArray* tabs=[NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) {
        // Preserve every reading/format/unknown field verbatim. Only group
        // state and the ordering belong to this API transaction.
        NSMutableDictionary* raw=[byPath[tab.path.stringByStandardizingPath] mutableCopy];
        if (tab.group) raw[@"group"]=tab.group.dictionary; else [raw removeObjectForKey:@"group"];
        [tabs addObject:raw];
    }
    NSMutableDictionary* result=[window mutableCopy]; result[@"tabs"]=tabs;
    result[@"selectedTab"]=@(_selectedTabIndex); result[@"sidebar"]=self.savedWorkspace;
    return result;
}
@end
BOOL SPDFMacAgentReaderIsRunning(void) {
    for (NSRunningApplication* app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.bundleIdentifier isEqual:@"com.intuition.shenzhenpdf"] && app.processIdentifier!=getpid() && !app.terminated)
            return YES;
    return NO;
}
static NSDictionary* SavedError(NSError** error,NSString* message) {
    if (error) *error=[NSError errorWithDomain:@"ShenzhenPDF.Agent" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return nil;
}
NSDictionary* SPDFMacAgentSavedSession(NSDictionary* command,NSString* directory,NSError** error) {
    NSString* path=[directory stringByAppendingPathComponent:@"session.yaml"];
    // No directory creation on a read: an absent workspace is reported plainly.
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return SavedError(error,@"No saved reader session. Open documents once before organizing saved tabs.");
    int fd=open([[directory stringByAppendingPathComponent:@"session.lock"] fileSystemRepresentation],O_CREAT|O_RDWR,0600);
    if (fd<0) return SavedError(error,@"Could not lock the saved reader session.");
    if (flock(fd,LOCK_EX)!=0) { close(fd); return SavedError(error,@"Could not lock the saved reader session."); }
    NSDictionary* response=nil;
    @try {
        NSData* bytes=[NSData dataWithContentsOfFile:path options:0 error:error];
        NSString* yaml=bytes ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
        char* json=yaml ? spdf_json_from_yaml(yaml.UTF8String) : NULL;
        NSDictionary* root=json ? [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:error] : nil;
        free(json);
        if (![root isKindOfClass:NSDictionary.class] || ![root[@"windows"] isKindOfClass:NSArray.class])
            return SavedError(error,@"Saved session is invalid; it was left unchanged.");
        NSArray* windows=root[@"windows"]; NSDictionary* chosen=nil; NSUInteger chosenIndex=NSNotFound;
        for (NSUInteger i=0;i<windows.count;i++) {
            NSDictionary* candidate=windows[i];
            if (![candidate isKindOfClass:NSDictionary.class]) return SavedError(error,@"Invalid saved window; session was left unchanged.");
            if (command[@"windowSessionID"] && ![command[@"windowSessionID"] isEqual:candidate[@"id"]]) continue;
            if (!chosen || [candidate[@"focusedAt"] doubleValue]>[chosen[@"focusedAt"] doubleValue]) { chosen=candidate; chosenIndex=i; }
        }
        if (!chosen || ![chosen[@"tabs"] isKindOfClass:NSArray.class]) return SavedError(error,@"Requested saved window was not found.");
        NSMutableSet* paths=[NSMutableSet set];
        for (NSDictionary* raw in chosen[@"tabs"]) {
            if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"path"] isKindOfClass:NSString.class]) return SavedError(error,@"Invalid saved tab; session was left unchanged.");
            NSString* p=[raw[@"path"] stringByStandardizingPath];
            if (!p.isAbsolutePath || [paths containsObject:p]) return SavedError(error,@"Saved tabs contain invalid or duplicate paths; session was left unchanged.");
            [paths addObject:p];
        }
        SPDFSavedGroupHost* host=[SPDFSavedGroupHost new]; [host loadWindow:chosen];
        response=[host performAgentGroupCommand:command];
        if (!response[@"error"] && ![command[@"action"] isEqual:@"list-groups"]) {
            NSMutableArray* updated=[windows mutableCopy]; updated[chosenIndex]=[host saveWindow:chosen];
            NSMutableDictionary* result=[root mutableCopy]; result[@"windows"]=updated;
            NSData* output=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:error];
            NSString* text=output ? [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] : nil;
            char* encoded=text ? spdf_yaml_from_json(text.UTF8String,"ShenzhenPDF session — edit while the app is closed") : NULL;
            NSData* encodedData=encoded ? [[NSString stringWithUTF8String:encoded] dataUsingEncoding:NSUTF8StringEncoding] : nil;
            free(encoded);
            if (!encodedData || ![encodedData writeToFile:path options:NSDataWritingAtomic error:error]) return nil;
        }
    } @finally { flock(fd,LOCK_UN); close(fd); }
    return response;
}
