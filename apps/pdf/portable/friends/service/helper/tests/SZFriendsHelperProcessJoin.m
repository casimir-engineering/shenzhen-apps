// Process test: joining a profile through a real helper's socket (PROTOCOL.md § Joining). The `join` view answers a
// subscription and follows the intents; the intents check their fields and reply with words for the person; the list
// carries `join_requests` and the badge counts them. The exchange between two computers is the nearby suite's.

#import <Foundation/Foundation.h>

#import <signal.h>

#import "SZFriendsHelperProcessHarness.h"

// The newest snapshot of `subscription` collected so far, or the next one within `timeout`.
static NSDictionary *SZFHJoinSnapshot(SZFHClient *client, NSString *subscription) {
    NSDictionary *found = nil;
    for (NSDictionary *frame in client.snapshots) {
        if ([frame[@"subscription"] isEqual:subscription]) found = frame;
    }
    [client.snapshots removeAllObjects];
    return found;
}

BOOL SZFHTestJoinIntents(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:[harness socketPathForStateDirectory:state] timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSDictionary *reply = [client intent:@"subscribe" fields:@{@"view" : @"join"}];
    NSString *join = reply[@"result"][@"subscription"];
    CHECK(join != nil, "the join view subscribes: %@", reply);
    NSDictionary *view = SZFHJoinSnapshot(client, join);
    CHECK([view[@"data"][@"state"] isEqual:@"idle"] && view[@"data"][@"id_field"] != nil, "offered: %@", view);

    reply = [client intent:@"join_profile" fields:@{@"friends_id" : @"not an id"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"id_invalid"], "%@", reply);
    reply = [client intent:@"enter_join_code" fields:@{@"code" : @"48312207"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"] && [reply[@"error"][@"message"] length] > 0,
          "no code before a request: %@", reply);
    reply = [client intent:@"join_profile" fields:@{@"friends_id" : @"tulip‑canyon"}];
    CHECK([reply[@"ok"] boolValue], "U+2011 reads as a hyphen: %@", reply);
    view = SZFHJoinSnapshot(client, join);
    CHECK([view[@"data"][@"state"] isEqual:@"waiting"] && [view[@"data"][@"friends_id"] isEqual:@"tulip-canyon"],
          "waiting: %@", view);
    reply = [client intent:@"enter_join_code" fields:@{@"code" : @"4831"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] &&
              [reply[@"error"][@"message"] containsString:@"8 digits"], "a short code says why: %@", reply);
    reply = [client intent:@"enter_join_code" fields:@{@"code" : @"4831 2207"}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    view = SZFHJoinSnapshot(client, join);
    CHECK([view[@"data"][@"state"] isEqual:@"checking"] &&
              [view[@"data"][@"code_field"][@"enabled"] isEqual:@NO], "checking: %@", view);
    CHECK([[client intent:@"cancel_join" fields:nil][@"ok"] boolValue]);
    view = SZFHJoinSnapshot(client, join);
    CHECK([view[@"data"][@"state"] isEqual:@"idle"], "cancelled: %@", view);

    reply = [client intent:@"approve_join" fields:@{@"join_id" : @"00112233445566778899aabbccddeeff"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_found"] &&
              [reply[@"error"][@"message"] containsString:@"no longer waiting"], "%@", reply);
    reply = [client intent:@"deny_join" fields:@{}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"], "%@", reply);
    reply = [client intent:@"subscribe" fields:@{@"view" : @"list"}];
    NSDictionary *list = SZFHJoinSnapshot(client, reply[@"result"][@"subscription"]);
    CHECK([list[@"data"][@"join_requests"] isEqual:@[]], "the list carries its join rows: %@", list[@"data"]);
    [client close];
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
