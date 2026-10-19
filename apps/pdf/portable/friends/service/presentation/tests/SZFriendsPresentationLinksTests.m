// Links as the reader sees them (PROTOCOL.md § Links; helper capability `links`): the profile's "Your links" rebuilt
// as fixtures/snapshots/profile-links.json shows it, the cards open_link answers with and the intents' messages as
// fixtures/replies/ show them, and the person who sent a file through a link, who is not a friend.

#import "SZFriendsPresentationWorld.h"

#import "service/store/SZFriendsTransfers.h"

static SZFriendsAudience *LinksAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.helperCapabilities = [NSSet setWithArray:@[ @"nearby.network", @"host.checkin", @"links" ]];
    return audience;
}

static SZFriendsDownloadLinkFacts *Download(NSString *linkID, NSString *name, NSUInteger downloads, double days) {
    SZFriendsDownloadLinkFacts *link = [SZFriendsDownloadLinkFacts new];
    link.linkID = linkID;
    link.fileName = name;
    link.downloads = downloads;
    link.expiresAt = [SZPNow() dateByAddingTimeInterval:days * 86400];
    return link;
}

static SZFriendsProfileFacts *ProfileWithLinks(NSArray *downloads) {
    SZFriendsProfileFacts *profile = SZPProfileRaph();
    profile.links = [SZFriendsLinksFacts new];
    profile.links.friendURL = @"https://friends.example/f#AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0Oq";
    profile.links.downloads = downloads;
    profile.links.now = SZPNow();
    return profile;
}

static void TestYourLinks(void) {
    NSArray *downloads = @[
        Download(@"EBESExQVFhcYGRobHB0eHw", @"Site photos.pdf", 3, 6),
        Download(@"IiMkJSYnKCkqKywtLi8wMQ",
                 @"Supplier contract v3 with the long annex and the signed amendments.pdf", 0, 1),
    ];
    SZPExpectFixture([SZPBuilder(LinksAudience()) profileWithFacts:ProfileWithLinks(downloads) waitingElsewhere:2],
                     @"profile-links.json", @"profile");
    NSDictionary *none = [SZPBuilder(LinksAudience()) profileWithFacts:ProfileWithLinks(@[]) waitingElsewhere:2];
    SZPExpect([none[@"links"][@"downloads_empty"] length] > 0 && [none[@"links"][@"downloads"] count] == 0,
              @"no download link yet: %@", none[@"links"]);
    NSDictionary *one = [SZPBuilder(LinksAudience()) profileWithFacts:ProfileWithLinks(@[
        Download(@"EBESExQVFhcYGRobHB0eHw", @"a.pdf", 1, 0.1)
    ]) waitingElsewhere:2];
    NSDictionary *row = [one[@"links"][@"downloads"] firstObject];
    SZPExpect([row[@"downloads_label"] isEqual:@"1 download"] && [row[@"expires_label"] isEqual:@"Expires today"],
              @"%@", row);
    // A helper that does not announce `links` (or an older one) shows none, whatever the facts hold.
    NSDictionary *plain = [SZPBuilder(SZPAudience()) profileWithFacts:ProfileWithLinks(downloads) waitingElsewhere:2];
    SZPExpect(plain[@"links"] == nil, @"no links without the capability");
}

static void TestCardsAndMessages(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(LinksAudience());
    NSString *payload = @"f.AbTdSXSAjDJSLILKcnTFnJ61gwHnPY127KX0X8oI-0OqyMnKy8zNzs_Q0dLT1NXW1w1ib25maXJlLW90"
                        @"dGVyCExlbyBQYXJr";
    NSDictionary *expected = SZPFixture(@"replies/open_link.json")[@"result"][@"card"];
    NSDictionary *card = [builder friendLinkCardWithName:@"Leo Park" friendsID:@"bonfire-otter" payload:payload
                                           alreadyFriend:NO];
    SZPValidateResult(@{@"card" : card}, @"open_link", @"friend card");
    for (NSString *key in @[ @"kind", @"title", @"subtitle", @"note", @"actions" ]) {
        SZPExpect([card[key] isEqual:expected[key]], @"card %@: %@ vs %@", key, card[key], expected[key]);
    }
    NSDictionary *friend = [builder friendLinkCardWithName:@"" friendsID:@"bonfire-otter" payload:payload
                                             alreadyFriend:YES];
    SZPExpect([friend[@"title"] isEqual:@"You’re already friends with bonfire‑otter"] &&
                  [friend[@"actions"] count] == 0,
              @"already a friend, named by the ID: %@", friend);
    NSDictionary *download = [builder downloadLinkCardWithPayload:@"d.x"];
    SZPValidateResult(@{@"card" : download}, @"open_link", @"download card");
    SZPExpect([[download[@"actions"] firstObject][@"action"] isEqual:@"receive_link"], @"%@", download);
    // Nothing opens the file by itself yet, so the words say where it will be.
    SZPExpect([[builder linkReceivingMessageForFile:@"Site photos.pdf" sender:@"Mei Wong"]
                  isEqual:@"Receiving Site photos.pdf from Mei Wong. You’ll find it in your chat with Mei once it "
                          @"arrives."],
              @"receive_link's message");
    SZPExpect([[builder downloadLinkMadeMessageUntil:[SZPNow() dateByAddingTimeInterval:7 * 86400]]
                  isEqual:SZPFixture(@"replies/make_download_link.json")[@"result"][@"message"]],
              @"make_download_link's message");
    NSString *sent = [builder linkRequestSentMessageForName:@"Leo Park"];
    SZPExpect([sent containsString:@"as soon as Friends reaches them"],
              @"a request goes as soon as Friends reaches the other person, and the words say so");
}

// Someone who sent a file through a link: their row says so (never "No longer friends"), their file offers Add, and
// the composer says why it is off.
static void TestTheSenderOfALinkFile(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(LinksAudience());
    SZFriendsPersonFacts *mei = SZPPeople()[@"c_mei"];
    mei.relation = SZFriendsPersonRelationRemoved;
    mei.linkContact = YES;
    mei.identityKey = SZPKey(SZPKeyMei);
    SZFriendsItemFacts *event = SZPEvent(@"e_link", @"2026-10-12 14:40", @"received_through_link");
    event.eventArguments = @{@"file" : @"Site photos.pdf"};
    mei.lastPreviewItemID = event.itemID;
    NSDictionary *list = [builder listWithPeople:@[ mei ] previewItems:@{event.itemID : event}
                                         profile:SZPProfileRaph() query:@"" now:SZPNow()];
    NSDictionary *row = [list[@"rows"] firstObject];
    SZPExpect([row[@"subtitle"] isEqual:@"Sent you Site photos.pdf through a link"], @"row: %@", row[@"subtitle"]);
    SZFriendsItemFacts *file = SZPTransfer(@"t_link", NO, @"2026-10-12 14:39", @"Site photos.pdf", 2516582,
                                           SZFriendsTransferStateReceived);
    NSDictionary *conversation = [builder conversationForPerson:mei items:@[ file, event ] hasEarlier:NO
                                                highlightItemID:nil waitingElsewhere:0 now:SZPNow()];
    SZPValidateSnapshot(conversation, @"conversation", @"link contact");
    NSDictionary *add = nil;
    for (NSDictionary *item in conversation[@"items"]) {
        for (NSDictionary *action in [item[@"kind"] isEqual:@"transfer"] ? item[@"actions"] : @[]) {
            if ([action[@"action"] isEqual:@"add_from_mention"]) add = action;
        }
    }
    SZPExpect([add[@"label"] isEqual:@"Add Mei"] && [add[@"friends_id"] isEqual:@"jasmine-street"] &&
                  [add[@"identity_key"] isEqual:SZPKeyMei],
              @"Add on their file: %@", add);
    SZPExpect([conversation[@"composer"][@"note"] isEqual:@"Add Mei as a friend to send messages."], @"%@",
              conversation[@"composer"][@"note"]);
    mei.linkContact = NO;
    row = [[builder listWithPeople:@[ mei ] previewItems:@{event.itemID : event} profile:SZPProfileRaph() query:@""
                               now:SZPNow()][@"rows"] firstObject];
    SZPExpect([row[@"subtitle"] isEqual:@"No longer friends"], @"a removed friend stays as before");
}

void SZPRunLinksTests(void) {
    TestYourLinks();
    TestCardsAndMessages();
    TestTheSenderOfALinkFile();
}
