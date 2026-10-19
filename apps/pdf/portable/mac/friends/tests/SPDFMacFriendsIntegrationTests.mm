// The host adapter with the real Friends views, client library and the protocol area's in-process fake helper, on
// loopback in a temporary SZFRIENDS_STATE_DIR: the views' own button placed in an offscreen title bar keeps its
// whole frame as its hit area, Friends' exported services reach the reader and feed Cmd+K, a chat scope opened
// through them is still enforced by the reader when the helper answers outside it, and the assistant's messages reach
// the helper as send_message with via_assistant over the same connection only from the card's Send, after which the
// card says what Friends says: its own sentence for when the message goes, then "Sent to Mei" once message_status
// reports it delivered, without opening the conversation. A helper that announces messages.cancel takes a queued
// message back from the card's Cancel; one from before messages.status is never asked about delivery. Nothing is
// left in the temp folder, even when a check fails.

#import <AppKit/AppKit.h>
#import "mac/SZFriendsDropdownController.h"
#import "mac/SZFriendsHelperLink.h"
#import "mac/SZFriendsHost.h"
#include "client/fake/szfriends_fake_helper.h"
#import "SPDFMacChromeColors.h"
#import "SPDFMacDocumentFormats.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFriendsAppearance.h"
#import "SPDFMacFriendsChatScope.h"
#import "SPDFMacFriendsHost.h"
#import "SPDFMacFriendsLinkSender.h"
#import "SPDFMacFriendsSendProvider.h"
#import "SPDFMacAIChatActivity.h"
#import "SPDFMacAIToolRegistry.h"
#import "SPDFMacFriendsPalette.h"
#import "SPDFMacFriendsTitleBar.h"
#import "SPDFMacFriendsTestSupport.h"

// Stands in for the reader's `/` assistant: hello only needs to see that the host has one.
@interface StubAssistant : NSObject <SZFriendsAssistant>
@end
@implementation StubAssistant
- (NSString*)commandLabel { return @"Ask the assistant"; }
- (NSString*)commandPlaceholder { return @"Draft a reply"; }
- (id<SZFriendsAssistantTask>)runCommand:(NSString*)command conversationID:(NSString*)conversationID
                             attachments:(NSArray<SZFriendsAttachableItem*>*)attachments
                                progress:(void (^)(NSString*))progress
                              completion:(void (^)(SZFriendsAssistantResult*, NSError*))completion {
    (void)command; (void)conversationID; (void)attachments; (void)progress; (void)completion;
    return nil;
}
@end

@interface Bridge : NSObject <SPDFMacFriendsReaderBridge>
@property NSMutableArray<NSView*>* installed;
@property id<SZFriendsServices> services;
@property id<SZFriendsAssistant> assistant;
@end
@implementation Bridge
- (instancetype)init { if ((self = [super init])) _installed = [NSMutableArray array]; return self; }
- (void)friendsBridgeInstallTitleBarButton:(NSView*)button { [self.installed addObject:button]; }
- (void)friendsBridgeRemoveTitleBarButton:(NSView*)button { [self.installed removeObject:button]; }
- (NSArray<NSDictionary*>*)friendsBridgeOpenDocuments { return @[]; }
- (id<SPDFMacFriendsCollectionLookup>)friendsBridgeCollectionLookup { return nil; }
- (void)friendsBridgeOpenPaths:(NSArray<NSString*>*)paths { (void)paths; }
- (void)friendsBridgeRevealFiles:(NSArray<NSURL*>*)fileURLs { (void)fileURLs; }
- (void)friendsBridgeServicesChanged:(id<SZFriendsServices>)services { self.services = services; }
- (SZFriendsAppearance*)friendsBridgeAppearance { return SPDFMacFriendsReaderAppearance(); }
- (id<SZFriendsAssistant>)friendsBridgeAssistant { return self.assistant; }
@end

static NSString* Frame(szfriends_fake_helper* fake, size_t index) {
    char* frame = szfriends_fake_helper_copy_frame(fake, index);
    NSString* text = frame ? @(frame) : nil;
    szfriends_free(frame);
    return text;
}

// The frames from `start` on whose type is `type`, parsed.
static NSArray<NSDictionary*>* FramesOfType(szfriends_fake_helper* fake, NSString* type, size_t start) {
    NSMutableArray* frames = [NSMutableArray array];
    for (size_t index = start; index < szfriends_fake_helper_frame_count(fake); index++) {
        NSData* bytes = [Frame(fake, index) dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* frame = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        if ([frame isKindOfClass:NSDictionary.class] && [frame[@"type"] isEqual:type]) [frames addObject:frame];
    }
    return frames;
}

static NSArray<NSDictionary*>* StatusSubscriptions(szfriends_fake_helper* fake, size_t start) {
    return [FramesOfType(fake, @"subscribe", start) filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"view == 'message_status'"]];
}

static NSString* LastFrameOfType(szfriends_fake_helper* fake, NSString* type) {
    NSString* needle = [NSString stringWithFormat:@"\"type\":\"%@\"", type];
    for (size_t index = szfriends_fake_helper_frame_count(fake); index > 0; index--) {
        NSString* frame = Frame(fake, index - 1);
        if ([frame containsString:needle]) return frame;
    }
    return nil;
}

// The assistant's send tool through the views' link, the client library and a helper speaking the real protocol.
static void CheckAssistantSendsThroughTheLink(SZFriendsHelperLink* link, szfriends_fake_helper* fake) {
    NSString* hello = Frame(fake, 0);
    Expect([hello containsString:@"\"assistant.drafts\""] && [hello containsString:@"\"assistant.chats\""],
           @"hello must say the host has `/` and scoped chats, or the helper refuses via_assistant: %@", hello);
    SPDFMacFriendsLinkSender* sender = [[SPDFMacFriendsLinkSender alloc] initWithLink:link];
    Expect(sender.friendsReady, @"the sender must see the link ready");
    __block NSDictionary* result = nil;
    __block NSString* code = nil;
    __block BOOL answered = NO;
    [sender sendIntent:@"send_message" fields:@{@"conversation_id" : @"c_mei", @"text" : @"Here is the contract.",
                                                @"client_token" : @"0123456789abcdef0123456789abcdef",
                                                @"via_assistant" : @YES}
                 reply:^(NSDictionary* r, NSString* c, NSString* m) { (void)m; result = r; code = c; answered = YES; }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return answered; }), @"send_message never answered");
    NSString* sent = LastFrameOfType(fake, @"send_message");
    Expect(!code && [result[@"message_id"] isEqual:@"m_c2d94e17"] && [sent containsString:@"\"via_assistant\":true"] &&
           [sent containsString:@"\"conversation_id\":\"c_mei\""], @"the helper received %@ and answered %@ %@", sent,
           result, code);
    szfriends_fake_helper_set_reply(fake, "send_message", "{\"type\":\"reply\",\"re\":\"x\",\"ok\":false,"
        "\"error\":{\"code\":\"not_friends\",\"message\":\"You’re not friends with Mei anymore. Add them again to "
        "send messages.\",\"retryable\":false,\"details\":{}}}");
    __block NSString* message = nil;
    code = nil;
    [sender sendIntent:@"send_message" fields:@{@"conversation_id" : @"c_mei", @"text" : @"x",
                                                @"client_token" : @"fedcba9876543210fedcba9876543210",
                                                @"via_assistant" : @YES}
                 reply:^(NSDictionary* r, NSString* c, NSString* m) { (void)r; code = c; message = m; }];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return code != nil; }) && [code isEqual:@"not_friends"] &&
           [message isEqual:@"You’re not friends with Mei anymore. Add them again to send messages."],
           @"the helper's refusal must reach the card: %@ %@",
           code, message);
    szfriends_fake_helper_set_reply(fake, "send_message", NULL);
    // Delivery is watched through message_status, never by opening the chat, which would mark Mei's messages read
    // from AI chat. The first snapshot comes at once: the fixture's (fixtures/snapshots/message-status.json).
    size_t before = szfriends_fake_helper_frame_count(fake);
    __block NSDictionary* statuses = nil;
    NSArray* asked = @[@"m_c4d27a19", @"m_5f2a90c1"];
    id watch = [sender watchMessages:asked handler:^(NSDictionary* s) { statuses = s; }];
    Expect(watch && SPDFMacFriendsTestRunUntil(5, ^BOOL { return statuses != nil; }), @"no message_status snapshot");
    NSArray* subscriptions = StatusSubscriptions(fake, before);
    Expect(subscriptions.count == 1 && [subscriptions[0][@"params"][@"message_ids"] isEqual:asked] &&
           !FramesOfType(fake, @"open_conversation", before).count,
           @"watching must send one message_status subscribe for exactly these messages, and open nothing: %@",
           subscriptions);
    NSData* fixture = [NSData dataWithContentsOfFile:@"friends/fixtures/snapshots/message-status.json"];
    NSMutableDictionary* expected = [NSMutableDictionary dictionary];
    NSDictionary* snapshot = fixture ? [NSJSONSerialization JSONObjectWithData:fixture options:0 error:nil] : nil;
    for (NSDictionary* row in snapshot[@"data"][@"messages"]) expected[row[@"message_id"]] = row[@"status"];
    Expect(expected.count >= 2 && [statuses isEqual:expected] &&
           ([statuses[@"m_c4d27a19"] isEqual:@{@"state" : @"queued", @"label" : @"Sends when Priya is nearby"}]) &&
           ([statuses[@"m_5f2a90c1"] isEqual:@{@"state" : @"delivered", @"label" : @"Delivered"}]),
           @"the handler must receive the helper's statuses: %@", statuses);
    [sender stopWatching:watch];
}

// The whole send, through the real link: a card that waits, the person's Send, Friends' own words while queued, and
// "Sent to Mei" from the helper's message_status, with no conversation opened along the way.
static void CheckCardFollowsDeliveryThroughTheLink(SZFriendsHelperLink* link, szfriends_fake_helper* fake) {
    SPDFMacFriendsLinkSender* sender = [[SPDFMacFriendsLinkSender alloc] initWithLink:link];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    provider.showMessage = ^(NSString* conversation, NSString* message) { (void)conversation; (void)message; };
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:provider error:nil];
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"Tell @Mei it's ready"
        chips:@[[SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"]]
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:nil budget:nil activity:activity];
    size_t before = szfriends_fake_helper_frame_count(fake);
    __block NSDictionary* result = nil;
    [registry performTool:SPDFMacFriendsSendToolName arguments:@{@"to" : @"Mei", @"text" : @"It's ready."}
                  context:context completion:^(NSDictionary* r) { result = r; }];
    NSDictionary* card = activity.entries.lastObject;
    Expect([result[@"status"] isEqual:@"waiting for the person"] && szfriends_fake_helper_frame_count(fake) == before,
           @"the call reached the helper before the person's Send: %@", result);
    [activity performAction:@"send" forEntry:card[SPDFMacAIActivityIDKey]];
    // Friends' own sentence as the helper's welcome carries it (fixtures/frames/welcome.json), then where to look.
    NSData* welcome = [NSData dataWithContentsOfFile:@"friends/fixtures/frames/welcome.json"];
    NSDictionary* frame = welcome ? [NSJSONSerialization JSONObjectWithData:welcome options:0 error:nil] : nil;
    NSString* note = [frame[@"strings"][@"queued_note"] stringByReplacingOccurrencesOfString:@"{first}"
                                                                                  withString:@"Mei"];
    Expect(note.length > 0, @"the welcome fixture has no queued_note: %@", frame[@"strings"]);
    NSString* queued = [note stringByAppendingString:@" Show opens your chat with Mei, where you can see when it "
                                                      "arrives."];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL {
               return [activity.entries.lastObject[SPDFMacAIActivityStatusKey] isEqual:queued]; }),
           @"the queued card must use the helper's own queued_note: %@", activity.entries.lastObject);
    // As the chat does on every change (SPDFMacFriendsAssistantIntegration.mm): the queued message is watched.
    [provider restoreCardsInActivity:activity];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL {
               return [LastFrameOfType(fake, @"subscribe") containsString:@"m_c2d94e17"]; }),
           @"the queued message was never watched: %@", LastFrameOfType(fake, @"subscribe"));
    szfriends_fake_helper_set_view_data(fake, "message_status", "{\"messages\":[{\"message_id\":\"m_c2d94e17\","
                                        "\"status\":{\"state\":\"delivered\",\"label\":\"Delivered\"}}]}");
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL {
               return [activity.entries.lastObject[SPDFMacAIActivityTitleKey] isEqual:@"Sent to Mei"]; }) &&
           [activity.entries.lastObject[SPDFMacAIActivityStatusKey] isEqual:@"Delivered"] &&
           !LastFrameOfType(fake, @"open_conversation"),
           @"delivery must turn the card into Sent, without opening the chat: %@", activity.entries.lastObject);
    [provider restoreCardsInActivity:activity];
}

// The fake helper's state path is too long for a socket, so it listens in the per-user szfriends-<hash> fallback
// folder; the test removes that folder too, or every run would leave one behind. NO when it could not.
static BOOL RemoveSocketFallback(NSString* state) {
    char path[1024];
    bool fallback = false;
    if (szfriends_socket_path(state.fileSystemRepresentation, path, sizeof path, &fallback) != SZFRIENDS_OK ||
        !fallback)
        return YES;
    NSString* folder = [@(path) stringByDeletingLastPathComponent];
    if (![folder.lastPathComponent hasPrefix:@"szfriends-"]) return NO; // not the fallback: never remove it
    [NSFileManager.defaultManager removeItemAtPath:folder error:nil];
    return ![NSFileManager.defaultManager fileExistsAtPath:folder];
}

// One Friends setup: a fake helper in a state folder of its own, the reader's host, and the views' link to it.
@interface FriendsRig : NSObject
@property NSString* state;
@property(assign) szfriends_fake_helper* fake;
@property Bridge* bridge;
@property SPDFMacFriendsHost* host;
@property SZFriendsHelperLink* link;
@end
@implementation FriendsRig
@end

// Every rig still running, stopped by StopRig or, when an expectation exits the process, by StopAllRigs: a failed run
// left a szfriends-<hash> and a spdf-friends-integration-* folder behind before.
static NSMutableArray<FriendsRig*>* gRigs;

static BOOL StopRig(FriendsRig* rig) {
    [rig.link stopDisablingFriends:YES];
    rig.link = nil;
    if (rig.fake) szfriends_fake_helper_stop(rig.fake);
    rig.fake = NULL;
    BOOL removed = RemoveSocketFallback(rig.state);
    [NSFileManager.defaultManager removeItemAtPath:rig.state error:nil];
    [gRigs removeObject:rig];
    return removed;
}

static void StopAllRigs(void) {
    for (FriendsRig* rig in [gRigs copy]) StopRig(rig);
}

// `capabilities`: welcome.capabilities as JSON, or NULL for the welcome fixture's. The link reads SZFRIENDS_STATE_DIR
// when it connects, so each rig points it at its own folder first.
static FriendsRig* StartRig(NSString* name, const char* capabilities) {
    FriendsRig* rig = [FriendsRig new];
    rig.state = SPDFMacFriendsTestTemporaryDirectory(name);
    [gRigs addObject:rig];
    setenv("SZFRIENDS_STATE_DIR", rig.state.fileSystemRepresentation, 1);
    setenv("SPDF_STATE_DIR", rig.state.fileSystemRepresentation, 1);
    szfriends_fake_helper_config config = {};
    config.state_dir = rig.state.fileSystemRepresentation;
    config.fixtures_dir = "friends/fixtures";
    config.capabilities_json = capabilities;
    szfriends_fake_helper* fake = NULL;
    Expect(szfriends_fake_helper_start(&config, &fake) == SZFRIENDS_OK && fake, @"the fake helper did not start");
    rig.fake = fake;
    rig.bridge = [Bridge new];
    rig.bridge.assistant = [StubAssistant new];
    rig.host = [[SPDFMacFriendsHost alloc] initWithBridge:rig.bridge bundle:NSBundle.mainBundle
                                                  formats:[NSSet setWithArray:@[@"pdf", @"md"]]];
    rig.link = [[SZFriendsHelperLink alloc] initWithHost:rig.host];
    [rig.link start];
    SZFriendsHelperLink* link = rig.link;
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return link.state == SZFriendsLinkStateReady; }),
           @"the link never became ready (state %ld)", (long)link.state);
    return rig;
}

// The card's send to Mei through `rig`'s link, pressed: returns the card's activity once Friends has it.
static SPDFMacAIChatActivity* QueuedCard(SPDFMacFriendsSendProvider* provider) {
    SPDFMacAIToolRegistry* registry = [SPDFMacAIToolRegistry new];
    [registry registerProvider:provider error:nil];
    SPDFMacAIChatActivity* activity = [SPDFMacAIChatActivity new];
    SPDFMacAIRequestContext* context = [[SPDFMacAIRequestContext alloc] initWithText:@"Tell @Mei it’s ready"
        chips:@[[SPDFMacAIRequestChip friendsChipWithConversationIDs:@[@"c_mei"] displayName:@"Mei"]]
        origin:SPDFMacAIRequestOriginChat friendConversation:nil settings:nil budget:nil activity:activity];
    __block NSDictionary* result = nil;
    [registry performTool:SPDFMacFriendsSendToolName arguments:@{@"to" : @"Mei", @"text" : @"It’s ready."}
                  context:context completion:^(NSDictionary* r) { result = r; }];
    Expect([result[@"status"] isEqual:@"waiting for the person"], @"no card: %@", result);
    [activity performAction:@"send" forEntry:activity.entries.lastObject[SPDFMacAIActivityIDKey]];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL {
               return [activity.entries.lastObject[SPDFMacAIActivityStatusKey] hasPrefix:@"Messages and files"]; }),
           @"Friends never took the message: %@", activity.entries.lastObject);
    return activity;
}

static NSArray* CardActions(SPDFMacAIChatActivity* activity) {
    return [[activity liveActionsForEntry:activity.entries.lastObject[SPDFMacAIActivityIDKey]] valueForKey:@"id"];
}

// A helper that announces messages.cancel: the queued card offers Cancel, which sends cancel_message for that
// message, and the card then says it was cancelled.
static void CheckCancelThroughTheLink(void) {
    FriendsRig* rig = StartRig(@"integration-cancel", "[\"messages.status\", \"messages.cancel\"]");
    SPDFMacFriendsLinkSender* sender = [[SPDFMacFriendsLinkSender alloc] initWithLink:rig.link];
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    provider.showMessage = ^(NSString* conversation, NSString* message) { (void)conversation; (void)message; };
    SPDFMacAIChatActivity* activity = QueuedCard(provider);
    Expect([CardActions(activity) containsObject:SPDFMacAIActivityActionCancel], @"no Cancel while queued: %@",
           CardActions(activity));
    size_t before = szfriends_fake_helper_frame_count(rig.fake);
    [activity performAction:SPDFMacAIActivityActionCancel forEntry:activity.entries.lastObject[SPDFMacAIActivityIDKey]];
    Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL {
               return [activity.entries.lastObject[SPDFMacAIActivityStateKey] isEqual:SPDFMacAIActivityStateStopped];
           }), @"the card never said it was cancelled: %@", activity.entries.lastObject);
    NSArray* cancels = FramesOfType(rig.fake, @"cancel_message", before);
    Expect(cancels.count == 1 && [cancels[0][@"message_id"] isEqual:@"m_c2d94e17"] &&
           [activity.entries.lastObject[SPDFMacAIActivityTitleKey] isEqual:@"Not sent to Mei"] &&
           [activity.entries.lastObject[SPDFMacAIActivityStatusKey] isEqual:@"Cancelled. Mei won’t get it."],
           @"Cancel must withdraw that message: %@ %@", cancels, activity.entries.lastObject);
    Expect(StopRig(rig), @"the socket fallback folder stayed for %@", rig.state);
}

// A helper from before messages.status: nothing asks it about delivery, so no subscribe it cannot answer, and with no
// messages.cancel the card offers no Cancel that would leave the text on its way.
static void CheckHelperWithoutCapabilities(void) {
    FriendsRig* rig = StartRig(@"integration-old", "[]");
    SPDFMacFriendsLinkSender* sender = [[SPDFMacFriendsLinkSender alloc] initWithLink:rig.link];
    size_t before = szfriends_fake_helper_frame_count(rig.fake);
    __block BOOL heard = NO;
    id watch = [sender watchMessages:@[@"m_c4d27a19"] handler:^(NSDictionary* statuses) {
        (void)statuses;
        heard = YES;
    }];
    SPDFMacFriendsTestRunUntil(0.3, ^BOOL { return heard; });
    Expect(!watch && !heard && !StatusSubscriptions(rig.fake, before).count,
           @"a helper without messages.status was asked about delivery: %@", StatusSubscriptions(rig.fake, before));
    SPDFMacFriendsSendProvider* provider = [[SPDFMacFriendsSendProvider alloc] initWithSender:^{ return sender; }];
    provider.showMessage = ^(NSString* conversation, NSString* message) { (void)conversation; (void)message; };
    SPDFMacAIChatActivity* activity = QueuedCard(provider);
    [provider restoreCardsInActivity:activity];
    SPDFMacFriendsTestRunUntil(0.3, ^BOOL { return NO; });
    Expect(([CardActions(activity) isEqual:@[@"show"]]) && !StatusSubscriptions(rig.fake, before).count,
           @"the card must offer only Show and watch nothing: %@", CardActions(activity));
    Expect(StopRig(rig), @"the socket fallback folder stayed for %@", rig.state);
}

static uint32_t Hex(NSColor* color, NSAppearanceName name) {
    __block uint32_t hex = 0;
    [[NSAppearance appearanceNamed:name] performAsCurrentDrawingAppearance:^{
        NSColor* rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        hex = (uint32_t)lround(rgb.redComponent * 255) << 16 | (uint32_t)lround(rgb.greenComponent * 255) << 8 |
              (uint32_t)lround(rgb.blueComponent * 255);
    }];
    return hex;
}

// The UX critique: rows took the reader's "selected" token on hover, so any row under the pointer looked selected,
// and the views' dark defaults differed from what the reader passes, so renders reviewed against the mockups showed
// colours users never see. The reader passes its own token for every colour the views' defaults copy.
static void CheckReaderAppearance(void) {
    SZFriendsAppearance* appearance = SPDFMacFriendsReaderAppearance();
    SZFriendsAppearance* defaults = [SZFriendsAppearance new];
    NSDictionary<NSString*, NSString*>* tokens = @{@"backgroundColor" : @"window", @"primaryTextColor" : @"text",
        @"secondaryTextColor" : @"secondary", @"separatorColor" : @"line", @"selectionColor" : @"selected",
        @"hoverColor" : @"hover", @"accentColor" : @"accent", @"controlColor" : @"control"};
    for (NSString* key in tokens) {
        NSColor* passed = [appearance valueForKey:key];
        Expect([passed isEqual:SPDFCollectionColor(tokens[key])], @"%@ is not the reader's %@ token: %@", key,
               tokens[key], passed);
        for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua])
            Expect(Hex([defaults valueForKey:key], name) == Hex(passed, name),
                   @"the views' default %@ (%06x) differs from the reader's (%06x) in %@", key,
                   Hex([defaults valueForKey:key], name), Hex(passed, name), name);
    }
    Expect([appearance.titleBarIconColor isEqual:SPDFChromeIconColor(YES)],
           @"the Friends button must take the colour of the title bar's other icons");
    for (NSAppearanceName name in @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua])
        Expect(Hex(appearance.hoverColor, name) != Hex(appearance.selectionColor, name),
               @"hover must not look like the selection in %@", name);
}

static void CheckRealButtonInTitleBar(NSView* button) {
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView;
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 400) styleMask:style
                                                     backing:NSBackingStoreBuffered defer:YES];
    window.releasedWhenClosed = NO;
    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 400)];
    window.contentView = content;
    NSView* strip = [NSView new];
    NSButton* search = [NSButton buttonWithTitle:@"" target:nil action:NSSelectorFromString(@"showFavoritesPalette:")];
    for (NSView* view in @[strip, search]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [content addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [strip.topAnchor constraintEqualToAnchor:content.topAnchor], [strip.heightAnchor constraintEqualToConstant:44],
        [strip.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-44],
        [search.widthAnchor constraintEqualToConstant:24], [search.heightAnchor constraintEqualToConstant:24],
        [search.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-8],
        [search.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor]]];
    SPDFMacFriendsTitleBarPlacement* placement = SPDFMacFriendsInstallTitleBarButton(button, content, strip,
        SPDFMacFriendsTrailingConstraint(content, strip), search, 28);
    [content layoutSubtreeIfNeeded];
    NSRect frame = button.frame;
    Expect(placement && NSWidth(frame) == 28 && NSHeight(frame) == 28, @"views' button frame %@",
           NSStringFromRect(frame));
    for (CGFloat x = NSMinX(frame) + 0.5; x < NSMaxX(frame); x += 1)
        for (CGFloat y = NSMinY(frame) + 0.5; y < NSMaxY(frame); y += 1) {
            NSView* hit = [content hitTest:[content convertPoint:NSMakePoint(x, y) toView:content.superview]];
            Expect(hit == button || [hit isDescendantOf:button], @"the views' button misses (%.1f, %.1f): %@", x, y,
                   hit);
        }
    Expect(!button.mouseDownCanMoveWindow, @"a click on the Friends button would drag the window");
    [placement uninstall];
}

// The reader's hello lists every format it opens in place (SPDFMacFriendsIntegration.mm). The fake helper accepts
// any list; the real one refuses a hello over its limits, and the reader then never connects.
static void CheckOpenFormatsFitTheHelper(void) {
    NSArray<NSString*>* formats = SPDFReadableDocumentExtensions();
    Expect(formats.count <= SZFRIENDS_MAX_OPEN_FORMATS, @"%lu formats; the helper accepts %d",
           (unsigned long)formats.count, SZFRIENDS_MAX_OPEN_FORMATS);
    for (NSString* format in formats)
        Expect(format.length && format.length <= SZFRIENDS_MAX_HELLO_STRING, @"format %@", format);
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        CheckOpenFormatsFitTheHelper();
        gRigs = [NSMutableArray array];
        atexit(StopAllRigs);
        CheckReaderAppearance();
        FriendsRig* rig = StartRig(@"integration", NULL);
        Bridge* bridge = rig.bridge;
        SZFriendsHelperLink* link = rig.link;
        SZFriendsDropdownController* dropdown = [[SZFriendsDropdownController alloc] initWithHost:rig.host link:link];
        [dropdown install];
        Expect(bridge.installed.count == 1 && bridge.installed.firstObject == dropdown.button,
               @"the views did not hand their button to the reader's title bar");
        CheckRealButtonInTitleBar(dropdown.button);

        Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return bridge.services != nil; }),
               @"Friends never offered its services to the reader (Cmd+K, citations, chat scopes)");
        __block NSArray* rows = nil;
        [bridge.services searchMessages:@"pages" limit:SPDFMacFriendsPaletteLimit completion:^(NSArray* results) {
            rows = SPDFMacFriendsPaletteRows(results);
        }];
        Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return rows != nil; }), @"Cmd+K search never answered");
        Expect(rows.count >= 2 && SPDFMacFriendsPaletteRowIsFriends(rows[1]) &&
               [rows[1][@"conversationID"] isEqual:@"c_mei"], @"Cmd+K rows %@", rows);

        // A scope for Kenji; the fake answers with Mei's message regardless, as a broken helper might.
        id<SZFriendsServices> services = bridge.services;
        SPDFMacFriendsChatScopeGate* gate =
            [[SPDFMacFriendsChatScopeGate alloc] initWithServices:^{ return services; }];
        for (NSArray* scope in @[@[@"c_mei"], @[@"c_kenji"]]) {
            [gate beginRequestWithScope:[SPDFMacFriendsScopeRequest conversationIDs:scope labels:@[@"Friend"]]];
            __block NSDictionary* result = nil;
            [gate performTool:SPDFMacFriendsSearchToolName arguments:@{@"query" : @"pages"}
                   completion:^(NSDictionary* r) { result = r; }];
            Expect(SPDFMacFriendsTestRunUntil(5, ^BOOL { return result != nil; }), @"scoped search never answered");
            NSUInteger expected = [scope.firstObject isEqual:@"c_mei"] ? 1 : 0;
            Expect([result[@"results"] count] == expected, @"scope %@ returned %@", scope, result);
            [gate endRequest];
        }

        CheckAssistantSendsThroughTheLink(link, rig.fake);
        CheckCardFollowsDeliveryThroughTheLink(link, rig.fake);

        [dropdown uninstall];
        Expect(!bridge.installed.count, @"disabling must take the button out of the title bar");
        Expect(StopRig(rig), @"the socket fallback folder stayed for %@", rig.state);
        CheckCancelThroughTheLink();
        CheckHelperWithoutCapabilities();
    }
    puts("SPDFMacFriendsIntegrationTests passed");
    return 0;
}
