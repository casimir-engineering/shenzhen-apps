// One profile on several computers as the views receive it (PROTOCOL.md § Devices): every person-facing string in the
// fixtures for Your computers, a removed computer, a new computer's join link, You, files another computer holds and
// Delete history on several computers is the catalog's own (SZFriendsCatalogDevices.m), filled as the fixture shows
// it, so the words the views are built against are the words the helper sends. And the catalog's words for these
// places speak of computers, never of how a computer belongs to a profile.

#import "SZFriendsPresentationWorld.h"

#import "service/presentation/SZFriendsPresentationPrivate.h"

static SZFriendsStrings *Strings;

static NSString *T(NSString *key, NSDictionary<NSString *, NSString *> *values) {
    NSMutableDictionary *filled = [values mutableCopy] ?: [NSMutableDictionary dictionary];
    filled[@"apps"] = [Strings text:@"apps.with_friends"];
    return [Strings text:key values:filled];
}

static void Same(id actual, NSString *expected, NSString *where) {
    SZPExpect([actual isEqual:expected], @"%@ is “%@”, the catalog says “%@”", where, actual, expected);
}

static NSDictionary *Data(NSString *fixture) {
    return SZPFixture([@"snapshots/" stringByAppendingString:fixture])[@"data"];
}

static void ExpectConfirm(NSDictionary *confirm, NSString *prefix, NSDictionary *values, NSString *where) {
    Same(confirm[@"title"], T([prefix stringByAppendingString:@".title"], values), where);
    Same(confirm[@"body"], T([prefix stringByAppendingString:@".body"], values), where);
    Same(confirm[@"confirm_label"], T([prefix stringByAppendingString:@".button"], values), where);
    Same(confirm[@"cancel_label"], T(@"static.cancel", nil), where);
    SZPExpect([confirm[@"destructive"] isEqual:@YES], @"%@ is drawn destructive", where);
}

static void TestYourComputers(void) {
    NSDictionary *devices = Data(@"devices-profile.json")[@"devices"];
    Same(devices[@"title"], T(@"devices.title", nil), @"devices.title");
    Same(devices[@"note"], T(@"devices.note", nil), @"devices.note");
    NSDictionary *lastKeys = @{@"connected" : @"devices.last.now", @"never_connected" : @"devices.last.never"};
    NSDictionary *spokenKeys = @{@"connected" : @"devices.accessibility.now",
                                 @"never_connected" : @"devices.accessibility.never",
                                 @"not_connected" : @"devices.accessibility.seen"};
    NSUInteger thisComputer = 0;
    for (NSDictionary *row in devices[@"rows"]) {
        NSString *name = row[@"name"], *system = row[@"system"], *last = row[@"last_connected"];
        NSDictionary *values = @{@"name" : name, @"system" : system, @"last" : last, @"device" : name};
        Same(row[@"detail"], T(@"devices.detail", values), @"a row's detail");
        if ([row[@"this_computer"] isEqual:@YES]) {
            thisComputer++;
            Same(last, T(@"devices.last.this_computer", nil), @"this computer's last connection");
            Same(row[@"accessibility_label"], T(@"devices.accessibility.this_computer", values), @"this computer");
            SZPExpect(row[@"remove"] == NSNull.null, @"this computer cannot remove itself here");
            Same(row[@"rename"][@"label"], T(@"devices.rename.label", nil), @"rename");
            Same(row[@"rename"][@"placeholder"], T(@"devices.rename.placeholder", nil), @"rename placeholder");
            Same(row[@"rename"][@"button_label"], T(@"devices.rename.button", nil), @"rename button");
            continue;
        }
        SZPExpect(row[@"rename"] == NSNull.null, @"only this computer renames itself: %@", name);
        if (lastKeys[row[@"state"]]) Same(last, T(lastKeys[row[@"state"]], nil), name);
        NSMutableDictionary *spoken = [values mutableCopy];
        spoken[@"last"] = [last lowercaseString]; // "Yesterday" said inside a sentence
        Same(row[@"accessibility_label"], T(spokenKeys[row[@"state"]], spoken), name);
        NSDictionary *remove = row[@"remove"];
        Same(remove[@"action"], @"revoke_device", name);
        Same(remove[@"device_id"], row[@"device_id"], name);
        Same(remove[@"label"], T(@"devices.remove", nil), name);
        ExpectConfirm(remove[@"confirm"], @"devices.remove.confirm", values, name);
    }
    SZPExpect(thisComputer == 1 && [devices[@"rows"][0][@"this_computer"] isEqual:@YES], @"this computer comes first");
}

static void TestRemovedAndNewComputer(void) {
    NSDictionary *list = Data(@"devices-list-removed.json"), *removed = list[@"removed"];
    Same(list[@"state"], @"device_removed", @"state");
    Same(removed[@"title"], T(@"device_removed.title", nil), @"removed title");
    Same(removed[@"body"], T(@"device_removed.body", nil), @"removed body");
    Same(removed[@"action"][@"action"], @"reset_friends", @"what they can do");
    Same(removed[@"action"][@"label"], T(@"device_removed.action", nil), @"removed action");
    ExpectConfirm(removed[@"action"][@"confirm"], @"device_removed.confirm", nil, @"start over");
    for (NSDictionary *row in list[@"rows"]) {
        Same(row[@"drop_refusal"], T(@"device_removed.drop_refusal", nil), @"a removed computer's row");
        SZPExpect(row[@"drop_label"] == NSNull.null, @"a removed computer takes no drops");
    }
    NSDictionary *prompt = Data(@"devices-list-new-computer.json")[@"name_prompt"];
    Same(prompt[@"join_label"], T(@"name_prompt.join", nil), @"join link");
    // The way in that Your computers and the removed computer name is the link's own label.
    SZPExpect([T(@"devices.note", nil) containsString:T(@"name_prompt.join", nil)] &&
                  [T(@"device_removed.body", nil) containsString:T(@"name_prompt.join", nil)],
              @"the notes name the join link as it reads");
}

static void TestYou(void) {
    NSDictionary *row = Data(@"devices-list.json")[@"rows"][0];
    Same(row[@"kind"], @"you", @"the You row");
    Same(row[@"conversation_id"], @"you", @"the You row");
    Same(row[@"title"], T(@"you.title", nil), @"the You row");
    Same(row[@"drop_label"], T(@"you.drop_label", nil), @"the You row");
    Same(row[@"accessibility_label"], T(@"you.row.accessibility", (@{@"preview" : row[@"subtitle"],
                                                                     @"time" : row[@"time_label"]})), @"You read");
    NSDictionary *you = Data(@"devices-conversation-you.json");
    Same(you[@"header"][@"title"], T(@"you.title", nil), @"You header");
    Same(you[@"header"][@"subtitle"], T(@"you.header.subtitle", nil), @"You header");
    Same(you[@"header"][@"accessibility_label"], T(@"you.header.accessibility", nil), @"You header");
    SZPExpect([you[@"header"][@"details_available"] isEqual:@NO], @"You has no details");
    Same(you[@"composer"][@"placeholder"], T(@"you.composer.placeholder", nil), @"You composer");
    Same(you[@"composer"][@"note"], T(@"you.composer.note.waiting", nil), @"You composer note");
    NSDictionary *message = you[@"items"][1], *file = you[@"items"][2];
    Same(message[@"status"][@"label"], T(@"you.status.delivered", nil), @"a message to yourself");
    Same(file[@"status_label"], T(@"you.transfer.status.sending", @{@"percent" : @"40"}), @"a file to yourself");
}

static void TestFilesElsewhere(void) {
    NSArray *items = Data(@"devices-conversation-mei-files.json")[@"items"];
    NSDictionary *device = @{@"device" : @"Raph’s Mac mini"};
    Same(items[1][@"state"], @"on_device", @"a file on another computer");
    Same(items[1][@"status_label"], T(@"transfer.status.on_device", device), @"a file on another computer");
    Same(items[1][@"actions"][0][@"action"], @"fetch_from_device", @"Get");
    Same(items[1][@"actions"][0][@"label"], T(@"transfer.action.fetch", nil), @"Get");
    Same(items[2][@"status_label"], T(@"transfer.status.fetching", (@{@"device" : @"Raph’s Mac mini",
                                                                      @"percent" : @"25"})), @"copying here");
    Same(items[3][@"status_label"], T(@"transfer.status.fetch_waiting", @{@"device" : @"Studio workstation"}),
         @"waiting for the computer that has it");
    SZPExpect(items[3][@"progress"] == NSNull.null, @"no progress while that computer is away");
}

static void TestHistoryEverywhere(void) {
    NSDictionary *history = Data(@"devices-settings.json")[@"history"];
    Same(history[@"note"], T(@"settings.history.note.devices", nil), @"Settings history note");
    Same(history[@"confirm"][@"body"], T(@"settings.history.confirm.body.devices", nil), @"Settings history confirm");
    NSDictionary *who = @{@"first" : @"Mei"};
    NSDictionary *erase = Data(@"devices-details-mei.json")[@"actions"][0];
    Same(erase[@"note"], T(@"details.history.note.friend.devices", who), @"a friend's history note");
    NSArray *sentences = @[ T(@"details.history.confirm.goes.devices", who),
                            T(@"details.history.confirm.stays.friend", who), T(@"details.history.confirm.files", nil) ];
    NSString *body = [sentences componentsJoinedByString:@" "];
    Same(erase[@"confirm"][@"body"], body, @"a friend's history confirm");
    // Every several-computer variant says where: all of them, not this one only.
    for (NSString *key in SZFriendsEnglishCatalogDevices()) {
        if (![key containsString:@"history"]) continue;
        NSString *text = SZFriendsEnglishCatalogDevices()[key];
        SZPExpect([text containsString:@"all your computers"] || [text containsString:@"your other computers"],
                  @"%@ does not say it reaches every computer: %@", key, text);
        SZPExpect(SZFriendsEnglishCatalog()[[key stringByReplacingOccurrencesOfString:@".devices" withString:@""]],
                  @"%@ has no one-computer original", key);
    }
}

// Words that describe how computers belong to a profile, which the person never needs: they add, remove and rename
// computers, and things reach them.
static void TestReaderWords(void) {
    NSArray<NSString *> *mechanism = @[ @"key", @"chain", @"token", @"revok", @"sync", @"device", @"signature",
                                        @"authori", @"session", @"peer" ];
    NSMutableDictionary *entries = [SZFriendsEnglishCatalogDevices() mutableCopy];
    [entries addEntriesFromDictionary:SZFriendsEnglishCatalogJoin()];
    for (NSString *key in entries) {
        NSString *text = [entries[key] lowercaseString];
        for (NSString *word in mechanism) {
            // {device} is a placeholder the computer's name fills, not a word anyone reads.
            NSString *read = [text stringByReplacingOccurrencesOfString:@"{device}" withString:@""];
            SZPExpect(![read containsString:word], @"%@ says “%@”: %@", key, word, entries[key]);
        }
    }
    NSDictionary *others = SZFriendsEnglishCatalogViews();
    for (NSString *key in SZFriendsEnglishCatalogDevices())
        SZPExpect(!others[key] && !SZFriendsEnglishCatalogJoin()[key] && !SZFriendsEnglishCatalogLinks()[key],
                  @"%@ is defined twice in the catalog", key);
}

void SZPRunDevicesTests(void) {
    Strings = [[SZFriendsStrings alloc] initWithAudience:SZPAudience()];
    TestYourComputers();
    TestRemovedAndNewComputer();
    TestYou();
    TestFilesElsewhere();
    TestHistoryEverywhere();
    TestReaderWords();
}
