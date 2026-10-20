// friends-one-identity-check, one computer: what is typed, read, renamed, offered or deleted in one app's own Friends
// view shows at once in the other two apps' views (SZFriendsE2EOneIdentity.h).

#import "SZFriendsE2EOneIdentityMac.h"

BOOL SZFE2EOneIDScenarioRealViews(SZFE2EWorld *world) {
    SZFOMac *mac = SZFOPrepareWith(world, SZFOSameBuild(), YES);
    if (mac == nil) return NO;
    BOOL ok = NO;
    @try {
        for (NSString *app in SZFOApps()) CHECK(SZFOLaunch(mac, app, SZFOBuild) != nil, "%@ launches", app);
        CHECK(SZFOAllReady(mac, 40), "all three ready on one helper: %@", SZFOStates(mac));
        if (!SZFOSameIdentity(mac, @"Ana")) return NO;
        NSString *ben = mac.benAtAna;
        SZFE2EApp *pdf = mac.running[SZFOPDF], *files = mac.running[SZFOFiles], *threeD = mac.running[SZFO3D];

        // Ben's message is unread in all three; reading it in Shenzhen Files' view reads it everywhere.
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  SZFODrain(mac);
                  return [SZFORow(pdf, ben)[@"unread"] boolValue] && [SZFORow(files, ben)[@"unread"] boolValue] &&
                         [SZFORow(threeD, ben)[@"unread"] boolValue];
              }),
              "unread in all three: %@", SZFORow(threeD, ben));
        for (NSString *app in SZFOApps()) {
            __block NSArray *texts = nil;
            CHECK(SZFE2EWaitUntil(15, ^BOOL {
                      texts = SZFOAsk(mac.running[app], @{@"cmd" : @"ui_list"}, 20)[@"result"][@"texts"];
                      return SZFOShows(texts, @"Ben") && SZFOShows(texts, @"Ana");
                  }),
                  "%@'s list shows Ben and Ana's name: %@", app, texts);
        }
        if (!SZFOViewsShow(mac, @[ SZFOFiles ], ben, @"Ben", @"Pages 3–5 are ready", YES, 10)) return NO;
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  SZFODrain(mac);
                  for (SZFE2EApp *app in @[ pdf, files, threeD ])
                      if (SZFORow(app, ben) == nil || [SZFORow(app, ben)[@"unread"] boolValue]) return NO;
                  return YES;
              }),
              "read in Shenzhen Files, read in all three: %@ / %@", SZFORow(pdf, ben), SZFORow(threeD, ben));

        // Typed into each app's own composer, shown at once in the other two views, and delivered to Ben.
        NSDictionary<NSString *, NSString *> *typed = @{
            SZFOPDF : @"Typed in ShenzhenPDF's composer",
            SZFO3D : @"Typed in Shenzhen 3D's panel",
            SZFOFiles : @"Typed in Shenzhen Files' composer",
        };
        NSString *atBen = [mac.ben.client openConversation:mac.anaAtBen];
        for (NSString *app in @[ SZFOPDF, SZFO3D, SZFOFiles ]) {
            NSDictionary *reply = SZFOAsk(mac.running[app], @{@"cmd" : @"ui_type", @"conversation_id" : ben,
                                                              @"title" : @"Ben", @"text" : typed[app]},
                                          20);
            CHECK([reply[@"ok"] boolValue], "%@ sends what was typed: %@ (%@)", app, reply, mac.running[app].log);
            NSMutableArray *others = [SZFOApps() mutableCopy];
            [others removeObject:app];
            if (!SZFOViewsShow(mac, others, ben, @"Ben", typed[app], YES, 10)) return NO;
        }
        CHECK(SZFE2EWaitUntil(20, ^BOOL {
                  NSArray *texts = SZFE2ETexts(mac.ben.client, atBen);
                  for (NSString *text in typed.allValues)
                      if (![texts containsObject:text]) return NO;
                  return YES;
              }),
              "Ben has all three: %@", SZFE2ETexts(mac.ben.client, atBen));
        CHECK(SZFE2ESay(mac.ben, mac.anaAtBen, @"All three arrived"));
        if (!SZFOViewsShow(mac, SZFOApps(), ben, @"Ben", @"All three arrived", YES, 15)) return NO;

        // The You conversation is one (it exists once Ana has a second computer): a note typed in Shenzhen Files
        // shows in the other two, and reaches her laptop.
        NSDictionary *note = SZFOAsk(files, @{@"cmd" : @"ui_type", @"conversation_id" : @"you", @"title" : @"You",
                                              @"text" : @"Note to self, from Shenzhen Files"},
                                     20);
        CHECK([note[@"ok"] boolValue], "a note to You: %@", note);
        if (!SZFOViewsShow(mac, @[ SZFOPDF, SZFO3D ], @"you", @"You", @"Note to self, from Shenzhen Files", YES, 10))
            return NO;
        NSString *youAtLaptop = [mac.laptop.client openConversation:@"you"];
        CHECK(SZFE2EWaitUntil(15, ^BOOL {
                  NSArray *texts = SZFE2ETexts(mac.laptop.client, youAtLaptop);
                  return [texts containsObject:@"Note to self, from Shenzhen Files"];
              }),
              "the note reaches the laptop: %@", SZFE2ETexts(mac.laptop.client, youAtLaptop));
        CHECK(SZFE2ESay(mac.laptop, @"you", @"Note from the laptop"));
        if (!SZFOViewsShow(mac, SZFOApps(), @"you", @"You", @"Note from the laptop", YES, 15)) return NO;

        // A name changed in one app is the name in all three, in their lists' own words.
        NSDictionary *renamed = SZFOAsk(threeD, @{@"cmd" : @"intent", @"type" : @"set_name",
                                                  @"fields" : @{@"name" : @"Ana Studio"}},
                                        10);
        CHECK([renamed[@"ok"] boolValue], "set_name from Shenzhen 3D: %@", renamed);
        if (!SZFOSameIdentity(mac, @"Ana Studio")) return NO;
        for (NSString *app in SZFOApps()) {
            __block NSArray *texts = nil;
            CHECK(SZFE2EWaitUntil(10, ^BOOL {
                      texts = SZFOAsk(mac.running[app], @{@"cmd" : @"ui_list"}, 20)[@"result"][@"texts"];
                      return SZFOShows(texts, @"Ana Studio");
                  }),
                  "%@'s list shows the new name: %@", app, texts);
        }

        // A file offered from ShenzhenPDF is one transfer in all three.
        NSString *file = [world fileOfSize:4096 named:@"bracket-notes.txt"];
        NSDictionary *offered = SZFOAsk(pdf, @{@"cmd" : @"intent", @"type" : @"send_files",
                                               @"fields" : @{@"conversation_id" : ben,
                                                             @"files" : @[ @{@"path" : file} ],
                                                             @"client_token" : SZFE2ERandomToken()}},
                                        10);
        CHECK([offered[@"ok"] boolValue], "send_files from ShenzhenPDF: %@", offered);
        for (SZFE2EApp *app in @[ pdf, files, threeD ]) [app send:@{@"cmd" : @"open", @"conversation_id" : ben}];
        CHECK(SZFE2EWaitUntil(15, ^BOOL {
                  SZFODrain(mac);
                  for (SZFE2EApp *app in @[ pdf, files, threeD ]) {
                      BOOL found = NO;
                      for (NSDictionary *item in [app conversation:ben][@"items"])
                          found = found || ([item[@"kind"] isEqual:@"transfer"] &&
                                            [item[@"file"][@"name"] isEqual:@"bracket-notes.txt"]);
                      if (!found) return NO;
                  }
                  return YES;
              }),
              "the offer is in all three: %@", [threeD conversation:ben][@"items"]);

        // Deleting the chat in Shenzhen 3D's panel (its details, Delete chat history…, confirmed) empties it in the
        // other two views.
        NSDictionary *deleted = SZFOAsk(threeD, @{@"cmd" : @"ui_delete", @"conversation_id" : ben, @"title" : @"Ben"},
                                        30);
        CHECK([deleted[@"ok"] boolValue], "Delete chat history in Shenzhen 3D's panel: %@ (%@)", deleted, threeD.log);
        for (NSString *text in @[ @"All three arrived", typed[SZFOPDF] ])
            if (!SZFOViewsShow(mac, SZFOApps(), ben, @"Ben", text, NO, 10)) return NO;
        CHECK(SZFE2EWaitUntil(10, ^BOOL {
                  SZFODrain(mac);
                  for (SZFE2EApp *app in @[ pdf, files, threeD ])
                      if (SZFE2EKindItems([app conversation:ben], @"message").count != 0) return NO;
                  return YES;
              }),
              "no message left in any of the three: %@", [pdf conversation:ben][@"items"]);
        CHECK(SZFOSharedHelper(mac) > 0 && SZFOHelperProcesses(mac).count == 1, "still one helper: %@",
              SZFOStates(mac));
        ok = YES;
    } @finally {
        SZFOShutDown(mac, !ok);
    }
    return ok;
}
