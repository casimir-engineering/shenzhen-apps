// friends-e2e-check: ShenzhenPDF and Shenzhen Files on one Mac share one helper (brief § Containment and porting, One
// identity per Mac user; PROTOCOL.md § Lifecycle, Handover).
//
// Ana's Mac runs both apps as processes of their own (SZFriendsE2EApps.h): one plays ShenzhenPDF through the C client
// library as AppKit's link uses it, the other plays Shenzhen Files through the GTK views' link, display-free. They say
// so in their hellos (app_id, app_name, toolkit) and each embeds its own helper with a build number. Ben is a harness
// helper on a separate state directory, befriended over loopback Bonjour before Ana's apps start, so there is a real
// conversation to share and a real friend to deliver to.

#import "SZFriendsE2EApps.h"
#import "SZFriendsE2EScenarios.h"

#import <errno.h>
#import <signal.h>

// The build both apps carry, then the newer one Shenzhen Files is updated to (YYMMDDBB, as helper.mk numbers them).
static const uint64_t SZFE2ESharedBuild = 26101301, SZFE2ENewerBuild = 26101302;

// What a scenario must clean up whatever happens: the app processes and the helpers they spawned.
@interface SZFE2ETwoApps : NSObject
@property(nonatomic, nullable) SZFE2EApp *pdf;
@property(nonatomic, nullable) SZFE2EApp *files;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic) NSMutableArray<NSNumber *> *helpers;
@end

@implementation SZFE2ETwoApps

- (instancetype)init {
    if ((self = [super init])) {
        _directory = @"";
        _helpers = [NSMutableArray array];
    }
    return self;
}

- (void)noteHelpers {
    for (SZFE2EApp *app in @[ self.pdf ?: (id)[NSNull null], self.files ?: (id)[NSNull null] ]) {
        if ([app isKindOfClass:[SZFE2EApp class]]) [self.helpers addObjectsFromArray:app.helperPIDs];
    }
}

- (void)cleanUpAfterFailure:(BOOL)failed {
    [self noteHelpers];
    if (failed) {
        for (SZFE2EApp *app in @[ self.pdf ?: (id)[NSNull null], self.files ?: (id)[NSNull null] ]) {
            if ([app isKindOfClass:[SZFE2EApp class]]) {
                fprintf(stderr, "--- %s log\n%s\n", app.executable.lastPathComponent.UTF8String, app.log.UTF8String);
            }
        }
    }
    [self.pdf quitWithin:3];
    [self.files quitWithin:3];
    self.pdf = self.files = nil;
    // The helpers outlive their apps by a grace period; nothing of a scenario may outlive the scenario.
    SZFE2EKillHelpersUnder(self.helpers, self.directory);
}

@end

static NSString *SZFE2EProgram(NSString *variable) {
    NSString *path = NSProcessInfo.processInfo.environment[variable];
    return [[NSFileManager defaultManager] isExecutableFileAtPath:path] ? path : nil;
}

// Ana and Ben befriended, Ben's message to Ana waiting unread, then Ana's harness helper stopped so her apps start
// their own on the same state directory. Builds both apps; the environment is the one the harness gives its helpers.
static BOOL SZFE2EPrepare(SZFE2EWorld *world, SZFE2EPair *pair, SZFE2ETwoApps *apps, NSDictionary **environment,
                          NSString **pdfExecutable, NSString **filesExecutable) {
    NSString *clientApp = SZFE2EProgram(@"SZFRIENDS_E2E_CLIENT_APP"), *gtkApp = SZFE2EProgram(@"SZFRIENDS_E2E_GTK_APP");
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    CHECK(clientApp && gtkApp && arguments.count >= 3, "e2e.mk names both app programs and the runner its helper");
    if (!SZFE2EStartPair(world, pair, nil, nil) || !SZFE2EBefriend(pair)) return NO;
    NSDictionary *sent = [pair.b intent:@"send_message" fields:@{@"conversation_id" : pair.aAtB,
                                                                @"text" : @"Pages 3–5 are ready",
                                                                @"client_token" : SZFE2EToken()}];
    CHECK([sent[@"ok"] boolValue], "Ben writes to Ana: %@", sent);
    CHECK(SZFE2EWaitUntil(15, ^BOOL {
              return [SZFE2ERowWithID([pair.a dataFor:pair.listA], pair.bAtA)[@"unread"] boolValue];
          }),
          "Ana's list shows it unread: %@", [pair.a dataFor:pair.listA]);
    [pair.a close];
    CHECK([pair.helperA terminate], "Ana's harness helper exits");
    apps.directory = [world.scenarioDirectory stringByAppendingPathComponent:@"apps"];
    *pdfExecutable = SZFE2EMakeAppBundle(apps.directory, @"ShenzhenPDF", clientApp, arguments[1], SZFE2ESharedBuild);
    *filesExecutable = SZFE2EMakeAppBundle(apps.directory, @"Shenzhen Files", gtkApp, arguments[1], SZFE2ESharedBuild);
    CHECK(*pdfExecutable && *filesExecutable, "both test app bundles");
    *environment = @{
        @"SZFRIENDS_STATE_DIR" : pair.helperA.stateDirectory,
        @"SZFRIENDS_KEY_STORE" : @"file",
        @"SZFRIENDS_TEST_SERVICE_TYPE" : world.serviceType,
        @"SZFRIENDS_AVATARS_MANIFEST" : arguments[2],
        @"HOME" : NSHomeDirectory(),
        @"PATH" : @"/usr/bin:/bin",
        @"TMPDIR" : NSTemporaryDirectory(),
    };
    return YES;
}

static NSDictionary *SZFE2EAppItem(SZFE2EApp *app, NSString *conversationID, NSString *text) {
    for (NSDictionary *item in SZFE2EItems([app conversation:conversationID], @"message")) {
        if ([item[@"text"] isEqual:text]) return item;
    }
    return nil;
}

static BOOL SZFE2ESharedChats(SZFE2EWorld *world, SZFE2ETwoApps *apps) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    NSDictionary *environment = nil;
    NSString *pdfExecutable = nil, *filesExecutable = nil;
    if (!SZFE2EPrepare(world, pair, apps, &environment, &pdfExecutable, &filesExecutable)) return NO;
    NSString *ben = pair.bAtA;

    // ShenzhenPDF starts first: nothing answers, so its library spawns the helper it embeds.
    apps.pdf = [SZFE2EApp launch:pdfExecutable build:SZFE2ESharedBuild environment:environment];
    [apps.pdf send:@{@"cmd" : @"list"}];
    pid_t helper = [apps.pdf waitReady:10];
    CHECK(helper > 0 && [SZFE2EProcessPath(helper) hasSuffix:@"ShenzhenPDF.app/Contents/Helpers/Shenzhen Friends.app/"
                                                                @"Contents/MacOS/Shenzhen Friends"],
          "ShenzhenPDF runs its own embedded helper: %d %@", helper, SZFE2EProcessPath(helper));
    // Shenzhen Files joins it: the same helper, not a second one.
    apps.files = [SZFE2EApp launch:filesExecutable build:SZFE2ESharedBuild environment:environment];
    [apps.files send:@{@"cmd" : @"list"}];
    CHECK([apps.files waitReady:10] == helper, "Shenzhen Files talks to the same helper: %d, %d", apps.files.helperPID,
          helper);

    // The same conversation, unread in both, previewing Ben's message (a real helper once left every preview "").
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              [apps.pdf drain];
              [apps.files drain];
              NSDictionary *atPDF = SZFE2ERowWithID(apps.pdf.list, ben);
              NSDictionary *atFiles = SZFE2ERowWithID(apps.files.list, ben);
              return [atPDF[@"unread"] boolValue] && [atFiles[@"unread"] boolValue] &&
                     [atPDF[@"title"] isEqual:@"Ben"] && [atPDF[@"title"] isEqual:atFiles[@"title"]] &&
                     [atPDF[@"subtitle"] isEqual:@"Pages 3–5 are ready"] &&
                     [atPDF[@"subtitle"] isEqual:atFiles[@"subtitle"]];
          }),
          "both apps list Ben's conversation, unread: %@ / %@", apps.pdf.list, apps.files.list);
    // One helper, two audiences, and neither footer carries a note about the ID any more (it was the one list string
    // that named the app; each audience's own words are covered by the presentation suite).
    CHECK(apps.pdf.list[@"footer"][@"id_note"] == [NSNull null] &&
              apps.files.list[@"footer"][@"id_note"] == [NSNull null],
          "no ID note in either app: %@ / %@", apps.pdf.list[@"footer"], apps.files.list[@"footer"]);

    // Read in Shenzhen Files: read in ShenzhenPDF too.
    [apps.files send:@{@"cmd" : @"open", @"conversation_id" : ben}];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              [apps.pdf drain];
              [apps.files drain];
              return SZFE2EAppItem(apps.files, ben, @"Pages 3–5 are ready") != nil &&
                     ![SZFE2ERowWithID(apps.pdf.list, ben)[@"unread"] boolValue] &&
                     SZFE2ERowWithID(apps.pdf.list, ben) != nil;
          }),
          "opened in Shenzhen Files, read in ShenzhenPDF: %@", SZFE2ERowWithID(apps.pdf.list, ben));

    // Sent from Shenzhen Files, it appears in ShenzhenPDF and reaches Ben; and the other way round.
    [apps.pdf send:@{@"cmd" : @"open", @"conversation_id" : ben}];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              [apps.pdf drain];
              return SZFE2EAppItem(apps.pdf, ben, @"Pages 3–5 are ready") != nil;
          }),
          "ShenzhenPDF shows Ben's message too: %@", [apps.pdf conversation:ben][@"items"]);
    [apps.files send:@{@"cmd" : @"send", @"conversation_id" : ben, @"text" : @"Thanks, from Files",
                       @"client_token" : SZFE2EToken(), @"tag" : @"files"}];
    [apps.pdf send:@{@"cmd" : @"send", @"conversation_id" : ben, @"text" : @"And from ShenzhenPDF",
                     @"client_token" : SZFE2EToken(), @"tag" : @"pdf"}];
    NSString *atBen = [pair.b openConversation:pair.aAtB];
    CHECK(SZFE2EWaitUntil(20, ^BOOL {
              [apps.pdf drain];
              [apps.files drain];
              NSDictionary *fromFiles = SZFE2EAppItem(apps.pdf, ben, @"Thanks, from Files");
              NSDictionary *fromPDF = SZFE2EAppItem(apps.files, ben, @"And from ShenzhenPDF");
              NSArray *received = [SZFE2EItems([pair.b dataFor:atBen], @"message") valueForKey:@"text"];
              return [fromFiles[@"item_id"] isEqual:[apps.files replyTagged:@"files"][@"result"][@"message_id"]] &&
                     [fromPDF[@"item_id"] isEqual:[apps.pdf replyTagged:@"pdf"][@"result"][@"message_id"]] &&
                     [fromFiles[@"direction"] isEqual:@"out"] && [received containsObject:@"Thanks, from Files"] &&
                     [received containsObject:@"And from ShenzhenPDF"];
          }),
          "each app shows what the other sent, and Ben has both: %@ / %@ / %@",
          [apps.pdf conversation:ben][@"items"], [apps.files conversation:ben][@"items"],
          [pair.b dataFor:atBen][@"items"]);
    CHECK(apps.pdf.goodbyes.count == 0 && apps.pdf.helperPIDs.count == 1 && apps.files.helperPIDs.count == 1,
          "nobody handed over: %@ %@ %@", apps.pdf.goodbyes, apps.pdf.helperPIDs, apps.files.helperPIDs);
    return YES;
}

static BOOL SZFE2EHandover(SZFE2EWorld *world, SZFE2ETwoApps *apps) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    NSDictionary *environment = nil;
    NSString *pdfExecutable = nil, *filesExecutable = nil;
    if (!SZFE2EPrepare(world, pair, apps, &environment, &pdfExecutable, &filesExecutable)) return NO;
    apps.pdf = [SZFE2EApp launch:pdfExecutable build:SZFE2ESharedBuild environment:environment];
    [apps.pdf send:@{@"cmd" : @"list"}];
    pid_t first = [apps.pdf waitReady:10];
    CHECK(first > 0, "ShenzhenPDF's helper runs");

    // Equal builds: Shenzhen Files keeps the helper that runs.
    apps.files = [SZFE2EApp launch:filesExecutable build:SZFE2ESharedBuild environment:environment];
    CHECK([apps.files waitReady:10] == first, "an equal build joins the running helper: %d", apps.files.helperPID);
    SZFE2EWaitUntil(1.5, ^BOOL {
        [apps.pdf drain];
        [apps.files drain];
        return NO;
    });
    CHECK(apps.pdf.goodbyes.count == 0 && kill(first, 0) == 0 && [apps.pdf.welcomes.lastObject[@"handover"]
                                                                       isEqual:@"none"],
          "and no handover is asked: %@ %@", apps.pdf.goodbyes, apps.pdf.welcomes.lastObject[@"handover"]);
    CHECK([apps.files quitWithin:3], "Shenzhen Files quits");

    // Shenzhen Files updated to carry a newer helper: it asks, the running helper steps aside, and both apps end up
    // on the newer helper, the one inside Shenzhen Files.
    CHECK(SZFE2ESetAppHelperBuild(filesExecutable, SZFE2ENewerBuild), "Shenzhen Files carries build %llu",
          SZFE2ENewerBuild);
    apps.files = [SZFE2EApp launch:filesExecutable build:SZFE2ENewerBuild environment:environment];
    [apps.files send:@{@"cmd" : @"list"}];
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              [apps.pdf drain];
              return apps.pdf.goodbyes.count > 0;
          }),
          "ShenzhenPDF is told the helper hands over");
    NSDictionary *goodbye = apps.pdf.goodbyes.firstObject;
    CHECK([goodbye[@"reason"] isEqual:@"handover"] &&
              [goodbye[@"successor"][@"build_number"] unsignedLongLongValue] == SZFE2ENewerBuild,
          "to Shenzhen Files' build: %@", goodbye);
    CHECK(SZFE2EWaitGone(first, 8), "the older helper exits");
    pid_t second = [apps.files waitReady:12];
    CHECK(second > 0 && second != first &&
              [SZFE2EProcessPath(second) hasSuffix:@"Shenzhen Files.app/Contents/Helpers/Shenzhen Friends.app/"
                                                   @"Contents/MacOS/Shenzhen Friends"],
          "Shenzhen Files runs its newer helper: %d %@", second, SZFE2EProcessPath(second));
    CHECK(SZFE2EWaitUntil(12, ^BOOL {
              [apps.pdf drain];
              return [apps.pdf.state isEqual:@"ready"] && apps.pdf.helperPID == second;
          }),
          "ShenzhenPDF waits for its successor rather than starting its own: %d, %@", apps.pdf.helperPID,
          apps.pdf.helperPIDs);
    CHECK([apps.pdf.welcomes.lastObject[@"helper"][@"build_number"] unsignedLongLongValue] == SZFE2ENewerBuild,
          "and is welcomed by build %llu: %@", SZFE2ENewerBuild, apps.pdf.welcomes.lastObject[@"helper"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              [apps.pdf drain];
              [apps.files drain];
              return SZFE2ERowWithID(apps.pdf.list, pair.bAtA) != nil &&
                     SZFE2ERowWithID(apps.files.list, pair.bAtA) != nil;
          }),
          "the newer helper serves the same friends and history to both: %@ / %@", apps.pdf.list, apps.files.list);
    return YES;
}

BOOL SZFE2EScenarioTwoAppsShareHelper(SZFE2EWorld *world) {
    SZFE2ETwoApps *apps = [[SZFE2ETwoApps alloc] init];
    BOOL ok = SZFE2ESharedChats(world, apps);
    [apps cleanUpAfterFailure:!ok];
    return ok;
}

BOOL SZFE2EScenarioTwoAppsHandover(SZFE2EWorld *world) {
    SZFE2ETwoApps *apps = [[SZFE2ETwoApps alloc] init];
    BOOL ok = SZFE2EHandover(world, apps);
    [apps cleanUpAfterFailure:!ok];
    return ok;
}
