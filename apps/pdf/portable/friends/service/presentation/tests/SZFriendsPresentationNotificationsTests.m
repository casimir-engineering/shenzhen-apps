// System notifications as the views and the notification centre show them (PROTOCOL.md § Notifications,
// SZFriendsPresentationNotifications.h): fixtures/snapshots/settings-notifications.json and
// list-notifications-ask.json rebuilt from their facts, when the card shows and when it does not, Settings for each
// permission, and the words of every kind of notification, with Show message text on and off.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsMentions.h"
#import "service/presentation/SZFriendsPresentationNotifications.h"

// The hello fixture's app, which declares the card, on a helper that posts notifications.
static SZFriendsAudience *NotifyingAudience(void) {
    SZFriendsAudience *audience = SZPAudience();
    audience.capabilities = [audience.capabilities setByAddingObjectsFromArray:@[ @"notifications.focus",
                                                                                  @"notifications.ask" ]];
    audience.helperCapabilities = [audience.helperCapabilities setByAddingObject:@"notifications"];
    return audience;
}

static SZFriendsNotificationsFacts *Facts(SZFriendsNotifyPermissionFacts permission) {
    SZFriendsNotificationsFacts *facts = [SZFriendsNotificationsFacts new];
    facts.enabled = YES;
    facts.preview = YES;
    facts.permission = permission;
    facts.used = YES;
    return facts;
}

static void TestFixtures(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(NotifyingAudience());
    NSArray<SZFriendsPersonFacts *> *everyone = SZPPeople().allValues;
    SZFriendsNotificationsFacts *notAsked = Facts(SZFriendsNotifyPermissionFactsNotAsked);

    NSMutableDictionary *settings = [[builder settingsWithProfile:SZPProfileRaph() people:everyone] mutableCopy];
    settings[@"notifications"] = [builder notificationsSettingsWithFacts:notAsked];
    SZPExpectFixture(settings, @"settings-notifications.json", @"settings");

    NSMutableDictionary *list = [[builder listWithPeople:everyone previewItems:SZPPreviewItems()
                                                 profile:SZPProfileRaph() query:@"" now:SZPNow()] mutableCopy];
    SZPExpect(list[@"banner"] == [NSNull null], @"no other banner: %@", list[@"banner"]);
    list[@"banner"] = [builder notificationsBannerWithFacts:notAsked];
    SZPExpectFixture(list, @"list-notifications-ask.json", @"list");
}

// The card shows only before the system was asked, with notifications on, after the person used Friends here, until
// Not Now, and only to an app that declared it; Settings shows only with the helper capability.
static void TestCard(void) {
    SZFriendsSnapshotBuilder *builder = SZPBuilder(NotifyingAudience());
    SZPExpect([builder notificationsBannerWithFacts:Facts(SZFriendsNotifyPermissionFactsNotAsked)] != nil, @"card");
    SZPExpect([builder notificationsBannerWithFacts:Facts(SZFriendsNotifyPermissionFactsGranted)] == nil,
              @"no card once allowed");
    SZPExpect([builder notificationsBannerWithFacts:Facts(SZFriendsNotifyPermissionFactsDenied)] == nil,
              @"no card once refused");
    SZFriendsNotificationsFacts *facts = Facts(SZFriendsNotifyPermissionFactsNotAsked);
    facts.askDismissed = YES;
    SZPExpect([builder notificationsBannerWithFacts:facts] == nil, @"Not Now is for good");
    facts = Facts(SZFriendsNotifyPermissionFactsNotAsked);
    facts.enabled = NO;
    SZPExpect([builder notificationsBannerWithFacts:facts] == nil, @"no card while notifications are off");
    facts = Facts(SZFriendsNotifyPermissionFactsNotAsked);
    facts.used = NO;
    SZPExpect([builder notificationsBannerWithFacts:facts] == nil, @"nothing asked before Friends was used");
    SZFriendsSnapshotBuilder *plain = SZPBuilder(SZPAudience());
    SZPExpect([plain notificationsBannerWithFacts:Facts(SZFriendsNotifyPermissionFactsNotAsked)] == nil,
              @"no card for an app without notifications.ask");
    SZPExpect([plain notificationsSettingsWithFacts:Facts(SZFriendsNotifyPermissionFactsNotAsked)] == nil,
              @"no Settings block from a helper without notifications");

    NSDictionary *granted = [builder notificationsSettingsWithFacts:Facts(SZFriendsNotifyPermissionFactsGranted)];
    SZPExpect([granted[@"note"] isEqual:@""] && granted[@"action"] == [NSNull null], @"allowed: %@", granted);
    NSDictionary *denied = [builder notificationsSettingsWithFacts:Facts(SZFriendsNotifyPermissionFactsDenied)];
    SZPExpect([denied[@"note"] isEqual:@"Notifications from Shenzhen Friends are off in System Settings."] &&
                  [denied[@"action"][@"action"] isEqual:@"open_settings"] &&
                  [denied[@"action"][@"settings_target"] isEqual:@"notifications"] &&
                  [denied[@"action"][@"label"] isEqual:@"Open System Settings"],
              @"refused: %@", denied);
    for (NSDictionary *data in @[ granted, denied ]) {
        NSMutableDictionary *settings = [[builder settingsWithProfile:SZPProfileRaph() people:@[]] mutableCopy];
        settings[@"notifications"] = data;
        SZPValidateSnapshot(settings, @"settings", @"settings with notifications");
    }
}

static void TestWords(void) {
    SZFriendsStrings *s = [[SZFriendsStrings alloc] initWithAudience:NotifyingAudience()];
    SZPExpect([[s notificationTitleForName:@" Mei " friendsID:@"jasmine-street"] isEqual:@"Mei"], @"title");
    SZPExpect([[s notificationTitleForName:nil friendsID:@"jasmine-street"] isEqual:@"jasmine‑street"],
              @"an unnamed friend is their ID as the list shows it");
    SZPExpect([[s notificationBodyForMessageText:@"Can you check the bracket?" count:1]
                  isEqual:@"Can you check the bracket?"],
              @"text");
    NSString *mention = SZFriendsMentionLink(@"Lena", @"jasmine-street", SZPKey(SZPKeyLena));
    NSString *body = [s notificationBodyForMessageText:[NSString stringWithFormat:@"Ask %@ first", mention] count:1];
    SZPExpect([body isEqual:@"Ask @Lena first"], @"a mention reads as its name: %@", body);
    SZPExpect([[s notificationBodyForMessageText:nil count:1] isEqual:@"New message"], @"hidden, one");
    SZPExpect([[s notificationBodyForMessageText:nil count:3] isEqual:@"3 new messages"], @"hidden, three");
    NSArray *files = @[ @"Bracket.step", @"Base.step", @"Lid.step" ];
    SZPExpect([[s notificationBodyForFiles:@[ @"Bracket.step" ] count:1 sender:@"Mei" offered:YES]
                  isEqual:@"Mei wants to send you Bracket.step"],
              @"offer");
    SZPExpect([[s notificationBodyForFiles:files count:3 sender:@"Mei" offered:NO]
                  isEqual:@"Mei sent Bracket.step and 2 more files"],
              @"received batch");
    SZPExpect([[s notificationBodyForFiles:files count:2 sender:@"Mei" offered:YES]
                  isEqual:@"Mei wants to send you Bracket.step and 1 more file"],
              @"offered pair");
    SZPExpect([[s notificationBodyForFiles:nil count:1 sender:@"Mei" offered:YES]
                  isEqual:@"Mei wants to send you a file"],
              @"hidden offer");
    SZPExpect([[s notificationBodyForFiles:nil count:3 sender:@"Mei" offered:NO] isEqual:@"Mei sent 3 files"],
              @"hidden batch");
    SZPExpect([[s notificationText:@"notify.request"] isEqual:@"Wants to be friends"], @"request");
    SZPExpect([[s notificationReplyPlaceholderForName:@"Mei"] isEqual:@"Message Mei"], @"placeholder");
    SZPExpect([[s notificationJoinTitleForDevice:@"Pixel 8"] isEqual:@"Pixel 8 wants to join your profile"],
              @"join");
}

void SZPRunNotificationsTests(void) {
    TestFixtures();
    TestCard();
    TestWords();
}
