// Where received files go: the default folder, the person's choice and its checks, falling back when a folder cannot
// take a file, the copy across volumes, and the received view's list (PROTOCOL.md § Views, settings and received).

#import <stdlib.h>
#import <sys/stat.h>
#import <sys/xattr.h>
#import <unistd.h>

#import "SZFriendsStoreTestSupport.h"

static SZFriendsTransfers *Receiver(SZFriendsStore *store) {
    SZFriendsTransfers *transfers = [[SZFriendsTransfers alloc] initWithStore:store
                                                               stateDirectory:store.stateDirectory];
    transfers.freeBytesProvider = ^uint64_t(NSString *path) {
        (void)path;
        return 1ULL << 40;
    };
    return transfers;
}

// Offers, accepts, streams and finishes one file from Mei; returns where it was published, or nil.
static NSString *_Nullable Receive(SZFriendsTransfers *transfers, NSString *transferID, NSString *name,
                                   NSData *contents) {
    NSError *error = nil;
    BOOL ok = [transfers recordIncomingOfferWithID:transferID conversationID:@"mei" fileName:name uniformType:nil
                                              size:contents.length contentDigest:SZFTBlake2b(contents)
                                            sentAt:[NSDate date] error:&error] != nil &&
              [transfers acceptTransfer:transferID automatically:NO error:&error] &&
              [transfers appendChunk:contents atOffset:0 toTransfer:transferID fromConversation:@"mei" error:&error] &&
              [transfers finishTransfer:transferID finalDigest:SZFTBlake2b(contents) fromConversation:@"mei"
                                  error:&error];
    if (!ok) fprintf(stderr, "receive %s failed: %s\n", transferID.UTF8String, error.localizedDescription.UTF8String);
    return ok ? [transfers transferWithID:transferID].receivedPath : nil;
}

static BOOL Quarantined(NSString *path) {
    char value[256] = {0};
    ssize_t length = getxattr(path.fileSystemRepresentation, "com.apple.quarantine", value, sizeof value - 1, 0, 0);
    return length > 0 && strstr(value, ";Shenzhen Friends;") != NULL;
}

static NSArray<NSString *> *Names(NSString *directory) {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]
        sortedArrayUsingSelector:@selector(compare:)] ?: @[];
}

static void TestDefaultFolder(void) {
    NSString *state = SZFTTemporaryDirectory(@"default-folder");
    unsetenv("SZFRIENDS_DOWNLOADS_DIR");
    SZFTExpect([SZFriendsDefaultReceivedFolder(state)
                   isEqualToString:[state stringByAppendingPathComponent:@"Downloads"]],
               @"a state directory of its own keeps Downloads inside it: %@", SZFriendsDefaultReceivedFolder(state));
    NSString *downloads = SZFTTemporaryDirectory(@"downloads-env");
    setenv("SZFRIENDS_DOWNLOADS_DIR", downloads.fileSystemRepresentation, 1);
    SZFTExpect([SZFriendsDefaultReceivedFolder(state) isEqualToString:downloads], @"SZFRIENDS_DOWNLOADS_DIR wins");
    unsetenv("SZFRIENDS_DOWNLOADS_DIR");
    // The default state directory of a test HOME: that HOME's Downloads, never the account's.
    NSString *home = SZFTTemporaryDirectory(@"home");
    const char *realHome = getenv("HOME"), *stateOverride = getenv("SZFRIENDS_STATE_DIR");
    NSString *savedHome = realHome ? @(realHome) : nil, *savedState = stateOverride ? @(stateOverride) : nil;
    unsetenv("SZFRIENDS_STATE_DIR");
    setenv("HOME", home.fileSystemRepresentation, 1);
    NSString *defaultState = [home stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
    SZFTExpect([SZFriendsDefaultReceivedFolder(defaultState)
                   isEqualToString:[home stringByAppendingPathComponent:@"Downloads"]],
               @"a test HOME's Downloads: %@", SZFriendsDefaultReceivedFolder(defaultState));
    if (savedHome) setenv("HOME", savedHome.fileSystemRepresentation, 1);
    if (savedState) setenv("SZFRIENDS_STATE_DIR", savedState.fileSystemRepresentation, 1);
    // With the state directory overridden, even that path keeps its Downloads inside it.
    SZFTExpect([SZFriendsDefaultReceivedFolder(defaultState)
                   isEqualToString:[defaultState stringByAppendingPathComponent:@"Downloads"]],
               @"SZFRIENDS_STATE_DIR: %@", SZFriendsDefaultReceivedFolder(defaultState));
    SZFTExpect(SZFriendsChosenReceivedFolder(state) == nil &&
                   [SZFriendsReceivedFolder(state) isEqualToString:SZFriendsDefaultReceivedFolder(state)],
               @"nothing chosen: Downloads");
}

static void TestChoosingAFolder(void) {
    NSString *state = SZFTTemporaryDirectory(@"choose-state");
    NSString *chosen = SZFTTemporaryDirectory(@"From friends");
    NSError *error = nil;
    SZFTExpect(SZFriendsSetReceivedFolder(state, @"relative/folder", &error) == SZFriendsReceivedFolderInvalidPath,
               @"not absolute");
    SZFTExpect(SZFriendsSetReceivedFolder(state, [chosen stringByAppendingPathComponent:@"missing"], &error) ==
                   SZFriendsReceivedFolderMissing, @"missing");
    NSString *file = [chosen stringByAppendingPathComponent:@"note.txt"];
    [[NSData data] writeToFile:file atomically:NO];
    SZFTExpect(SZFriendsSetReceivedFolder(state, file, &error) == SZFriendsReceivedFolderNotAllowed, @"a file");
    NSString *inside = [state stringByAppendingPathComponent:@"received"];
    [NSFileManager.defaultManager createDirectoryAtPath:inside withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    SZFTExpect(SZFriendsSetReceivedFolder(state, inside, &error) == SZFriendsReceivedFolderNotAllowed &&
                   SZFriendsSetReceivedFolder(state, state, &error) == SZFriendsReceivedFolderNotAllowed,
               @"the helper's own folders");
    NSString *readOnly = SZFTTemporaryDirectory(@"read-only");
    chmod(readOnly.fileSystemRepresentation, 0555);
    SZFTExpect(SZFriendsSetReceivedFolder(state, readOnly, &error) == SZFriendsReceivedFolderNotAllowed,
               @"not writable");
    chmod(readOnly.fileSystemRepresentation, 0755);
    SZFTExpect(SZFriendsChosenReceivedFolder(state) == nil, @"nothing stored by a refusal");
    // Stored as its real path (the temporary root is behind /var -> /private/var).
    SZFTExpect(SZFriendsSetReceivedFolder(state, [chosen stringByAppendingString:@"/./"], &error) ==
                   SZFriendsReceivedFolderOK, @"chosen: %@", error);
    NSString *stored = [NSString stringWithContentsOfFile:[state stringByAppendingPathComponent:@"received-folder"]
                                                 encoding:NSUTF8StringEncoding error:NULL];
    char real[PATH_MAX];
    realpath(chosen.fileSystemRepresentation, real);
    SZFTExpect([stored isEqualToString:@(real)] && [SZFriendsReceivedFolder(state) isEqualToString:@(real)],
               @"the real path, one line: %@", stored);
    // Choosing Downloads again clears the choice.
    NSString *downloads = SZFriendsDefaultReceivedFolder(state);
    [NSFileManager.defaultManager createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil
                                                  error:NULL];
    SZFTExpect(SZFriendsSetReceivedFolder(state, downloads, &error) == SZFriendsReceivedFolderOK &&
                   SZFriendsChosenReceivedFolder(state) == nil &&
                   ![NSFileManager.defaultManager fileExistsAtPath:[state stringByAppendingPathComponent:
                                                                              @"received-folder"]],
               @"Downloads clears it");
}

static void TestPublishToChosenAndFallBack(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"publish-chosen"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSString *chosen = SZFTTemporaryDirectory(@"chosen");
    SZFriendsSetReceivedFolder(store.stateDirectory, chosen, NULL);
    NSData *one = SZFTRandomData(5000);
    NSString *first = Receive(transfers, @"f1", @"Plan.pdf", one);
    NSString *folder = SZFriendsReceivedFolder(store.stateDirectory);
    SZFTExpect([first.stringByDeletingLastPathComponent isEqualToString:folder] &&
                   [[NSData dataWithContentsOfFile:first] isEqualToData:one] && Quarantined(first),
               @"in the chosen folder, quarantined: %@", first);
    NSString *second = Receive(transfers, @"f2", @"Plan.pdf", SZFTRandomData(10));
    SZFTExpect([second.lastPathComponent isEqualToString:@"Plan (2).pdf"] &&
                   [[NSData dataWithContentsOfFile:first] isEqualToData:one], @"never replaced: %@", second);
    NSString *state = store.stateDirectory;
    SZFTExpect(SZFriendsSavedPlaceOfFile(state, first) == SZFriendsSavedPlaceFolder &&
                   SZFriendsLastReceivedFallback(state) == SZFriendsReceivedFallbackNone,
               @"saved where meant: no fallback");
    // Read-only now (as a privacy refusal would be): the next file goes to Downloads.
    chmod(chosen.fileSystemRepresentation, 0555);
    NSString *third = Receive(transfers, @"f3", @"Plan.pdf", SZFTRandomData(10));
    chmod(chosen.fileSystemRepresentation, 0755);
    NSString *downloads = SZFriendsDefaultReceivedFolder(store.stateDirectory);
    SZFTExpect([third isEqualToString:[downloads stringByAppendingPathComponent:@"Plan.pdf"]],
               @"falls back to Downloads: %@", third);
    SZFTExpect(SZFriendsSavedPlaceOfFile(state, third) == SZFriendsSavedPlaceDownloads &&
                   SZFriendsLastReceivedFallback(state) == SZFriendsReceivedFallbackDownloads,
               @"the fallback to Downloads is remembered");
    // The next file saved where it was meant to be clears it.
    NSString *back = Receive(transfers, @"f3b", @"Plan.pdf", SZFTRandomData(10));
    SZFTExpect([back.stringByDeletingLastPathComponent isEqualToString:folder] &&
                   SZFriendsLastReceivedFallback(state) == SZFriendsReceivedFallbackNone,
               @"a good save clears the fallback: %@", back);
    // Chosen folder gone and Downloads unwritable: the helper's own received/ keeps the file.
    [NSFileManager.defaultManager removeItemAtPath:chosen error:NULL];
    chmod(downloads.fileSystemRepresentation, 0555);
    NSString *fourth = Receive(transfers, @"f4", @"Plan.pdf", SZFTRandomData(10));
    chmod(downloads.fileSystemRepresentation, 0755);
    SZFTExpect([fourth.stringByDeletingLastPathComponent isEqualToString:transfers.receivedDirectory],
               @"never lost: %@", fourth);
    SZFTExpect(SZFriendsSavedPlaceOfFile(state, fourth) == SZFriendsSavedPlaceKept &&
                   SZFriendsLastReceivedFallback(state) == SZFriendsReceivedFallbackKept,
               @"kept in the helper's own folder, and remembered");
    // Changing the folder (here back to Downloads) clears it too.
    SZFriendsSetReceivedFolder(state, downloads, NULL);
    SZFTExpect(SZFriendsLastReceivedFallback(state) == SZFriendsReceivedFallbackNone, @"a new folder clears it");
    struct stat info;
    SZFTExpect(stat(downloads.fileSystemRepresentation, &info) == 0 && (info.st_mode & 0777) == 0755,
               @"a person's folder keeps its permissions: %o", info.st_mode & 0777);
}

static void TestPublishAcrossVolumes(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"publish-copy"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSData *contents = SZFTRandomData(300000);
    SZFriendsPublishAcrossVolumes = YES;
    NSString *published = Receive(transfers, @"v1", @"Drawings.pdf", contents);
    SZFriendsPublishAcrossVolumes = NO;
    NSString *downloads = SZFriendsDefaultReceivedFolder(store.stateDirectory);
    SZFTExpect([published isEqualToString:[downloads stringByAppendingPathComponent:@"Drawings.pdf"]] &&
                   [[NSData dataWithContentsOfFile:published] isEqualToData:contents] && Quarantined(published),
               @"copied, complete, quarantined: %@", published);
    SZFTExpect([Names(downloads) isEqual:@[ @"Drawings.pdf" ]], @"no part file left: %@", Names(downloads));
    NSString *partial = [transfers.receivedDirectory stringByAppendingPathComponent:@".partial"];
    SZFTExpect(Names(partial).count == 0, @"no staging file left: %@", Names(partial));
}

static void TestReceivedList(void) {
    SZFriendsStore *store = SZFTOpenStore(SZFTTemporaryDirectory(@"received-list"));
    SZFTAddPerson(store, @"mei", 1, SZFriendsRelationFriend, 1000);
    SZFriendsTransfers *transfers = Receiver(store);
    NSString *older = Receive(transfers, @"l1", @"Older.pdf", SZFTRandomData(10));
    [NSThread sleepForTimeInterval:0.01];
    NSString *newer = Receive(transfers, @"l2", @"Newer.pdf", SZFTRandomData(10));
    Receive(transfers, @"l3", @"Gone.pdf", SZFTRandomData(10));
    [NSFileManager.defaultManager removeItemAtPath:[transfers transferWithID:@"l3"].receivedPath error:NULL];
    NSArray<SZFriendsReceivedFile *> *files = [transfers receivedFilesWithLimit:100];
    SZFTExpect(files.count == 2 && [files[0].path isEqualToString:newer] && [files[1].path isEqualToString:older] &&
                   [files[0].transferID isEqualToString:@"l2"] && files[0].source == SZFriendsReceivedSourceFriend &&
                   fabs(files[0].receivedAt.timeIntervalSinceNow) < 60,
               @"newest first, only files still there: %@", [files valueForKey:@"path"]);
    SZFTExpect([transfers receivedFilesWithLimit:1].count == 1, @"limited");
}

void SZFTRunReceivedFolderTests(void) {
    TestDefaultFolder();
    TestChoosingAFolder();
    TestPublishToChosenAndFallBack();
    TestPublishAcrossVolumes();
    TestReceivedList();
}
