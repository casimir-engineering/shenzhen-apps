// Shenzhen Friends views tests: entry point, and the helper link's routing over a scripted transport.
//
// Usage: SZFriendsViewsTests <fixtures dir> <animal manifest> <renders dir>
// Runs with a temporary SZFRIENDS_STATE_DIR and the protocol area's fake helper on loopback; never the Keychain,
// never the network, never a window on screen.

#import "SZFriendsViewsTestSupport.h"

#include <pthread.h>
#include <unistd.h>

static NSDictionary *SZFLastSent(SZFTestTransport *transport) {
    return transport.sent.lastObject ?: @{};
}

void SZFTestLinkRouting(void) {
    SZFTestTransport *transport = nil;
    SZFriendsHelperLink *link = SZFTestReadyLink(&transport);
    SZFExpect([[link staticStringForKey:@"tab_nearby"] isEqualToString:@"Nearby"], @"welcome strings");
    SZFExpect([link.helperCapabilities containsObject:@"nearby.bluetooth"], @"welcome capabilities");

    __block NSDictionary *latest = nil;
    __block NSInteger delivered = 0;
    NSString *token = [link subscribeToView:@"list" params:nil handler:^(NSDictionary *data, NSInteger rev) {
        (void)rev;
        latest = data;
        delivered++;
    }];
    NSDictionary *subscribe = SZFLastSent(transport);
    SZFExpect([subscribe[@"type"] isEqualToString:@"subscribe"]
            && [subscribe[@"fields"][@"view"] isEqualToString:@"list"],
              @"subscribe sent: %@", subscribe);
    // The first snapshot precedes its reply (PROTOCOL.md § Snapshots); it must wait for the mapping, not be lost.
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_9", @"view" : @"list", @"rev" : @1,
                         @"data" : @{@"query" : @"first"}}];
    SZFExpect(delivered == 0, @"early snapshot held until the reply");
    [transport deliver:@{@"type" : @"reply", @"re" : subscribe[@"id"], @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_9"}}];
    SZFExpect(delivered == 1 && [latest[@"query"] isEqualToString:@"first"], @"early snapshot delivered after reply");
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_9", @"view" : @"list", @"rev" : @2,
                         @"data" : @{@"query" : @"second"}}];
    SZFExpect(delivered == 2 && [latest[@"query"] isEqualToString:@"second"], @"later snapshot delivered");

    [link setFilter:@"mei" forSubscription:token];
    NSDictionary *filter = SZFLastSent(transport);
    SZFExpect([filter[@"type"] isEqualToString:@"set_filter"] &&
                  [filter[@"fields"][@"subscription"] isEqualToString:@"s_9"] &&
                  [filter[@"fields"][@"query"] isEqualToString:@"mei"],
              @"set_filter uses the helper's id: %@", filter);

    // A reconnect voids helper ids: the link subscribes again by itself and re-applies the filter.
    [transport setLinkState:SZFriendsLinkStateWaiting];
    [transport setLinkState:SZFriendsLinkStateReady];
    NSDictionary *again = SZFLastSent(transport);
    SZFExpect([again[@"type"] isEqualToString:@"subscribe"], @"re-subscribed after reconnect: %@", again);
    [transport deliver:@{@"type" : @"reply", @"re" : again[@"id"], @"ok" : @YES,
            @"result" : @{@"subscription" : @"s_10"}}];
    NSDictionary *refilter = SZFLastSent(transport);
    SZFExpect([refilter[@"type"] isEqualToString:@"set_filter"] &&
                  [refilter[@"fields"][@"subscription"] isEqualToString:@"s_10"],
              @"filter re-applied to the new subscription: %@", refilter);
    [transport deliver:@{@"type" : @"snapshot", @"subscription" : @"s_9", @"view" : @"list", @"rev" : @3,
                         @"data" : @{@"query" : @"stale"}}];
    SZFExpect(![latest[@"query"] isEqualToString:@"stale"], @"snapshots for a void id are not delivered");

    // Intents never queue while disconnected.
    [transport setLinkState:SZFriendsLinkStateWaiting];
    __block NSString *code = nil;
    [link sendIntent:@"ping" fields:nil reply:^(NSDictionary *result, SZFriendsLinkError *error) {
        (void)result;
        code = error.code;
    }];
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return code != nil; }) && [code isEqualToString:@"not_ready"],
              @"not_ready while disconnected: %@", code);
    // An intent in flight when the connection drops fails once, as connection_lost.
    [transport setLinkState:SZFriendsLinkStateReady];
    __block NSInteger calls = 0;
    code = nil;
    [link sendIntent:@"accept_offer" fields:@{@"transfer_id" : @"t_1"} reply:^(NSDictionary *r, SZFriendsLinkError *e) {
        (void)r;
        calls++;
        code = e.code;
    }];
    [transport setLinkState:SZFriendsLinkStateWaiting];
    SZFExpect(SZFTestWaitUntil(2, ^BOOL { return code != nil; }) && [code isEqualToString:@"connection_lost"],
              @"connection_lost: %@", code);
    SZFTestSpin(0.05);
    SZFExpect(calls == 1, @"reply ran exactly once: %ld", (long)calls);

    // Unsubscribing before the reply: the reply's subscription is released at once.
    [transport setLinkState:SZFriendsLinkStateReady];
    NSString *details = [link subscribeToView:@"details" params:@{@"conversation_id" : @"c_mei"}
                                      handler:^(NSDictionary *data, NSInteger rev) { (void)data, (void)rev; }];
    NSDictionary *detailsFrame = nil;
    for (NSDictionary *frame in transport.sent)
        if ([frame[@"fields"][@"view"] isEqualToString:@"details"]) detailsFrame = frame;
    [link unsubscribe:details];
    [transport deliver:@{@"type" : @"reply", @"re" : detailsFrame[@"id"] ?: @"", @"ok" : @YES,
                         @"result" : @{@"subscription" : @"s_20"}}];
    NSDictionary *release = SZFLastSent(transport);
    SZFExpect([release[@"type"] isEqualToString:@"unsubscribe"] &&
                  [release[@"fields"][@"subscription"] isEqualToString:@"s_20"],
              @"abandoned subscription released: %@", release);

    // Error replies reach the view with the helper's own words.
    __block SZFriendsLinkError *failure = nil;
    [link sendIntent:@"accept_offer" fields:@{@"transfer_id" : @"t_kenji_site"}
               reply:^(NSDictionary *result, SZFriendsLinkError *error) {
                   (void)result;
                   failure = error;
               }];
    NSMutableDictionary *errorFrame = [SZFTestFrame(@"frames/reply-error") mutableCopy];
    errorFrame[@"re"] = SZFLastSent(transport)[@"id"];
    [transport deliver:errorFrame];
    SZFExpect([failure.code isEqualToString:@"disk_full"] && failure.message.length > 0 && failure.retryable,
              @"error reply: %@ %@", failure.code, failure.message);
}

// A state directory too deep for a socket path puts the fake helper's socket in a per-user szfriends-<hash>
// directory; stopping the fake must take that directory away too, or every run of the suite leaves one behind.
void SZFTestFakeHelperCleanup(void) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-views-deep.XXXXXX"];
    char *rootTemplate = strdup(pattern.fileSystemRepresentation);
    if (!rootTemplate || !mkdtemp(rootTemplate)) {
        free(rootTemplate);
        SZFExpect(NO, @"temporary directory");
        return;
    }
    NSString *root = @(rootTemplate);
    free(rootTemplate);
    NSString *deep = [root stringByAppendingPathComponent:[@"" stringByPaddingToLength:100 withString:@"d"
                                                                       startingAtIndex:0]];
    char path[SZFRIENDS_PATH_CAP];
    bool fallback = false;
    SZFExpect(szfriends_socket_path(deep.fileSystemRepresentation, path, sizeof path, &fallback) == SZFRIENDS_OK &&
                  fallback,
              @"a state directory this deep uses the fallback socket directory");
    NSString *fallbackDirectory = @(path).stringByDeletingLastPathComponent;
    SZFTestFakeHelper *fake = [[SZFTestFakeHelper alloc] initWithStateDirectory:deep];
    SZFExpect(fake && [NSFileManager.defaultManager fileExistsAtPath:fallbackDirectory],
              @"the fake listens in %@", fallbackDirectory);
    [fake stop];
    SZFExpect(![NSFileManager.defaultManager fileExistsAtPath:fallbackDirectory], @"stopping the fake removes it");
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    rmdir(fallbackDirectory.fileSystemRepresentation); // if the expectation failed, still leave nothing behind
}

static void *SZFWatchdog(void *argument) {
    (void)argument;
    // Every wait in the suite is bounded; this only catches a bug that makes one of them spin forever.
    sleep(240);
    fprintf(stderr, "SZFriendsViewsTests: watchdog expired\n");
    _exit(3);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: %s <fixtures dir> <animal manifest> <renders dir>\n", argv[0]);
            return 2;
        }
        pthread_t watchdog;
        pthread_create(&watchdog, NULL, SZFWatchdog, NULL);
        pthread_detach(watchdog);
        SZFTestFixturesDir = @(argv[1]);
        SZFTestRendersDir = @(argv[3]);
        [NSFileManager.defaultManager createDirectoryAtPath:SZFTestRendersDir withIntermediateDirectories:YES
                                                 attributes:nil error:nil];
        [NSApplication sharedApplication];
        [SZFriendsAvatarView setAnimalManifestPath:@(argv[2])];
        // A private state directory, so nothing touches the real one; a deep path exercises the client library's
        // short fallback socket path.
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfriends-views.XXXXXX"];
        char *stateTemplate = strdup(pattern.fileSystemRepresentation);
        if (!stateTemplate || !mkdtemp(stateTemplate)) return 2;
        NSString *state = @(stateTemplate);
        setenv("SZFRIENDS_STATE_DIR", stateTemplate, 1);
        setenv("SZFRIENDS_KEY_STORE", "file", 1);
        free(stateTemplate);

        SZFTestLinkRouting();
        SZFTestFixtureConstruction();
        SZFTestHitTesting();
        SZFTestControls();
        SZFTestRowActions();
        SZFTestAssistantMarkers();
        SZFTestChrome();
        SZFTestArmedActions();
        SZFTestDragFeedback();
        SZFTestReusedRows();
        SZFTestFakeHelperCleanup();
        SZFTestMarkdownBubbles();
        SZFTestLinkMenus();
        SZFTestAssistantCommands();
        SZFTestAssistantProposals();
        SZFTestInvisibleCharacters();
        SZFTestMarkdownPasses();
        SZFTestPlainText();
        SZFTestMentions();
        SZFTestMentionCards();
        SZFTestFilePreviews();
        SZFTestDropRefusals();
        SZFTestAvatarPhotos();
        SZFTestRouteIcons();
        SZFTestOnlineStates();
        SZFTestFriendLinks();
        SZFTestDevices();
        SZFTestPopoverLayout();
        SZFTestDropdownSession([state stringByAppendingPathComponent:@"session"]);
        SZFTestDrops([state stringByAppendingPathComponent:@"drops"]);
        SZFTestSettingsAndServices([state stringByAppendingPathComponent:@"settings"]);
        SZFTestRenders();
        SZFTestAssistantRenders();

        [NSFileManager.defaultManager removeItemAtPath:state error:nil];
        if (SZFTestFailures) {
            fprintf(stderr, "SZFriendsViewsTests failed: %d\n", SZFTestFailures);
            return 1;
        }
        printf("SZFriendsViewsTests passed\n");
        return 0;
    }
}
