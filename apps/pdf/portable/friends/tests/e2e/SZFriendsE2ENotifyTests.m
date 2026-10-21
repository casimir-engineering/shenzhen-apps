// friends-e2e-notify-check: system notifications between real helpers (ADR 0017, PROTOCOL.md § Notifications).
//
// Every helper runs in a test home (SZFRIENDS_STATE_DIR), so it posts nothing to the notification centre: each
// request, withdrawal and routed click is a JSON line in <state dir>/notifications.jsonl, which these scenarios read.
// The person's computer runs three apps' clients at once (ShenzhenPDF, Shenzhen Files and Shenzhen 3D, each with its
// own app id and URL scheme), a friend runs a helper of their own, and the second scenario adds the person's second
// computer. The helper is the devices suite's (SZFriendsE2EDevices.h), with no host list: everything is nearby.
//
// Usage: SZFriendsE2ENotifyTests <online e2e helper> <animal manifest> [scenario numbers, e.g. 2]

#import "SZFriendsE2EDevices.h"

#import <sodium.h>

static const NSTimeInterval kScenarioBudget = 60;
// How long nothing must appear for a "never notifies" check: a burst is one second.
static const NSTimeInterval kQuiet = 2.5;

#pragma mark - The sink

static NSArray<NSDictionary *> *SinkLines(SZFE2EComputer *computer) {
    NSString *path = [computer.helper.stateDirectory stringByAppendingPathComponent:@"notifications.jsonl"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length == 0) continue;
        id object = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0
                                                      error:NULL];
        if ([object isKindOfClass:NSDictionary.class]) [lines addObject:object];
    }
    return lines;
}

static NSArray<NSDictionary *> *SinkRequests(SZFE2EComputer *computer, NSString *kind) {
    NSMutableArray *requests = [NSMutableArray array];
    for (NSDictionary *line in SinkLines(computer)) {
        if (line[@"key"] != nil && (kind == nil || [line[@"kind"] isEqual:kind])) [requests addObject:line];
    }
    return requests;
}

static NSArray<NSDictionary *> *RequestsWithBody(SZFE2EComputer *computer, NSString *body) {
    return [SinkRequests(computer, nil) filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"body == %@", body]];
}

// Waits for the one request with `body`; nil when none came.
static NSDictionary *_Nullable AwaitBody(SZFE2EComputer *computer, NSString *body) {
    SZFE2EWaitUntil(15, ^BOOL { return RequestsWithBody(computer, body).count > 0; });
    return RequestsWithBody(computer, body).firstObject;
}

static NSUInteger WithdrawalsOf(SZFE2EComputer *computer, NSString *thread) {
    NSUInteger count = 0;
    for (NSDictionary *line in SinkLines(computer)) count += [line[@"withdraw"][@"thread"] isEqual:thread];
    return count;
}

static NSDictionary *Open(NSString *url, NSString *appID) {
    return @{@"url" : url, @"app_id" : appID, @"app_path" : [NSNull null]};
}

// The person's own words reach the list row of the conversation (directly, or by sync).
static BOOL RowSays(SZFE2EComputer *computer, NSString *title, NSString *text) {
    return SZFE2EWaitUntil(20, ^BOOL {
        NSString *subtitle = SZFE2EListRow(computer, title)[@"subtitle"];
        return [subtitle isKindOfClass:NSString.class] && [subtitle containsString:text];
    });
}

static SZFE2EClient *_Nullable AppClient(SZFE2EComputer *computer, NSString *appID, NSString *name, NSString *scheme) {
    return [SZFE2EClient clientForHelper:computer.helper appID:appID appName:name urlScheme:scheme
                            capabilities:@[ @"drop.files", @"notifications.focus", @"notifications.ask" ]];
}

static BOOL OK(NSDictionary *_Nullable reply) {
    return [reply[@"ok"] boolValue];
}

#pragma mark - Scenarios

// A friend's request, acceptance, message and offer each post one notification worded as ADR 0017 says, opening the
// app the person used last; nothing for the conversation a focused window shows; read withdraws; Show message text
// off hides the words; a click opens the last app on the conversation and Reply sends.
static BOOL ScenarioFriend(SZFE2EWorld *world) {
    SZFE2EComputer *studio = SZFE2EStartComputer(world, @"studio", @"Ana", nil, NO);
    SZFE2EComputer *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
    CHECK(studio != nil && ben != nil);
    NSString *benAtStudio = nil, *anaAtBen = nil;
    if (!SZFE2EBefriendNearby(studio, ben, &benAtStudio, &anaAtBen)) return NO;

    // The request on Ben's computer, the acceptance on Ana's: before any app was remembered, ShenzhenPDF opens.
    NSDictionary *request = AwaitBody(ben, @"Wants to be friends");
    CHECK([request[@"kind"] isEqual:@"request"] && [request[@"channel"] isEqual:@"requests"] &&
              [request[@"title"] isEqual:@"Ana"] && [request[@"conversation_id"] isEqual:anaAtBen] &&
              [request[@"thread"] isEqual:anaAtBen] && request[@"reply"] == [NSNull null] &&
              [request[@"open"] isEqual:Open([@"shenzhenpdf://friends/conversation/" stringByAppendingString:anaAtBen],
                                             @"com.intuition.shenzhenpdf")],
          "the request: %@", SinkLines(ben));
    CHECK(SinkRequests(ben, @"request").count == 1, "one request: %@", SinkLines(ben));
    NSDictionary *accepted = AwaitBody(studio, @"Accepted your friend request");
    CHECK([accepted[@"kind"] isEqual:@"request"] && [accepted[@"title"] isEqual:@"Ben"] &&
              [accepted[@"conversation_id"] isEqual:benAtStudio],
          "the acceptance: %@", SinkLines(studio));

    // Three apps on Ana's computer; Shenzhen Files is the one she used last.
    SZFE2EClient *pdf = AppClient(studio, @"com.intuition.shenzhenpdf", @"ShenzhenPDF", @"shenzhenpdf");
    SZFE2EClient *files = AppClient(studio, @"com.intuition.shenzhenfiles", @"Shenzhen Files", @"shenzhenfiles");
    SZFE2EClient *threeD = AppClient(studio, @"com.shenzhen3d.viewer", @"Shenzhen 3D", @"shenzhen3d");
    CHECK(pdf && files && threeD, "three apps connect");
    CHECK([pdf.welcome[@"capabilities"] containsObject:@"notifications"], "the helper posts: %@", pdf.welcome);
    CHECK(OK([pdf intent:@"activate" fields:nil]) && OK([files intent:@"activate" fields:nil]), "activate");

    // A message: one notification, in Ana's last app.
    CHECK(SZFE2ESay(ben, anaAtBen, @"Can you check the bracket?"), "Ben says it");
    NSDictionary *message = AwaitBody(studio, @"Can you check the bracket?");
    NSString *chat = [@"friends/conversation/" stringByAppendingString:benAtStudio];
    CHECK([message[@"kind"] isEqual:@"message"] && [message[@"channel"] isEqual:@"messages"] &&
              [message[@"key"] hasPrefix:@"message:"] && [message[@"title"] isEqual:@"Ben"] &&
              [message[@"conversation_id"] isEqual:benAtStudio] && [message[@"thread"] isEqual:benAtStudio] &&
              [message[@"reply"] isEqual:(@{@"label" : @"Reply", @"placeholder" : @"Message Ben", @"send" : @"Send"})] &&
              [message[@"open"] isEqual:Open([@"shenzhenfiles://" stringByAppendingString:chat],
                                             @"com.intuition.shenzhenfiles")],
          "the message: %@", message);

    // Read in ShenzhenPDF: withdrawn.
    NSString *open = [pdf openConversation:benAtStudio];
    CHECK(open != nil, "ShenzhenPDF opens the conversation");
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return WithdrawalsOf(studio, benAtStudio) == 1; }), "withdrawn after read: %@",
          SinkLines(studio));
    CHECK(OK([pdf intent:@"unsubscribe" fields:@{@"subscription" : open}]), "closed again");

    // Shown in Shenzhen 3D's focused window: nothing.
    CHECK(OK([threeD intent:@"set_focus" fields:@{@"conversation_id" : benAtStudio}]), "set_focus");
    CHECK(SZFE2ESay(ben, anaAtBen, @"Are you there?"), "Ben asks");
    CHECK(RowSays(studio, @"Ben", @"Are you there?"), "it arrives");
    SZFE2EPump(kQuiet);
    CHECK(RequestsWithBody(studio, @"Are you there?").count == 0, "nothing while focused: %@", SinkLines(studio));
    CHECK(OK([threeD intent:@"set_focus" fields:@{@"conversation_id" : [NSNull null]}]), "focus ends");

    // An offer waiting for an answer opens Shenzhen 3D, the last app Ana looked at Friends in.
    NSString *notes = [world fileOfSize:2048 named:@"Notes.pdf"];
    NSDictionary *sent = [ben.client intent:@"send_files" fields:@{@"conversation_id" : anaAtBen,
                                                                   @"files" : @[ @{@"path" : notes} ],
                                                                   @"client_token" : SZFE2ERandomToken()}];
    CHECK(OK(sent), "Ben offers a file: %@", sent);
    NSDictionary *offer = AwaitBody(studio, @"Ben wants to send you Notes.pdf");
    CHECK([offer[@"kind"] isEqual:@"file"] && [offer[@"channel"] isEqual:@"files"] && [offer[@"title"] isEqual:@"Ben"] &&
              [offer[@"key"] isEqual:[@"file:" stringByAppendingString:[sent[@"result"][@"transfer_ids"] firstObject]]] &&
              [offer[@"open"] isEqual:Open([@"shenzhen3d://" stringByAppendingString:chat], @"com.shenzhen3d.viewer")],
          "the offer: %@", offer);

    // Show message text off: who, never what.
    CHECK(OK([pdf intent:@"set_notifications" fields:@{@"preview" : @NO}]), "preview off");
    NSString *settings = [pdf subscribe:@"settings" params:nil];
    CHECK([[pdf dataFor:settings][@"notifications"][@"preview"][@"value"] isEqual:@NO], "Settings shows it: %@",
          [pdf dataFor:settings][@"notifications"]);
    CHECK(SZFE2ESay(ben, anaAtBen, @"the secret plan"), "Ben says something private");
    NSDictionary *hidden = AwaitBody(studio, @"New message");
    CHECK(hidden != nil && [hidden[@"title"] isEqual:@"Ben"], "hidden: %@", SinkLines(studio));
    NSData *sink = [NSData dataWithContentsOfFile:[studio.helper.stateDirectory
                                                      stringByAppendingPathComponent:@"notifications.jsonl"]];
    CHECK(![[[NSString alloc] initWithData:sink encoding:NSUTF8StringEncoding] containsString:@"secret plan"],
          "the words never reach a notification");
    CHECK(OK([pdf intent:@"set_notifications" fields:@{@"preview" : @YES}]), "preview on");

    // One request per item: no key twice.
    NSArray *keys = [SinkRequests(studio, nil) valueForKey:@"key"];
    CHECK([NSSet setWithArray:keys].count == keys.count, "one request each: %@", keys);

    // A click opens the app used last (Shenzhen Files again) on the conversation.
    CHECK(OK([files intent:@"activate" fields:nil]), "Files again");
    NSDictionary *click = [pdf intent:@"test_notification_response" fields:@{@"key" : message[@"key"],
                                                                            @"action" : @"open"}];
    CHECK(OK(click), "open: %@", click);
    CHECK([SinkLines(studio).lastObject isEqual:@{@"opened" : Open([@"shenzhenfiles://" stringByAppendingString:chat],
                                                                   @"com.intuition.shenzhenfiles")}],
          "the click: %@", SinkLines(studio).lastObject);
    NSDictionary *unknown = [pdf intent:@"test_notification_response" fields:@{@"key" : @"message:nope",
                                                                              @"action" : @"open"}];
    CHECK([unknown[@"error"][@"code"] isEqual:@"not_found"], "an unknown key: %@", unknown);

    // Reply: Ben gets the words, and the conversation is read on Ana's computer.
    NSUInteger before = WithdrawalsOf(studio, benAtStudio);
    NSDictionary *replied = [threeD intent:@"test_notification_response" fields:@{@"key" : hidden[@"key"],
                                                                                 @"action" : @"reply",
                                                                                 @"text" : @"On it"}];
    CHECK(OK(replied), "reply: %@", replied);
    NSString *atBen = [ben.client openConversation:anaAtBen];
    CHECK(SZFE2EWaitUntil(15, ^BOOL { return [SZFE2ETexts(ben.client, atBen) containsObject:@"On it"]; }),
          "Ben reads the reply: %@", SZFE2ETexts(ben.client, atBen));
    CHECK(SZFE2EWaitUntil(10, ^BOOL { return WithdrawalsOf(studio, benAtStudio) > before; }), "read after replying");
    CHECK([SZFE2EListRow(studio, @"Ben")[@"unread"] isEqual:@NO], "no longer unread");
    return YES;
}

// The person's second computer: what they write there never notifies here; a friend's message notifies once here.
static BOOL ScenarioOwnComputer(SZFE2EWorld *world) {
    SZFE2EComputer *studio = SZFE2EStartComputer(world, @"studio", @"Ana", nil, NO);
    SZFE2EComputer *ben = SZFE2EStartComputer(world, @"ben", @"Ben", nil, NO);
    CHECK(studio != nil && ben != nil);
    NSString *benAtStudio = nil, *anaAtBen = nil;
    if (!SZFE2EBefriendNearby(studio, ben, &benAtStudio, &anaAtBen)) return NO;
    SZFE2EComputer *laptop = SZFE2EStartComputer(world, @"laptop", @"Ana", nil, YES);
    CHECK(laptop != nil);
    if (!SZFE2EJoin(studio, laptop, 25)) return NO;
    NSArray *joins = SinkRequests(studio, @"join");
    CHECK(joins.count == 1 && [joins.firstObject[@"title"] hasSuffix:@" wants to join your profile"] &&
              [joins.firstObject[@"body"] isEqual:@"Approve it in Friends only if you’re setting it up now."] &&
              [joins.firstObject[@"open"][@"url"] isEqual:@"shenzhenpdf://friends"],
          "one join request: %@", SinkLines(studio));
    CHECK(SZFE2EWaitUntil(20, ^BOOL { return SZFE2EListRow(laptop, @"Ben") != nil; }), "Ben reaches the laptop");
    NSString *benAtLaptop = SZFE2EListRow(laptop, @"Ben")[@"conversation_id"];

    NSUInteger messagesBefore = SinkRequests(studio, @"message").count;
    CHECK(SZFE2ESay(laptop, benAtLaptop, @"from the laptop"), "Ana writes from the laptop");
    CHECK(SZFE2ESay(laptop, @"you", @"note to self"), "and to herself");
    CHECK(RowSays(studio, @"Ben", @"from the laptop"), "sync brings it to the studio");
    SZFE2EPump(kQuiet);
    CHECK(SinkRequests(studio, @"message").count == messagesBefore, "nothing for her own words: %@",
          SinkLines(studio));
    NSDictionary *atBen = AwaitBody(ben, @"from the laptop");
    CHECK([atBen[@"title"] isEqual:@"Ana"], "Ben hears it: %@", SinkLines(ben));

    // Ben's message reaches one of Ana's computers first; the studio notifies once, directly or by sync.
    CHECK(SZFE2ESay(ben, anaAtBen, @"hi both"), "Ben writes");
    CHECK(AwaitBody(studio, @"hi both") != nil, "the studio hears it: %@", SinkLines(studio));
    SZFE2EPump(kQuiet);
    CHECK(RequestsWithBody(studio, @"hi both").count == 1, "once: %@", SinkLines(studio));
    return YES;
}

#pragma mark - Runner

typedef BOOL (*SZFE2ENotifyScenario)(SZFE2EWorld *world);

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3 || sodium_init() < 0) {
            fprintf(stderr, "usage: SZFriendsE2ENotifyTests <online e2e helper> <animal manifest>\n");
            return 2;
        }
        NSString *executable = @(argv[1]), *manifest = @(argv[2]);
        char template[1024];
        NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"szfn.XXXXXX"];
        strlcpy(template, pattern.fileSystemRepresentation, sizeof(template));
        NSString *root = mkdtemp(template) ? @(template) : nil;
        if (root == nil || ![[NSFileManager defaultManager] isExecutableFileAtPath:executable]) {
            fprintf(stderr, "SZFriendsE2ENotifyTests: no scratch directory or no helper at %s\n", argv[1]);
            return 2;
        }
        SZFE2EWorld *world = [[SZFE2EWorld alloc] initWithExecutable:executable manifest:manifest root:root];
        struct {
            const char *name;
            SZFE2ENotifyScenario run;
        } scenarios[] = {
            {"notify: a friend's request, message and offer, focus, read, preview, click and reply", ScenarioFriend},
            {"notify: the person's second computer never notifies; a friend's message once", ScenarioOwnComputer},
        };
        NSArray<NSString *> *only = argc > 3 ? [@(argv[3]) componentsSeparatedByString:@","] : nil;
        int failed = 0;
        for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
            if (only != nil && ![only containsObject:[NSString stringWithFormat:@"%zu", i + 1]]) continue;
            int before = SZFE2EFailures;
            [world beginScenario:[NSString stringWithFormat:@"n%02zu", i + 1]];
            NSDate *start = [NSDate date];
            BOOL ok = scenarios[i].run(world) && SZFE2EFailures == before;
            NSTimeInterval took = -start.timeIntervalSinceNow;
            if (ok && took > kScenarioBudget) {
                SZFE2EFail(__FILE__, __LINE__, "took <= 60 s", [NSString stringWithFormat:@"%.1f s", took]);
                ok = NO;
            }
            printf("%s %s (%.1f s)\n", ok ? "ok  " : "FAIL", scenarios[i].name, took);
            fflush(stdout);
            if (!ok) {
                failed++;
                [world printLogs];
            }
            [world endScenario];
        }
        if (getenv("SZFRIENDS_E2E_KEEP_LOGS") == NULL) {
            [[NSFileManager defaultManager] removeItemAtPath:root error:NULL];
        } else fprintf(stderr, "SZFriendsE2ENotifyTests: helper logs kept under %s\n", root.UTF8String);
        if (failed > 0 || SZFE2EFailures > 0) {
            fprintf(stderr, "SZFriendsE2ENotifyTests: %d scenario(s) failed\n", failed);
            return 1;
        }
        printf("SZFriendsE2ENotifyTests passed\n");
        return 0;
    }
}
