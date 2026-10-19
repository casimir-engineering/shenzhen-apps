#import "SPDFMacAgentGroups.h"
#import "SPDFMacAgentCommand.h"
#import "SPDFMacTabGroupIntegration.h"
#include <assert.h>
#import "SPDFMacAgentSavedSession.h"
#import "spdf_yaml.h"

NSString* spdf_mac_support_directory(void) { return @"/unused-agent-group-tests"; }
static NSUInteger liveCollectionHooks;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"
@implementation ShenzhenMacDelegate
- (void)collectionRememberGroups { liveCollectionHooks++; }
@end
#pragma clang diagnostic pop
@interface AgentGroupProbe : ShenzhenMacDelegate
@property(nonatomic) NSUInteger saves;
@property(nonatomic) NSUInteger selections;
@property(nonatomic) NSUInteger collectionGroupUpdates;
@property(nonatomic) NSMutableDictionary* workspace;
@property(nonatomic) NSArray* savedTabs;
- (void)seed:(NSArray*)tabs;
- (NSArray*)tabs;
@end
@implementation AgentGroupProbe
- (void)seed:(NSArray*)tabs { _tabs=[tabs mutableCopy]; _selectedTabIndex=tabs.count ? 0 : -1; _windowSessionID=@"test-window"; }
- (NSArray*)tabs { return _tabs; }
- (void)updateTabStrip {}
- (void)refreshSidebarWorkspacePanel {}
- (void)rememberActiveTabState {}
// This isolated command/codec target omits Collection storage integration.
// Record the persistence hook without opening the user's Collection store.
- (void)collectionRememberGroups { self.collectionGroupUpdates++; }
- (NSMutableDictionary*)sidebarWorkspaceState { if (!self.workspace) self.workspace=[NSMutableDictionary dictionary]; return self.workspace; }
- (void)savePersistentState {
    self.saves++; NSMutableArray* encoded=[NSMutableArray array];
    for (SPDFDocumentTab* tab in _tabs) [encoded addObject:spdf_dictionary_from_tab(tab,0)];
    self.savedTabs=encoded;
}
- (void)selectTabAtIndex:(NSInteger)index { self.selections++; _selectedTabIndex=index; [self activateSelectedTabGroup]; }
@end
static void Check(BOOL value) { assert(value); }
static SPDFDocumentTab* Tab(NSString* path) {
    SPDFDocumentTab* tab=[SPDFDocumentTab new]; tab.path=path; tab.title=path.lastPathComponent; return tab;
}
static NSDictionary* Run(AgentGroupProbe* host,NSDictionary* command) {
    NSError* error=nil; NSData* bytes=[NSJSONSerialization dataWithJSONObject:command options:0 error:nil];
    NSDictionary* validated=SPDFMacValidateAgentCommand(bytes,&error); Check(validated && !error);
    return [host performAgentGroupCommand:validated];
}
static NSDictionary* Group(NSDictionary* state, NSString* identifier) {
    for (NSDictionary* group in state[@"groups"]) if ([group[@"id"] isEqual:identifier]) return group;
    return nil;
}
static void CheckEmptyGroupCommands(void) {
    AgentGroupProbe* host=[AgentGroupProbe new]; [host seed:@[Tab(@"/current.pdf")]];
    SPDFTabGroup* group=[host createEmptyTabGroup];
    NSDictionary* state=Run(host,@{@"action":@"list-groups"});
    Check(Group(state,group.identifier) && [Group(state,group.identifier)[@"paths"] count]==0);
    state=Run(host,@{@"action":@"update-group",@"groupID":group.identifier,@"name":@"Upcoming",@"hidden":@YES});
    Check(!state[@"error"] && [Group(state,group.identifier)[@"name"] isEqual:@"Upcoming"]);
    state=Run(host,@{@"action":@"move-tab",@"groupID":group.identifier,@"path":@"/current.pdf"});
    Check(!state[@"error"] && [Group(state,group.identifier)[@"paths"] isEqual:@[@"/current.pdf"]]);
    Check(![host emptyTabGroups].count);
}
int main(void) {
    @autoreleasepool {
        CheckEmptyGroupCommands();
        AgentGroupProbe* host=[AgentGroupProbe new];
        [host seed:@[Tab(@"/a.pdf"),Tab(@"/b.md"),Tab(@"/c.pdf"),Tab(@"/d.md")]];
        NSDictionary* state=Run(host,@{@"action":@"list-groups"});
        Check([state[@"groups"] count]==0 && [state[@"tabs"] count]==4 && host.saves==0);
        Check([state[@"tabs"][0][@"groupID"] isEqual:NSNull.null]);
        Check([state[@"windowSessionID"] isEqual:@"test-window"] && [state[@"colors"] containsObject:@"Blue"]);
        Check(Run(host,@{@"action":@"create-group",@"paths":@[@"/a.pdf",@"/missing.md"]})[@"error"]);
        Check(host.saves==0 && !((SPDFDocumentTab*)host.tabs[0]).group);
        Check(Run(host,@{@"action":@"create-group",@"paths":@[@"/a.pdf"],@"color":@"Unknown"})[@"error"]);
        Check(host.saves==0);
        state=Run(host,@{@"action":@"create-group",@"paths":@[@"/c.pdf",@"/a.pdf"],@"name":@" Research ",@"color":@"Blue"});
        NSString* research=state[@"groupID"]; Check(research.length && !state[@"error"]);
        Check(host.collectionGroupUpdates>0);
        Check([Group(state,research)[@"paths"] isEqual:@[@"/c.pdf",@"/a.pdf"]]);
        Check([Group(state,research)[@"name"] isEqual:@"Research"]);
        Check([state[@"groups"][0][@"id"] isEqual:@"general"]);
        Check([Group(state,@"general")[@"paths"] isEqual:@[@"/b.md",@"/d.md"]]);
        NSUInteger saves=host.saves;
        Check(Run(host,@{@"action":@"update-group",@"groupID":research,@"name":@"Wrong window",@"windowSessionID":@"other"})[@"error"]);
        Check(Run(host,@{@"action":@"update-group",@"groupID":@"general",@"name":@"",@"color":@"Blue"})[@"error"]);
        Check(Run(host,@{@"action":@"move-tab",@"path":@"/b.md",@"groupID":research,@"beforePath":@"/d.md"})[@"error"]);
        Check(host.saves==saves);
        state=Run(host,@{@"action":@"update-group",@"groupID":research,@"name":@"Sources",@"color":@"Rose",@"collapsed":@YES});
        Check([Group(state,research)[@"name"] isEqual:@"Sources"] && [Group(state,research)[@"color"] isEqual:@"Rose"]);
        Check([Group(state,research)[@"collapsed"] boolValue]);
        state=Run(host,@{@"action":@"update-group",@"groupID":research,@"collapsed":@NO});
        Check(![Group(state,research)[@"collapsed"] boolValue]);
        state=Run(host,@{@"action":@"move-tab",@"path":@"/b.md",@"groupID":research,@"beforePath":@"/a.pdf"});
        Check([Group(state,research)[@"paths"] isEqual:@[@"/c.pdf",@"/b.md",@"/a.pdf"]]);
        state=Run(host,@{@"action":@"move-tab",@"path":@"/a.pdf",@"groupID":research,@"beforePath":@"/c.pdf"});
        Check([Group(state,research)[@"paths"] isEqual:@[@"/a.pdf",@"/c.pdf",@"/b.md"]]);
        state=Run(host,@{@"action":@"move-group",@"groupID":research,@"beforeGroupID":@"general"});
        Check([state[@"groups"][0][@"id"] isEqual:research]);
        state=Run(host,@{@"action":@"create-group",@"paths":@[@"/d.md"],@"beforeGroupID":research,@"name":@"Review"});
        NSString* review=state[@"groupID"];
        Check([state[@"groups"][0][@"id"] isEqual:review]);
        Check(Run(host,@{@"action":@"create-group",@"paths":@[@"/d.md"],@"beforeGroupID":review})[@"error"]);
        state=Run(host,@{@"action":@"move-group",@"groupID":review});
        Check([[state[@"groups"] lastObject][@"id"] isEqual:review]);
        // The actual session/tab codec is the persistence contract; no parallel agent registry.
        NSMutableArray* restored=[NSMutableArray array];
        for (NSDictionary* saved in host.savedTabs) [restored addObject:spdf_tab_from_dictionary(saved)];
        spdf_tab_groups_normalize(restored);
        AgentGroupProbe* reopened=[AgentGroupProbe new]; [reopened seed:restored];
        NSDictionary* snapshot=Run(reopened,@{@"action":@"list-groups"});
        Check([snapshot[@"groups"] isEqual:state[@"groups"]]);
        Check([[snapshot[@"tabs"] valueForKey:@"path"] isEqual:[state[@"tabs"] valueForKey:@"path"]]);
        state=Run(host,@{@"action":@"ungroup",@"groupID":research});
        Check(!Group(state,research) && [Group(state,@"general")[@"paths"] count]==3);
        Check(Run(host,@{@"action":@"ungroup",@"groupID":@"general"})[@"error"]);
        Check(Run(host,@{@"action":@"update-group",@"groupID":research,@"name":@"Gone"})[@"error"]);
        AgentGroupProbe* managed=[AgentGroupProbe new]; [managed seed:@[Tab(@"/one.md"),Tab(@"/two.md")]];
        Check(Run(managed,@{@"action":@"update-group",@"groupID":@"general",@"color":@"Blue"})[@"error"] && managed.saves==0);
        state=Run(managed,@{@"action":@"update-group",@"groupID":@"general",@"hidden":@YES});
        Check([Group(state,@"general")[@"hidden"] boolValue] && [state[@"tabs"] count]==2 && [state[@"tabs"][0][@"selected"] boolValue]);
        state=Run(managed,@{@"action":@"jump-group",@"groupID":@"general"});
        Check(![Group(state,@"general")[@"hidden"] boolValue]);
        state=Run(managed,@{@"action":@"update-group",@"groupID":@"general",@"name":@"Inbox",@"color":@"Teal"});
        NSString* promoted=state[@"groupID"];
        Check(![promoted isEqual:@"general"] && ![Group(state,promoted)[@"general"] boolValue] &&
            [Group(state,promoted)[@"name"] isEqual:@"Inbox"] && [state[@"newDocumentsInGeneral"] boolValue]);
        SPDFDocumentTab* fresh=Tab(@"/next.md"); [managed appendNewTabToActiveGroup:fresh];
        Check(fresh.group.general && !fresh.group.hidden && [fresh.group.identifier isEqual:@"general"]);
        AgentGroupProbe* batch=[AgentGroupProbe new];
        NSMutableArray* many=[NSMutableArray array]; NSMutableArray* paths=[NSMutableArray array];
        for (NSUInteger i=0;i<256;i++) {
            NSString* path=[NSString stringWithFormat:@"/batch-%lu.pdf",(unsigned long)i];
            [many addObject:Tab(path)]; [paths addObject:path];
        }
        [many addObject:Tab(@"/outside.md")]; [batch seed:many];
        state=Run(batch,@{@"action":@"create-group",@"paths":paths,@"name":@"Batch",@"color":@"Teal"});
        Check(!state[@"error"] && batch.saves==1 && batch.selections==1);
        Check([Group(state,state[@"groupID"])[@"paths"] isEqual:paths]);
        Check([Group(state,@"general")[@"paths"] isEqual:@[@"/outside.md"]]);
        NSDictionary* last=[state[@"tabs"] lastObject];
        Check([last[@"path"] isEqual:paths.lastObject] && [last[@"selected"] boolValue]);
        // Offline operations must not instantiate NSApplication or read documents.
        NSString* dir=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString* session=[dir stringByAppendingPathComponent:@"session.yaml"];
        NSDictionary* untouched=@{@"id":@"other",@"focusedAt":@1,@"tabs":@[]};
        NSDictionary* original=@{@"custom":@"preserved",@"windows":@[untouched,@{@"id":@"offline",@"focusedAt":@2,@"selectedTab":@0,@"tabs":@[@{@"path":@"/not-readable/a.pdf",@"page":@7,@"custom":@42,@"collectionHistoryID":@"existing-collection-document"},@{@"path":@"/not-readable/b.md"}]}]};
        NSData* seed=[NSJSONSerialization dataWithJSONObject:original options:0 error:nil];
        char* encoded=spdf_yaml_from_json([[NSString alloc] initWithData:seed encoding:NSUTF8StringEncoding].UTF8String,"test");
        [[NSString stringWithUTF8String:encoded] writeToFile:session atomically:YES encoding:NSUTF8StringEncoding error:nil]; free(encoded);
        NSData* before=[NSData dataWithContentsOfFile:session]; NSError* offlineError=nil;
        NSDictionary* offline=SPDFMacAgentSavedSession(@{@"action":@"list-groups"},dir,&offlineError);
        Check(!offlineError && [offline[@"windowSessionID"] isEqual:@"offline"] && !NSApp);
        Check([before isEqual:[NSData dataWithContentsOfFile:session]]);
        offline=SPDFMacAgentSavedSession(@{@"action":@"create-group",@"paths":@[@"/not-readable/b.md",@"/not-readable/a.pdf"],@"name":@"Offline",@"color":@"Blue"},dir,&offlineError);
        Check(!offlineError && !offline[@"error"] && !NSApp);
        Check(liveCollectionHooks==0); // Offline grouping must not enter live Collection I/O.
        NSDictionary* reopenedOffline=SPDFMacAgentSavedSession(@{@"action":@"list-groups"},dir,&offlineError);
        Check([offline[@"groups"] isEqual:reopenedOffline[@"groups"]]);
        char* decoded=spdf_json_from_yaml([NSString stringWithContentsOfFile:session encoding:NSUTF8StringEncoding error:nil].UTF8String);
        NSDictionary* saved=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:decoded] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; free(decoded);
        Check([saved[@"custom"] isEqual:@"preserved"] && [saved[@"windows"][0] isEqual:untouched]);
        Check([saved[@"windows"][1][@"tabs"][1][@"page"] intValue]==7 && [saved[@"windows"][1][@"tabs"][1][@"custom"] intValue]==42);
        Check([saved[@"windows"][1][@"tabs"][1][@"collectionHistoryID"] isEqual:@"existing-collection-document"]);
        before=[NSData dataWithContentsOfFile:session];
        offline=SPDFMacAgentSavedSession(@{@"action":@"move-tab",@"path":@"/missing",@"groupID":@"bad"},dir,&offlineError);
        Check(offline[@"error"] && [before isEqual:[NSData dataWithContentsOfFile:session]]);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
        puts("SPDFMacAgentGroupTests passed");
    }
}
