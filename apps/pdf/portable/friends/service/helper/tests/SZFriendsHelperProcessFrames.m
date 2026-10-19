// Process tests of framing, the handshake's errors and the socket's location and safety checks.

#import <Foundation/Foundation.h>

#import <signal.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>

#import "SZFriendsHelperProcessHarness.h"

static const NSUInteger SZFHFrameCap = 8388608; // PROTOCOL.md § Framing

static BOOL SZFHGoodbyeIs(NSDictionary *goodbye, NSString *code) {
    return [goodbye[@"type"] isEqual:@"goodbye"] && [goodbye[@"reason"] isEqual:@"protocol_error"] &&
           [goodbye[@"error"][@"code"] isEqual:code];
}

static SZFHClient *SZFHReadyClient(NSString *socket) {
    SZFHClient *client = [SZFHClient connectToSocket:socket timeout:5];
    return [[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"] ? client : nil;
}

// The 8 MiB cap, both sides of it, and frames that are not frames.
BOOL SZFHTestFrames(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];

    // Exactly at the cap is a frame: a ping padded with whitespace to 8,388,608 bytes before its line feed.
    SZFHClient *client = SZFHReadyClient(socket);
    CHECK(client != nil);
    NSString *head = @"{\"type\":\"ping\",\"id\":\"cap\"";
    NSMutableData *exact = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    exact.length = SZFHFrameCap - 1;
    memset((uint8_t *)exact.mutableBytes + head.length, ' ', SZFHFrameCap - 1 - head.length);
    [exact appendBytes:"}\n" length:2];
    CHECK(exact.length == SZFHFrameCap + 1);
    CHECK([client sendData:exact timeout:8]);
    NSDictionary *reply = [client nextFrameOfType:@"reply" timeout:8];
    CHECK([reply[@"re"] isEqual:@"cap"] && [reply[@"ok"] boolValue], "a frame of exactly 8 MiB is accepted: %@", reply);

    // One byte more is refused before it is buffered: goodbye frame_too_large, then the close.
    NSMutableData *over = [NSMutableData dataWithLength:SZFHFrameCap + 1];
    memset(over.mutableBytes, 'a', over.length);
    [client sendData:over timeout:8]; // the helper may close before every byte is written
    NSDictionary *goodbye = [client nextFrameOfType:@"goodbye" timeout:8];
    CHECK(SZFHGoodbyeIs(goodbye, @"frame_too_large"), "%@", goodbye);
    CHECK([goodbye[@"error"][@"details"][@"max_frame_bytes"] unsignedIntegerValue] == SZFHFrameCap);
    CHECK([client waitForEOFWithTimeout:3]);

    // Not JSON, not an object, no id: protocol errors that end the connection.
    NSArray *notFrames = @[ @"this is not json", @"[1,2,3]", @"{\"type\":\"ping\"}", @"{\"type\":\"ping\",\"id\":7}" ];
    for (NSString *line in notFrames) {
        SZFHClient *bad = SZFHReadyClient(socket);
        CHECK(bad != nil && [bad sendLine:line]);
        goodbye = [bad nextFrameOfType:@"goodbye" timeout:3];
        CHECK(SZFHGoodbyeIs(goodbye, @"bad_frame"), "%@ for %@", goodbye, line);
        CHECK([bad waitForEOFWithTimeout:3]);
    }

    // A well-formed frame with a bad field is answered and the connection stays open; empty lines are skipped.
    SZFHClient *lenient = SZFHReadyClient(socket);
    CHECK([lenient sendLine:@""] && [lenient sendLine:@"  \r"]);
    reply = [lenient intent:@"subscribe" fields:@{@"view" : @"bogus"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] &&
              [reply[@"error"][@"details"][@"field"] isEqual:@"view"],
          "%@", reply);
    reply = [lenient intent:@"frobnicate" fields:nil];
    CHECK([reply[@"error"][@"code"] isEqual:@"unknown_intent"] && reply[@"error"][@"message"] == [NSNull null],
          "%@", reply);
    reply = [lenient intent:@"assistant_search" fields:@{@"scope_id" : @"x", @"query" : @"y"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"unknown_intent"], "no assistant.scopes capability: %@", reply);
    reply = [lenient intent:@"ping" fields:nil];
    CHECK([reply[@"ok"] boolValue] && [reply[@"result"] isEqual:@{}], "still open: %@", reply);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// hello comes first; versions with no common major are refused and closed.
BOOL SZFHTestHandshakeErrors(SZFHHarness *harness) {
    NSString *state = [harness makeDirectory];
    pid_t pid = [harness spawnHelperWithStateDirectory:state timeScale:1];
    NSString *socket = [harness socketPathForStateDirectory:state];

    SZFHClient *early = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([early sendLine:@"{\"type\":\"ping\",\"id\":\"9\"}"]);
    NSDictionary *reply = [early nextFrameWithTimeout:3];
    CHECK([reply[@"type"] isEqual:@"reply"] && [reply[@"re"] isEqual:@"9"] &&
          [reply[@"error"][@"code"] isEqual:@"hello_required"], "%@", reply);
    CHECK(SZFHGoodbyeIs([early nextFrameWithTimeout:3], @"hello_required") && [early waitForEOFWithTimeout:3]);

    SZFHClient *future = [SZFHClient connectToSocket:socket timeout:5];
    NSDictionary *hello = @{
        @"type" : @"hello", @"id" : @"1", @"protocol" : @{@"major" : @3, @"minor" : @0, @"min_major" : @2},
        @"client" : @{@"app_id" : @"x", @"app_name" : @"Future", @"app_version" : @"9", @"toolkit" : @"gtk4",
                      @"reveal_in" : @"Files", @"pid" : @1},
        @"embedded_helper" : [NSNull null], @"capabilities" : @[], @"open_formats" : @[], @"locale" : @"en",
    };
    CHECK([future sendFrame:hello]);
    reply = [future nextFrameWithTimeout:3];
    CHECK([reply[@"error"][@"code"] isEqual:@"protocol_unsupported"] &&
          [reply[@"error"][@"details"][@"helper_major"] intValue] == 1, "%@", reply);
    CHECK(SZFHGoodbyeIs([future nextFrameWithTimeout:3], @"protocol_unsupported") && [future waitForEOFWithTimeout:3]);

    // A hello with a malformed client is answered, and a corrected hello on the same connection works.
    SZFHClient *sloppy = [SZFHClient connectToSocket:socket timeout:5];
    NSMutableDictionary *bad = [hello mutableCopy];
    bad[@"protocol"] = @{@"major" : @1, @"minor" : @0, @"min_major" : @1};
    bad[@"client"] = @{@"app_id" : @"x"};
    CHECK([sloppy sendFrame:bad]);
    reply = [sloppy nextFrameWithTimeout:3];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"], "%@", reply);
    CHECK([[sloppy helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    return YES;
}

// A state directory too deep for sun_path still works through the per-user fallback, which is created 0700.
BOOL SZFHTestSocketFallback(SZFHHarness *harness) {
    NSString *deep = [[harness makeDirectory] stringByAppendingPathComponent:
                                                  [@"" stringByPaddingToLength:80 withString:@"d" startingAtIndex:0]];
    NSString *socket = [harness socketPathForStateDirectory:deep];
    CHECK([socket.stringByDeletingLastPathComponent.lastPathComponent hasPrefix:@"szfriends-"], "fallback: %@", socket);
    pid_t pid = [harness spawnHelperWithStateDirectory:deep timeScale:1];
    SZFHClient *client = [SZFHClient connectToSocket:socket timeout:5];
    CHECK([[client helloWithEmbeddedBuild:0][@"type"] isEqual:@"welcome"]);
    struct stat st;
    CHECK(lstat(socket.stringByDeletingLastPathComponent.fileSystemRepresentation, &st) == 0 && S_ISDIR(st.st_mode) &&
          (st.st_mode & 0777) == 0700 && st.st_uid == geteuid());
    CHECK(lstat(socket.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0077) == 0, "socket 0600");
    kill(pid, SIGTERM);
    CHECK([harness waitForExit:pid timeout:3 status:NULL]);
    [[NSFileManager defaultManager] removeItemAtPath:socket.stringByDeletingLastPathComponent error:NULL];

    // Someone else's fallback directory (here: one with group and world access) is refused, never used or fixed.
    NSString *other = [[harness makeDirectory] stringByAppendingPathComponent:
                                                   [@"" stringByPaddingToLength:80 withString:@"e" startingAtIndex:0]];
    NSString *otherSocket = [harness socketPathForStateDirectory:other];
    NSString *otherDirectory = otherSocket.stringByDeletingLastPathComponent;
    CHECK(mkdir(otherDirectory.fileSystemRepresentation, 0755) == 0 &&
          chmod(otherDirectory.fileSystemRepresentation, 0755) == 0);
    pid = [harness spawnHelperWithStateDirectory:other timeScale:1];
    int status = 0;
    BOOL exited = [harness waitForExit:pid timeout:3 status:&status];
    [[NSFileManager defaultManager] removeItemAtPath:otherDirectory error:NULL];
    CHECK(exited && WIFEXITED(status) && WEXITSTATUS(status) == 1, "refuses an unsafe fallback (status %d)", status);
    return YES;
}

// The primary socket directory: group/world access or a symlink means someone else may have made it. Refused.
BOOL SZFHTestUnsafeDirectories(SZFHHarness *harness) {
    NSString *loose = [harness makeDirectory];
    NSString *ipc = [loose stringByAppendingPathComponent:@"ipc"];
    CHECK(mkdir(ipc.fileSystemRepresentation, 0755) == 0 && chmod(ipc.fileSystemRepresentation, 0755) == 0);
    pid_t pid = [harness spawnHelperWithStateDirectory:loose timeScale:1];
    int status = 0;
    CHECK([harness waitForExit:pid timeout:3 status:&status] && WIFEXITED(status) && WEXITSTATUS(status) == 1,
          "refuses a 0755 socket directory");
    struct stat st;
    CHECK(lstat(ipc.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0755, "left as found");
    CHECK(lstat([ipc stringByAppendingPathComponent:@"helper.sock"].fileSystemRepresentation, &st) != 0, "no socket");

    NSString *linked = [harness makeDirectory];
    NSString *target = [harness makeDirectory];
    NSString *link = [linked stringByAppendingPathComponent:@"ipc"];
    CHECK(symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) == 0);
    pid = [harness spawnHelperWithStateDirectory:linked timeScale:1];
    CHECK([harness waitForExit:pid timeout:3 status:&status] && WIFEXITED(status) && WEXITSTATUS(status) == 1,
          "refuses a symlinked socket directory");
    return YES;
}
