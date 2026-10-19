// Process test: the person's computers through a real helper's socket (PROTOCOL.md § Devices). The helper announces
// `devices`; the profile lists this computer, which can be renamed and cannot remove itself; the intents check their
// fields and answer with words for the person; the list carries `state`. Removing, You and files on another computer
// between two computers are the nearby suite's.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sodium.h>

#import "service/store/SZFriendsStoreSync.h"

#import "SZFriendsHelperProcessHarness.h"

static NSDictionary *SZFHDevicesSnapshot(SZFHClient *client, NSString *subscription) {
    NSDictionary *found = nil;
    for (NSDictionary *frame in client.snapshots) {
        if ([frame[@"subscription"] isEqual:subscription]) found = frame;
    }
    [client.snapshots removeAllObjects];
    return found;
}

// The next snapshot of `subscription` that `test` accepts, within 2 s: snapshots follow an intent at most ten a second.
static NSDictionary *SZFHDevicesSnapshotWhere(SZFHClient *client, NSString *subscription,
                                              BOOL (^test)(NSDictionary *)) {
    NSDictionary *found = SZFHDevicesSnapshot(client, subscription);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!(found && test(found)) && [deadline timeIntervalSinceNow] > 0) {
        NSDictionary *frame = [client nextFrameOfType:@"snapshot" timeout:[deadline timeIntervalSinceNow]];
        if ([frame[@"subscription"] isEqual:subscription]) found = frame;
    }
    return found;
}

BOOL SZFHTestDevicesIntents(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    NSDictionary *welcome = [client helloWithEmbeddedBuild:0];
    CHECK([welcome[@"capabilities"] containsObject:@"devices"], "the helper announces devices: %@", welcome);
    NSDictionary *reply = [client intent:@"subscribe" fields:@{@"view" : @"profile"}];
    NSString *profile = reply[@"result"][@"subscription"];
    NSDictionary *devices = SZFHDevicesSnapshot(client, profile)[@"data"][@"devices"];
    NSDictionary *me = [devices[@"rows"] firstObject];
    CHECK([devices[@"title"] isEqual:@"Your computers"] && [devices[@"rows"] count] == 1, "one computer: %@", devices);
    CHECK([me[@"this_computer"] isEqual:@YES] && me[@"remove"] == NSNull.null && [me[@"rename"] isKindOfClass:
                                                                                     NSDictionary.class],
          "this computer renames itself and cannot remove itself: %@", me);

    reply = [client intent:@"revoke_device" fields:@{@"device_id" : @"d_0011223344556677"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"] &&
              [reply[@"error"][@"message"] isEqual:@"That computer was already removed."], "%@", reply);
    reply = [client intent:@"revoke_device" fields:@{@"device_id" : me[@"device_id"]}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"], "not this computer: %@", reply);
    reply = [client intent:@"rename_device" fields:@{@"name" : @"   "}];
    CHECK([reply[@"error"][@"code"] isEqual:@"name_invalid"] &&
              [reply[@"error"][@"message"] isEqual:@"Type a name for this computer."], "%@", reply);
    reply = [client intent:@"rename_device" fields:@{@"name" : @"Studio\nMac"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"name_invalid"] &&
              [reply[@"error"][@"message"] containsString:@"line break"], "%@", reply);
    reply = [client intent:@"rename_device" fields:@{@"name" : @" Studio Mac "}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    NSDictionary *renamed = SZFHDevicesSnapshotWhere(client, profile, ^BOOL(NSDictionary *frame) {
        return [[frame[@"data"][@"devices"][@"rows"] firstObject][@"name"] isEqual:@"Studio Mac"];
    });
    me = [renamed[@"data"][@"devices"][@"rows"] firstObject];
    CHECK([me[@"name"] isEqual:@"Studio Mac"], "renamed: %@", me);
    reply = [client intent:@"fetch_from_device" fields:@{@"transfer_id" : @"t_missing"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"] && [reply[@"error"][@"message"] containsString:@"anymore"],
          "%@", reply);

    reply = [client intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *list = SZFHDevicesSnapshot(client, reply[@"result"][@"subscription"])[@"data"];
    CHECK([list[@"state"] isEqual:@"normal"] && list[@"removed"] == NSNull.null, "a normal list: %@", list);
    CHECK([list[@"name_prompt"][@"join_label"] isEqual:@"Use my existing profile"], "joining offered: %@", list);
    [client close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// You through a real helper: a message to yourself is stored here (never queued for a friend), its row says You, what
// was sent before a reconnect is not sent twice, and with no other computer it waits for none.
BOOL SZFHTestYouIntents(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    CHECK(sodium_init() >= 0);
    SZFriendsStore *store = [SZFriendsStore storeInDirectory:state error:NULL];
    CHECK(store != nil && [store ensureYouConversation:NULL], "a You conversation");
    store.profileName = @"Raph";
    [store close];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *fields = @{@"conversation_id" : @"you", @"text" : @"Pages 3 to 5",
                             @"client_token" : @"you-token-0123456789"};
    NSDictionary *reply = [client intent:@"send_message" fields:fields];
    NSString *messageID = reply[@"result"][@"message_id"];
    CHECK([reply[@"ok"] boolValue] && messageID.length > 0, "sent to You: %@", reply);
    reply = [client intent:@"send_message" fields:fields];
    CHECK([reply[@"result"][@"message_id"] isEqual:messageID], "the same send again is the same message: %@", reply);
    reply = [client intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSString *list = reply[@"result"][@"subscription"];
    NSArray *rows = SZFHDevicesSnapshotWhere(client, list, ^BOOL(NSDictionary *frame) {
        return [[frame[@"data"][@"rows"] firstObject][@"kind"] isEqual:@"you"];
    })[@"data"][@"rows"];
    NSDictionary *you = rows.firstObject;
    CHECK([you[@"title"] isEqual:@"You"] && [you[@"subtitle"] isEqual:@"Pages 3 to 5"] && rows.count == 1,
          "the You row: %@", rows);
    reply = [client intent:@"open_conversation" fields:@{@"conversation_id" : @"you"}];
    NSDictionary *conversation = SZFHDevicesSnapshotWhere(client, reply[@"result"][@"subscription"],
                                                          ^BOOL(NSDictionary *frame) {
        return frame[@"data"][@"header"] != nil;
    })[@"data"];
    NSDictionary *message = [conversation[@"items"] lastObject];
    CHECK([conversation[@"header"][@"title"] isEqual:@"You"] &&
              [conversation[@"composer"][@"placeholder"] isEqual:@"Message yourself"], "%@", conversation);
    // On one computer, what is here is on every computer there is: nothing waits, and the composer says nothing more.
    CHECK([message[@"status"][@"label"] isEqual:@"On all your computers"] &&
              conversation[@"composer"][@"note"] == NSNull.null, "%@", message);
    [client close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
