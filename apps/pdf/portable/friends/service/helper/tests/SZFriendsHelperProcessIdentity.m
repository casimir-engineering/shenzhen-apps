// Process tests of an identity the helper cannot read at start: what the views are told, Reset Friends from there,
// and a read that works again later. The file key store stands in for the Keychain: a key file others may read is
// refused exactly as an item another code signature made is refused (both are "exists but cannot be used").

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sys/stat.h>

#import "SZFriendsHelperProcessHarness.h"

static NSString *SZFHKeyPath(NSString *state) {
    return [[state stringByAppendingPathComponent:@"keys"] stringByAppendingPathComponent:@"identity"];
}

static NSDictionary *SZFHSnapshotOf(SZFHClient *client, NSString *view) {
    NSDictionary *reply = [client intent:@"subscribe" fields:@{@"view" : view}];
    NSString *subscription = reply[@"result"][@"subscription"];
    if (subscription == nil) return nil;
    for (NSDictionary *snapshot in client.snapshots)
        if ([snapshot[@"subscription"] isEqual:subscription]) return snapshot[@"data"];
    NSDictionary *frame = [client nextFrameOfType:@"snapshot" timeout:3];
    return [frame[@"subscription"] isEqual:subscription] ? frame[@"data"] : nil;
}

static BOOL SZFHHasCapability(NSDictionary *welcome, NSString *capability) {
    NSArray *capabilities = welcome[@"capabilities"];
    return [capabilities isKindOfClass:[NSArray class]] && [capabilities containsObject:capability];
}

// What the views show while the identity is unreadable: the reset banner, and a Nearby tab that says why it does not
// work instead of asking for Local Network or Bluetooth access nobody refused.
static BOOL SZFHCheckUnavailableViews(SZFHClient *c) {
    NSDictionary *list = SZFHSnapshotOf(c, @"list");
    CHECK([list[@"banner"][@"kind"] isEqual:@"identity_unavailable"], "banner: %@", list[@"banner"]);
    CHECK([list[@"banner"][@"action"][@"action"] isEqual:@"reset_friends"], "%@", list[@"banner"]);
    NSDictionary *nearby = SZFHSnapshotOf(c, @"nearby");
    CHECK(nearby != nil, "a nearby snapshot");
    CHECK(nearby[@"alert"] == [NSNull null] && nearby[@"note"] == [NSNull null],
          "no permission card or Bluetooth line without an identity: %@ / %@", nearby[@"alert"], nearby[@"note"]);
    NSString *said = [NSString stringWithFormat:@"%@ %@ %@", nearby[@"visibility"][@"body"], nearby[@"empty"][@"title"],
                                                nearby[@"empty"][@"body"]];
    CHECK([said rangeOfString:@"Reset Friends"].location != NSNotFound, "says what to do: %@", said);
    CHECK([said rangeOfString:@"System Settings"].location == NSNotFound &&
              [said rangeOfString:@"Bluetooth"].location == NSNotFound,
          "never blames permissions or Bluetooth: %@", said);
    return YES;
}

// An unreadable identity at start; Reset Friends from the banner makes a new one and Nearby and the check-in run
// without a restart: the clients come back to a helper with the devices capability and no reset banner.
BOOL SZFHTestResetUnreadableIdentity(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    NSString *keys = [state stringByAppendingPathComponent:@"keys"];
    CHECK([[NSFileManager defaultManager] createDirectoryAtPath:keys withIntermediateDirectories:YES
                                                     attributes:@{NSFilePosixPermissions : @0700} error:NULL]);
    NSData *junk = [NSMutableData dataWithLength:133];
    CHECK([junk writeToFile:SZFHKeyPath(state) atomically:NO]);
    CHECK(chmod(SZFHKeyPath(state).fileSystemRepresentation, 0644) == 0);
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *c = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *welcome = [c helloWithEmbeddedBuild:0];
    CHECK([welcome[@"type"] isEqual:@"welcome"], "%@", welcome);
    CHECK(!SZFHHasCapability(welcome, @"devices"), "no Nearby without an identity: %@", welcome[@"capabilities"]);
    CHECK([[harness logForStateDirectory:state] containsString:@"identity unavailable"]);
    if (!SZFHCheckUnavailableViews(c)) return NO;
    // Opening Friends reads the identity again; it is still unreadable, so nothing changes and nobody is sent away.
    CHECK([[c intent:@"activate" fields:nil][@"ok"] boolValue]);
    CHECK([c nextFrameOfType:@"goodbye" timeout:0.5] == nil, "no reconnect while the identity stays unreadable");

    NSDictionary *reply = [c intent:@"reset_friends" fields:@{@"confirm" : @"reset"}];
    CHECK([reply[@"ok"] boolValue], "Reset Friends works from an unreadable identity: %@", reply);
    CHECK([[c nextFrameOfType:@"goodbye" timeout:3][@"reason"] isEqual:@"reset"]);
    struct stat info;
    CHECK(stat(SZFHKeyPath(state).fileSystemRepresentation, &info) == 0 && (info.st_mode & 077) == 0,
          "a new private key replaced the unreadable one");
    SZFHClient *after = [SZFHClient connectToSocket:socket timeout:5];
    welcome = [after helloWithEmbeddedBuild:0];
    CHECK(SZFHHasCapability(welcome, @"devices"), "Nearby runs after the reset: %@", welcome[@"capabilities"]);
    NSDictionary *list = SZFHSnapshotOf(after, @"list");
    CHECK(list[@"banner"] == [NSNull null] || ![list[@"banner"][@"kind"] isEqual:@"identity_unavailable"],
          "the reset banner is gone: %@", list[@"banner"]);
    NSDictionary *profile = SZFHSnapshotOf(after, @"profile");
    CHECK([profile[@"id"][@"friends_id"] length] > 0, "a new Friends ID: %@", profile[@"id"]);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// An identity that cannot be read at start but can be later (a keychain still locked when the helper started):
// opening Friends reads it again, keeps the same identity and ID, and starts what needs it.
BOOL SZFHTestIdentityReadableAgain(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];
    SZFHClient *c = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[c helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    NSString *friendsID = SZFHSnapshotOf(c, @"profile")[@"id"][@"friends_id"];
    CHECK(friendsID.length > 0);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);

    CHECK(chmod(SZFHKeyPath(state).fileSystemRepresentation, 0644) == 0);
    pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    c = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *welcome = [c helloWithEmbeddedBuild:0];
    CHECK(!SZFHHasCapability(welcome, @"devices"), "unreadable at start: %@", welcome[@"capabilities"]);
    if (!SZFHCheckUnavailableViews(c)) return NO;

    CHECK(chmod(SZFHKeyPath(state).fileSystemRepresentation, 0600) == 0);
    CHECK([[c intent:@"activate" fields:nil][@"ok"] boolValue]);
    CHECK([[c nextFrameOfType:@"goodbye" timeout:3][@"reason"] isEqual:@"reset"], "clients reconnect");
    SZFHClient *after = [SZFHClient connectToSocket:socket timeout:5];
    welcome = [after helloWithEmbeddedBuild:0];
    CHECK(SZFHHasCapability(welcome, @"devices"), "Nearby runs once the identity reads: %@", welcome[@"capabilities"]);
    NSDictionary *profile = SZFHSnapshotOf(after, @"profile");
    CHECK([profile[@"id"][@"friends_id"] isEqual:friendsID], "the same identity and ID: %@", profile[@"id"]);
    NSDictionary *list = SZFHSnapshotOf(after, @"list");
    CHECK(list[@"banner"] == [NSNull null] || ![list[@"banner"][@"kind"] isEqual:@"identity_unavailable"],
          "%@", list[@"banner"]);
    CHECK([[harness logForStateDirectory:state] containsString:@"identity available again"]);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}
