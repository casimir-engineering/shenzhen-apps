// friends-e2e-check: where received files go (PROTOCOL.md § Views, settings and received). Every helper here has
// SZFRIENDS_DOWNLOADS_DIR at a folder of its scenario, so nothing reaches the real ~/Downloads.

#import <sys/stat.h>
#import <sys/xattr.h>

#import "SZFriendsE2EScenarios.h"

static NSString *Resolved(NSString *path) {
    return path.stringByResolvingSymlinksInPath;
}

// The folder a delivered item's file is in.
static NSString *Folder(NSDictionary *item) {
    return Resolved([item[@"file"][@"path"] stringByDeletingLastPathComponent]);
}

static NSDictionary *_Nullable TransferItem(NSDictionary *conversation, NSString *transferID) {
    for (NSDictionary *item in SZFE2EItems(conversation, @"transfer")) {
        if ([item[@"transfer_id"] isEqual:transferID]) return item;
    }
    return nil;
}

static BOOL Quarantined(NSString *path) {
    char value[256] = {0};
    ssize_t length = getxattr(path.fileSystemRepresentation, "com.apple.quarantine", value, sizeof value - 1, 0, 0);
    return length > 0 && strstr(value, ";Shenzhen Friends;") != NULL;
}

// A sends `source`; B (which accepts files from A automatically) has it once it is received. Returns B's item.
static NSDictionary *_Nullable Deliver(SZFE2EPair *pair, NSString *conversationAtB, NSString *source) {
    NSDictionary *reply = [pair.a intent:@"send_files"
                                  fields:@{@"conversation_id" : pair.bAtA, @"files" : @[ @{@"path" : source} ],
                                           @"client_token" : SZFE2EToken()}];
    NSString *transferID = [reply[@"result"][@"transfer_ids"] firstObject];
    if (transferID == nil) return nil;
    __block NSDictionary *item = nil;
    SZFE2EWaitUntil(30, ^BOOL {
        item = TransferItem([pair.b dataFor:conversationAtB], transferID);
        return [item[@"state"] isEqual:@"received"] && [item[@"file"][@"path"] isKindOfClass:[NSString class]];
    });
    return [item[@"state"] isEqual:@"received"] ? item : nil;
}

// Nothing half-written or hidden is left beside the published files.
static NSArray<NSString *> *Names(NSString *directory) {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]
        sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

static NSString *_Nullable ActionPath(NSDictionary *item, NSString *action) {
    for (NSDictionary *candidate in item[@"actions"]) {
        if ([candidate[@"action"] isEqual:action]) return candidate[@"path"];
    }
    return nil;
}

static BOOL StartAutoAcceptingPair(SZFE2EWorld *world, SZFE2EPair *pair, NSDictionary *_Nullable envB,
                                   NSString *_Nullable *_Nonnull atB) {
    if (!SZFE2EStartPair(world, pair, nil, envB) || !SZFE2EBefriend(pair)) return NO;
    NSDictionary *reply = [pair.b intent:@"set_auto_accept"
                                  fields:@{@"conversation_id" : pair.aAtB, @"enabled" : @YES}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    *atB = [pair.b openConversation:pair.aAtB];
    CHECK(*atB != nil);
    return YES;
}

// Received files go to Downloads, complete and quarantined, "Name (2).ext" on a clash; the item opens and shows that
// file; the received view lists it; Settings names the folder; a chosen folder takes the next file; bad folders are
// refused with the documented errors; a folder that cannot take a file passes it to Downloads, which the item and
// Settings say until the next good save; choosing Downloads again clears the choice.
BOOL SZFE2EScenarioReceivedFolder(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    NSString *atB = nil;
    if (!StartAutoAcceptingPair(world, pair, nil, &atB)) return NO;
    CHECK([pair.b.welcome[@"capabilities"] containsObject:@"received.folder"], "%@", pair.b.welcome[@"capabilities"]);
    NSString *settings = [pair.b subscribe:@"settings" params:nil];
    NSString *received = [pair.b subscribe:@"received" params:nil];
    CHECK(settings != nil && received != nil, "subscribed to settings and received");
    NSString *downloads = pair.helperB.downloadsDirectory;
    NSDictionary *row = [pair.b dataFor:settings][@"received"];
    CHECK([row[@"label"] isEqual:@"Save received files to"] && [row[@"value"] isEqual:@"Downloads"] &&
              [row[@"note"] isEqual:@""] && [Resolved(row[@"path"]) isEqualToString:Resolved(downloads)] &&
              [row[@"action"][@"action"] isEqual:@"show_file"] &&
              [Resolved(row[@"action"][@"path"]) isEqualToString:Resolved(downloads)] &&
              [row[@"change"][@"action"] isEqual:@"choose_received_folder"] &&
              [row[@"change"][@"label"] isEqual:@"Change…"],
          "Settings names Downloads: %@", row);

    // The first file: in Downloads, the same bytes, quarantined, nothing else left there or in staging.
    NSString *source = [world fileOfSize:2 * 1024 * 1024 + 99 named:@"Site plan.pdf"];
    NSDictionary *first = Deliver(pair, atB, source);
    NSString *path = first[@"file"][@"path"];
    CHECK([Resolved(path) isEqualToString:Resolved([downloads stringByAppendingPathComponent:@"Site plan.pdf"])],
          "in Downloads under its own name: %@", first);
    CHECK([[NSData dataWithContentsOfFile:path] isEqual:[NSData dataWithContentsOfFile:source]], "complete");
    CHECK(Quarantined(path), "quarantined like a download");
    CHECK([first[@"status_label"] isEqual:@"Saved to Downloads"] &&
              [first[@"accessibility_label"] hasSuffix:@", saved to Downloads"],
          "the item says where it went: %@", first);
    CHECK([Names(downloads) isEqual:@[ @"Site plan.pdf" ]], "nothing half-written beside it: %@", Names(downloads));
    NSString *staging = [pair.helperB.stateDirectory stringByAppendingPathComponent:@"received/.partial"];
    CHECK(Names(staging).count == 0, "no staging file left: %@", Names(staging));
    // What Show in Finder reveals is that file (and Open opens it, for a client that opens PDFs).
    CHECK([ActionPath(first, @"show_file") isEqualToString:path], "Show in Finder targets it: %@", first[@"actions"]);
    NSString *open = ActionPath(first, @"open_file");
    CHECK(open == nil || [open isEqualToString:path], "Open targets it: %@", first[@"actions"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *listed = [[pair.b dataFor:received][@"files"] firstObject];
              return [listed[@"transfer_id"] isEqual:first[@"transfer_id"]] && [listed[@"path"] isEqual:path] &&
                     [listed[@"file_name"] isEqual:@"Site plan.pdf"] && [listed[@"source"] isEqual:@"friend"] &&
                     [listed[@"received_at"] longLongValue] > 0;
          }),
          "the received view lists it: %@", [pair.b dataFor:received]);

    // The same name again: "Site plan (2).pdf", the first untouched.
    NSData *firstBytes = [NSData dataWithContentsOfFile:path];
    NSString *againFolder = [world.scenarioDirectory stringByAppendingPathComponent:@"again"];
    [NSFileManager.defaultManager createDirectoryAtPath:againFolder
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *again = [world fileOfSize:4096 named:@"again/Site plan.pdf"];
    NSDictionary *second = Deliver(pair, atB, again);
    CHECK([[second[@"file"][@"path"] lastPathComponent] isEqualToString:@"Site plan (2).pdf"] &&
              [[NSData dataWithContentsOfFile:second[@"file"][@"path"]] isEqual:[NSData dataWithContentsOfFile:again]],
          "a clash takes the next name: %@", second[@"file"]);
    CHECK([[NSData dataWithContentsOfFile:path] isEqual:firstBytes], "nothing overwritten");

    // Bad folders, each with its documented error; nothing changes.
    NSDictionary *reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : @"Documents/From friends"}];
    CHECK([reply[@"error"][@"code"] isEqual:@"invalid_field"] &&
              [reply[@"error"][@"details"][@"field"] isEqual:@"path"],
          "relative: %@", reply);
    NSString *missing = [world.scenarioDirectory stringByAppendingPathComponent:@"no such folder"];
    reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : missing}];
    CHECK([reply[@"error"][@"code"] isEqual:@"file_missing"] && [reply[@"error"][@"details"][@"path"] isEqual:missing] &&
              [reply[@"error"][@"message"] isEqual:@"That folder can’t be found or opened. Choose another folder."],
          "missing: %@", reply);
    reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : source}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"] &&
              [reply[@"error"][@"message"] isEqual:@"Files can’t be saved in that folder. Choose another folder."],
          "a file: %@", reply);
    reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : pair.helperB.stateDirectory}];
    CHECK([reply[@"error"][@"code"] isEqual:@"not_allowed"], "the helper's own folder: %@", reply);
    CHECK([[pair.b dataFor:settings][@"received"][@"value"] isEqual:@"Downloads"], "still Downloads");

    // A chosen folder: Settings shows it, and the next file lands there.
    NSString *chosen = [world.scenarioDirectory stringByAppendingPathComponent:@"From friends"];
    [NSFileManager.defaultManager createDirectoryAtPath:chosen withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : chosen}];
    CHECK([reply[@"ok"] boolValue], "%@", reply);
    row = [pair.b dataFor:settings][@"received"];
    CHECK([row[@"value"] isEqual:@"From friends"] && [Resolved(row[@"path"]) isEqualToString:Resolved(chosen)] &&
              [Resolved(row[@"action"][@"path"]) isEqualToString:Resolved(chosen)],
          "Settings names the chosen folder (sent before the reply): %@", row);
    NSString *third = [world fileOfSize:1000 named:@"Bracket rev B.step"];
    NSDictionary *thirdItem = Deliver(pair, atB, third);
    CHECK([Resolved([thirdItem[@"file"][@"path"] stringByDeletingLastPathComponent]) isEqualToString:Resolved(chosen)],
          "the next file lands there: %@", thirdItem[@"file"]);
    CHECK([thirdItem[@"status_label"] isEqual:@"Saved to From friends"], "%@", thirdItem[@"status_label"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSArray *files = [pair.b dataFor:received][@"files"];
              return files.count == 3 && [files[0][@"transfer_id"] isEqual:thirdItem[@"transfer_id"]];
          }),
          "newest first: %@", [pair.b dataFor:received]);

    // The chosen folder cannot take the next file (read-only, as when macOS refuses access): it goes to Downloads,
    // says so, and Settings says why until a file is saved in the chosen folder again.
    NSString *fallbackNote = @"The last file couldn’t be saved here, so it went to Downloads.";
    chmod(chosen.fileSystemRepresentation, 0555);
    NSDictionary *fourth = Deliver(pair, atB, [world fileOfSize:1200 named:@"Fallback one.pdf"]);
    chmod(chosen.fileSystemRepresentation, 0755);
    CHECK([Folder(fourth) isEqualToString:Resolved(downloads)] &&
              [fourth[@"status_label"] isEqual:@"Saved to Downloads"],
          "a read-only folder: Downloads takes it: %@", fourth);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              NSDictionary *now = [pair.b dataFor:settings][@"received"];
              return [now[@"note"] isEqual:fallbackNote] && [now[@"value"] isEqual:@"From friends"];
          }),
          "Settings says the last file went to Downloads: %@", [pair.b dataFor:settings][@"received"]);
    NSDictionary *fifth = Deliver(pair, atB, [world fileOfSize:1300 named:@"Back again.pdf"]);
    CHECK([Folder(fifth) isEqualToString:Resolved(chosen)],
          "writable again: %@", fifth[@"file"]);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [[pair.b dataFor:settings][@"received"][@"note"] isEqual:@""];
          }),
          "the next good save clears the note: %@", [pair.b dataFor:settings][@"received"]);
    // The folder is gone: Downloads again, and choosing a folder clears the note.
    [NSFileManager.defaultManager removeItemAtPath:chosen error:NULL];
    NSDictionary *sixth = Deliver(pair, atB, [world fileOfSize:1400 named:@"Fallback two.pdf"]);
    CHECK([Folder(sixth) isEqualToString:Resolved(downloads)] &&
              [sixth[@"status_label"] isEqual:@"Saved to Downloads"],
          "a removed folder: Downloads takes it: %@", sixth);
    CHECK(SZFE2EWaitUntil(10, ^BOOL {
              return [[pair.b dataFor:settings][@"received"][@"note"] isEqual:fallbackNote];
          }),
          "the note again: %@", [pair.b dataFor:settings][@"received"]);

    // Downloads again clears the choice, and the note with it.
    reply = [pair.b intent:@"set_received_folder" fields:@{@"path" : downloads}];
    CHECK([reply[@"ok"] boolValue] && [[pair.b dataFor:settings][@"received"][@"value"] isEqual:@"Downloads"] &&
              [[pair.b dataFor:settings][@"received"][@"note"] isEqual:@""] &&
              ![NSFileManager.defaultManager fileExistsAtPath:[pair.helperB.stateDirectory
                                                                  stringByAppendingPathComponent:@"received-folder"]],
          "Downloads again: %@ %@", reply, [pair.b dataFor:settings][@"received"]);
    return YES;
}

// Without SZFRIENDS_DOWNLOADS_DIR, a helper whose state directory is overridden keeps its Downloads inside it.
BOOL SZFE2EScenarioReceivedDefaultUnderState(SZFE2EWorld *world) {
    SZFE2EPair *pair = [[SZFE2EPair alloc] init];
    NSString *atB = nil;
    if (!StartAutoAcceptingPair(world, pair, @{@"SZFRIENDS_DOWNLOADS_DIR" : @""}, &atB)) return NO;
    NSString *downloads = [pair.helperB.stateDirectory stringByAppendingPathComponent:@"Downloads"];
    NSDictionary *item = Deliver(pair, atB, [world fileOfSize:5000 named:@"notes.txt"]);
    CHECK([Resolved([item[@"file"][@"path"] stringByDeletingLastPathComponent]) isEqualToString:Resolved(downloads)],
          "in <state>/Downloads: %@", item[@"file"]);
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:pair.helperB.downloadsDirectory], "nowhere else");
    return YES;
}
