// Compiled -fsyntax-only, with the reader's include path only (no -Ifriends): the hook lines the host adapter asks the
// lead to add, written exactly as they would appear in each reader file, so a request that no longer compiles fails
// this suite instead of the integration. Never linked or run.

#import "SPDFMacAIIntegration.h"
#import "SPDFMacAIChatView.h"
#import "SPDFMacAITools.h"
#import "SPDFMacAITransport.h"
#import "SPDFMacCollectionPalette.h"
#import "SPDFMacLaunchPrerenderPrivate.h"
#import "friends/SPDFMacFriendsIntegration.h"
#import "friends/SPDFMacFriendsSettingsPage.h"

// Implemented in ShenzhenPDFMac.mm, where the save hook sits; declared here only so the probe can spell it.
@interface ShenzhenMacDelegate (SPDFMacFriendsHookProbeCoordinator)
- (void)writeStateObject:(id)object toFile:(NSString*)name;
@end

@interface ShenzhenMacDelegate (SPDFMacFriendsHookProbe)
- (void)probeLoadPersistentState;
- (void)probeSavePersistentState;
- (void)probeAfterFirstPaint;
- (void)probeAISession:(SPDFMacAITools*)tools view:(SPDFMacAIChatView*)view store:(id)store;
- (void)probeCitation:(NSURL*)URL chat:(NSDictionary*)chat;
- (void)probeAuthorize:(NSString*)draft key:(NSString*)key;
- (void)probePalette:(NSString*)query progress:(NSProgress*)progress result:(NSDictionary*)result;
@end

@implementation ShenzhenMacDelegate (SPDFMacFriendsHookProbe)

// ShenzhenPDFMac.mm -loadPersistentState: the existing line, wrapped (no line added).
- (void)probeLoadPersistentState {
    NSDictionary* settings = [self friendsLaunchWithSettings:[self stateObjectFromFile:@"settings.yaml"]];
    (void)settings;
}

// ShenzhenPDFMac.mm -savePersistentState: the existing literal, wrapped (no line added).
- (void)probeSavePersistentState {
    [self writeStateObject:SPDFMacFriendsSettingsForSaving(@{
        @"version" : @1
    })
                   toFile:@"settings.yaml"];
}

// SPDFMacAISettingsIntegration.mm -showUnifiedSettingsAfterFirstPaint: one line, first.
- (void)probeAfterFirstPaint {
    [self friendsAfterFirstPaint];
}

// SPDFMacAIIntegration.mm -readerAIState: the session line edited in place, and one line after the view's blocks.
- (void)probeAISession:(SPDFMacAITools*)tools view:(SPDFMacAIChatView*)view store:(id)store {
    SPDFMacAIChatSession* session=[[SPDFMacAIChatSession alloc] initWithTransport:[self friendsChatTransport:
        [[SPDFMacAITransport alloc] initWithConfiguration:nil]]
        tools:[self friendsChatTools:(id<SPDFMacAIChatTools>)tools] definitions:SPDFMacAITools.toolDefinitions
        store:store];
    [self friendsAttachChatView:view session:session];
}

// SPDFMacAIIntegration.mm -aiChatAction: "authorize": the two sends, edited in place.
- (void)probeAuthorize:(NSString*)draft key:(NSString*)key {
    if ([self friendsSendDraft:draft using:^BOOL(NSString* text) { return text.length > 0 && key != nil; }]) return;
}

// SPDFMacAIIntegration.mm -aiOpenCitation: one line, after `state` is read.
- (void)probeCitation:(NSURL*)URL chat:(NSDictionary*)chat {
    if ([self friendsOpenCitation:URL chat:chat]) return;
}

// SPDFMacCollectionPalette.mm: the Friends tier and its opening.
- (void)probePalette:(NSString*)query progress:(NSProgress*)progress result:(NSDictionary*)result {
    __block NSArray* latestFriends = @[];
    void (^publish)(NSString*, NSArray*, NSArray*) = ^(NSString* tier, NSArray* first, NSArray* second) {
        (void)second;
        if ([tier isEqual:@"friends"]) latestFriends = first;
        NSArray* rows = SPDFMacFriendsPaletteMergeRows(@[], latestFriends);
        (void)rows;
    };
    [self friendsSearchPaletteQuery:query progress:progress
                            publish:^(NSArray* rows) { publish(@"friends", rows, nil); }];
    if ([self friendsOpenPaletteResult:result]) return;
}

@end

// SPDFMacUnifiedSettings.mm -selectSection: one branch.
static void ProbeSettingsSection(SPDFMacUnifiedSettingsController* controller, NSString* section) {
    if ([section isEqual:@"friends"]) [controller buildFriends];
}
void SPDFMacFriendsHookProbeKeep(void);
void SPDFMacFriendsHookProbeKeep(void) { ProbeSettingsSection(nil, @""); }
