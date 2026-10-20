// Where received files go (PROTOCOL.md § Views, settings and received): the folder the person chose, else Downloads,
// else the helper's own received/ folder, and publishing a verified file there without ever replacing another.

#import <copyfile.h>
#import <fcntl.h>
#import <pwd.h>
#import <stdio.h>
#import <sys/stat.h>
#import <unistd.h>

#import "service/store/SZFriendsStoreInternal.h"

NS_ASSUME_NONNULL_BEGIN

BOOL SZFriendsPublishAcrossVolumes = NO;

NSString *const SZFriendsReceivedFolderFileName = @"received-folder";
NSString *const SZFriendsReceivedFallbackFileName = @"received-fallback";
NSString *const SZFriendsDownloadsDirEnvironment = @"SZFRIENDS_DOWNLOADS_DIR";

static NSString *SZFriendsStandardPath(NSString *path) {
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) == NULL) return path.stringByStandardizingPath;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
}

// Read live (getenv, not NSProcessInfo's copy taken at launch), as the helper's own overrides are.
static NSString *_Nullable SZFriendsEnv(const char *name) {
    const char *value = getenv(name);
    return value ? @(value) : nil;
}

static void SZFriendsRecordReceivedFallback(NSString *stateDirectory, SZFriendsReceivedFallback fallback);

// The state directory a helper uses when nothing overrides it, for the HOME it runs with.
static BOOL SZFriendsIsDefaultStateDirectory(NSString *stateDirectory) {
    if (SZFriendsEnv("SZFRIENDS_STATE_DIR").length > 0) return NO;
    NSString *home = SZFriendsEnv("HOME");
    if (![home hasPrefix:@"/"]) home = NSHomeDirectory();
    NSString *standard = [home stringByAppendingPathComponent:@"Library/Application Support/Shenzhen Friends"];
    return [stateDirectory.stringByStandardizingPath isEqualToString:standard.stringByStandardizingPath];
}

NSString *SZFriendsDefaultReceivedFolder(NSString *stateDirectory) {
    NSString *tests = SZFriendsEnv("SZFRIENDS_DOWNLOADS_DIR");
    if ([tests hasPrefix:@"/"]) return tests.stringByStandardizingPath;
    // A helper whose state lives elsewhere (tests, probes) never reaches the person's real Downloads.
    if (!SZFriendsIsDefaultStateDirectory(stateDirectory)) {
        return [stateDirectory stringByAppendingPathComponent:@"Downloads"];
    }
    // A HOME other than the account's own (a test home) gets its own Downloads, never the account's.
    NSString *home = SZFriendsEnv("HOME");
    struct passwd *account = getpwuid(getuid());
    NSString *accountHome = account && account->pw_dir ? @(account->pw_dir) : nil;
    if ([home hasPrefix:@"/"] && accountHome && ![home.stringByStandardizingPath
                                                       isEqualToString:accountHome.stringByStandardizingPath]) {
        return [home stringByAppendingPathComponent:@"Downloads"];
    }
    NSURL *downloads = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory
                                                            inDomains:NSUserDomainMask].firstObject;
    return downloads.path ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
}

NSString *_Nullable SZFriendsChosenReceivedFolder(NSString *stateDirectory) {
    NSString *file = [stateDirectory stringByAppendingPathComponent:SZFriendsReceivedFolderFileName];
    NSData *data = [NSData dataWithContentsOfFile:file options:0 error:NULL];
    if (data.length == 0 || data.length > 4096) return nil;
    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    path = [path stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
    return [path hasPrefix:@"/"] ? path : nil;
}

NSString *SZFriendsReceivedFolder(NSString *stateDirectory) {
    return SZFriendsChosenReceivedFolder(stateDirectory) ?: SZFriendsDefaultReceivedFolder(stateDirectory);
}

SZFriendsReceivedFolderResult SZFriendsSetReceivedFolder(NSString *stateDirectory, NSString *path,
                                                         NSError **error) {
    if (![path hasPrefix:@"/"] || [path rangeOfString:@"\0"].location != NSNotFound) {
        return SZFriendsReceivedFolderInvalidPath;
    }
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) == NULL) return SZFriendsReceivedFolderMissing;
    NSString *real = [NSFileManager.defaultManager stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    struct stat info;
    if (stat(resolved, &info) != 0) return SZFriendsReceivedFolderMissing;
    if (!S_ISDIR(info.st_mode)) return SZFriendsReceivedFolderNotAllowed;
    if (access(resolved, R_OK | X_OK) != 0) return SZFriendsReceivedFolderMissing;
    if (access(resolved, W_OK) != 0) return SZFriendsReceivedFolderNotAllowed;
    NSString *file = [stateDirectory stringByAppendingPathComponent:SZFriendsReceivedFolderFileName];
    // Downloads clears the choice (a test helper's Downloads may be inside its state directory, so first).
    BOOL downloads = [real isEqualToString:SZFriendsStandardPath(SZFriendsDefaultReceivedFolder(stateDirectory))];
    // The helper's own files are not a place for the person's: Reset and recovery delete what they find there.
    NSString *state = SZFriendsStandardPath(stateDirectory);
    if (!downloads && ([real isEqualToString:state] || [real hasPrefix:[state stringByAppendingString:@"/"]])) {
        return SZFriendsReceivedFolderNotAllowed;
    }
    if (downloads) {
        if (unlink(file.fileSystemRepresentation) != 0 && errno != ENOENT) {
            SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"cannot clear the folder"));
            return SZFriendsReceivedFolderFailed;
        }
    } else {
        // Atomic: a crash leaves the old choice or the new one, never half a path.
        NSData *data = [real dataUsingEncoding:NSUTF8StringEncoding];
        if (![data writeToFile:file options:NSDataWritingAtomic error:error]) return SZFriendsReceivedFolderFailed;
    }
    // A new folder: what happened to the last file in the old one no longer applies.
    SZFriendsRecordReceivedFallback(stateDirectory, SZFriendsReceivedFallbackNone);
    return SZFriendsReceivedFolderOK;
}

#pragma mark - Where files went

static NSString *_Nullable SZFriendsFallbackWord(SZFriendsReceivedFallback fallback) {
    return fallback == SZFriendsReceivedFallbackDownloads ? @"downloads"
           : fallback == SZFriendsReceivedFallbackKept    ? @"kept"
                                                          : nil;
}

SZFriendsReceivedFallback SZFriendsLastReceivedFallback(NSString *stateDirectory) {
    NSString *file = [stateDirectory stringByAppendingPathComponent:SZFriendsReceivedFallbackFileName];
    NSData *data = [NSData dataWithContentsOfFile:file options:0 error:NULL];
    if (data.length == 0 || data.length > 64) return SZFriendsReceivedFallbackNone;
    NSString *word = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([word isEqualToString:@"downloads"]) return SZFriendsReceivedFallbackDownloads;
    if ([word isEqualToString:@"kept"]) return SZFriendsReceivedFallbackKept;
    return SZFriendsReceivedFallbackNone;
}

static void SZFriendsRecordReceivedFallback(NSString *stateDirectory, SZFriendsReceivedFallback fallback) {
    if (SZFriendsLastReceivedFallback(stateDirectory) == fallback) return;
    NSString *file = [stateDirectory stringByAppendingPathComponent:SZFriendsReceivedFallbackFileName];
    NSString *word = SZFriendsFallbackWord(fallback);
    if (word == nil) {
        unlink(file.fileSystemRepresentation);
        return;
    }
    [[word dataUsingEncoding:NSUTF8StringEncoding] writeToFile:file options:NSDataWritingAtomic error:NULL];
}

SZFriendsSavedPlace SZFriendsSavedPlaceOfFile(NSString *stateDirectory, NSString *path) {
    NSString *folder = SZFriendsStandardPath(path.stringByDeletingLastPathComponent);
    NSString *own = SZFriendsStandardPath([stateDirectory stringByAppendingPathComponent:@"received"]);
    if ([folder isEqualToString:own]) return SZFriendsSavedPlaceKept;
    if ([folder isEqualToString:SZFriendsStandardPath(SZFriendsDefaultReceivedFolder(stateDirectory))]) {
        return SZFriendsSavedPlaceDownloads;
    }
    return SZFriendsSavedPlaceFolder;
}

#pragma mark - Publishing

NSString *SZFriendsReceivedPartPath(NSString *finalPath) {
    NSString *name = [NSString stringWithFormat:@".%@.part", finalPath.lastPathComponent];
    return [finalPath.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
}

static void SZFriendsSyncDirectory(NSString *directory) {
    int fd = open(directory.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        fsync(fd); // the rename itself must survive a power cut before the row says Received
        close(fd);
    }
}

// Errors that mean "not this folder": try the next one rather than fail the file.
static BOOL SZFriendsFolderRefused(int number) {
    return number == EACCES || number == EPERM || number == EROFS || number == ENOENT || number == ENOTDIR ||
           number == ENOSPC || number == EDQUOT;
}

// The folders to try, in order, each made ready: the chosen one only if it is there (it is the person's, and
// never created or changed), Downloads created if missing (normal permissions), received/ as the helper's own.
static NSArray<NSString *> *SZFriendsPublishFolders(NSString *stateDirectory) {
    NSMutableArray<NSString *> *folders = [NSMutableArray array];
    NSString *chosen = SZFriendsChosenReceivedFolder(stateDirectory);
    NSString *downloads = SZFriendsDefaultReceivedFolder(stateDirectory);
    struct stat info;
    if (chosen && stat(chosen.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode)) {
        [folders addObject:chosen];
    }
    if (stat(downloads.fileSystemRepresentation, &info) != 0 && errno == ENOENT) {
        [NSFileManager.defaultManager createDirectoryAtPath:downloads withIntermediateDirectories:YES attributes:nil
                                                      error:NULL];
    }
    if (stat(downloads.fileSystemRepresentation, &info) == 0 && S_ISDIR(info.st_mode) &&
        ![folders containsObject:downloads]) {
        [folders addObject:downloads];
    }
    NSString *own = [stateDirectory stringByAppendingPathComponent:@"received"];
    if (SZFriendsEnsurePrivateDirectory(own, NULL)) [folders addObject:own];
    return folders;
}

// Across volumes a rename cannot work: the bytes go into a hidden part file beside the final name, made durable and
// quarantined, which then takes the final name exclusively. Returns 0, or the errno that stopped it.
static int SZFriendsCopyAcross(NSString *staged, NSString *final) {
    NSString *part = SZFriendsReceivedPartPath(final);
    unlink(part.fileSystemRepresentation); // a copy a crash interrupted is redone from the start
    int in = open(staged.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return errno;
    int out = open(part.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) {
        int number = errno;
        close(in);
        return number;
    }
    int number = 0;
    if (fcopyfile(in, out, NULL, COPYFILE_DATA) != 0) number = errno ?: EIO;
    if (number == 0 && fcntl(out, F_FULLFSYNC) != 0 && fsync(out) != 0) number = errno;
    close(in);
    close(out);
    if (number == 0 && !SZFriendsSetQuarantine(part, NULL)) number = EIO;
    if (number == 0) SZFriendsStoreTestPoint("received.part_written");
    if (number == 0 && renamex_np(part.fileSystemRepresentation, final.fileSystemRepresentation, RENAME_EXCL) != 0) {
        number = errno;
    }
    if (number != 0) {
        unlink(part.fileSystemRepresentation);
        return number;
    }
    SZFriendsSyncDirectory(final.stringByDeletingLastPathComponent);
    SZFriendsStoreTestPoint("received.part_renamed");
    unlink(staged.fileSystemRepresentation);
    return 0;
}

NSString *_Nullable SZFriendsPublishReceivedFile(NSString *staged, NSString *fileName, NSString *stateDirectory,
                                                 BOOL (^_Nullable willPublish)(NSString *finalPath, NSError **error),
                                                 NSError **error) {
    // Quarantined before it gets a name anyone sees, as a browser download would be.
    SZFriendsSetQuarantine(staged, NULL);
    // Where it is meant to go; any other folder that takes it is a fallback Settings mentions.
    NSString *meant = SZFriendsReceivedFolder(stateDirectory);
    NSString *downloads = SZFriendsDefaultReceivedFolder(stateDirectory);
    for (NSString *folder in SZFriendsPublishFolders(stateDirectory)) {
        for (int attempt = 0; attempt < 16; attempt++) {
            NSString *final = SZFriendsUniqueDestination(folder, fileName);
            if (willPublish && !willPublish(final, error)) return nil;
            SZFriendsStoreTestPoint("transfer.before_rename");
            int number = 0;
            if (SZFriendsPublishAcrossVolumes) {
                number = EXDEV;
            } else if (renamex_np(staged.fileSystemRepresentation, final.fileSystemRepresentation, RENAME_EXCL) != 0) {
                number = errno;
            } else {
                SZFriendsSyncDirectory(folder);
            }
            if (number == EXDEV) number = SZFriendsCopyAcross(staged, final);
            if (number == 0) {
                SZFriendsRecordReceivedFallback(stateDirectory, [folder isEqualToString:meant]
                                                                    ? SZFriendsReceivedFallbackNone
                                                                : [folder isEqualToString:downloads]
                                                                    ? SZFriendsReceivedFallbackDownloads
                                                                    : SZFriendsReceivedFallbackKept);
                return final;
            }
            if (number == EEXIST) continue; // something took the name since it was chosen: the next number
            if (SZFriendsFolderRefused(number)) break;
            SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase,
                                                         [NSString stringWithFormat:@"cannot publish: %s",
                                                                                    strerror(number)]));
            return nil;
        }
    }
    SZFriendsFail(error, SZFriendsStoreMakeError(SZFriendsStoreErrorDatabase, @"no folder takes the file"));
    return nil;
}

#pragma mark - Transfers

@implementation SZFriendsReceivedFile
@end

@implementation SZFriendsTransfers (ReceivedFolder)

// received/ is always directly inside the state directory.
- (NSString *)ownStateDirectory {
    return self.receivedDirectory.stringByDeletingLastPathComponent;
}

- (NSString *)destinationDirectory {
    return SZFriendsReceivedFolder(self.ownStateDirectory);
}

- (uint64_t)freeBytesForReceiving {
    uint64_t staging = self.freeBytesProvider(self.ownStateDirectory);
    NSString *destination = self.destinationDirectory;
    struct stat a, b;
    // Downloads not made yet: the volume it will be made on.
    while (destination.length > 1 && stat(destination.fileSystemRepresentation, &b) != 0) {
        destination = destination.stringByDeletingLastPathComponent;
    }
    // Same volume: one number. Elsewhere the file needs room in both places, for the staging and the copy.
    if (stat(self.ownStateDirectory.fileSystemRepresentation, &a) == 0 &&
        stat(destination.fileSystemRepresentation, &b) == 0 && a.st_dev == b.st_dev) {
        return staging;
    }
    return MIN(staging, self.freeBytesProvider(destination));
}

- (NSArray<SZFriendsReceivedFile *> *)receivedFilesWithLimit:(NSUInteger)limit {
    NSMutableArray<SZFriendsReceivedFile *> *files = [NSMutableArray array];
    [self.store performRead:^(SZFriendsStoreDB *_Nullable db) {
        // Rows whose file was moved or deleted since are skipped, so read a few more than asked.
        [db run:@"SELECT transfer_id, received_path, coalesce(received_at, updated_at), received_via FROM transfers "
                @"WHERE outgoing = 0 AND state = ? AND received_path IS NOT NULL "
                @"ORDER BY coalesce(received_at, updated_at) DESC, transfer_id LIMIT ?"
            binds:@[ @(SZFriendsTransferStateReceived), @(limit * 4) ]
              row:^(sqlite3_stmt *statement) {
                  if (files.count >= limit) return;
                  NSString *path = SZFriendsColumnText(statement, 1);
                  struct stat info;
                  if (path == nil || lstat(path.fileSystemRepresentation, &info) != 0) return;
                  SZFriendsReceivedFile *file = [[SZFriendsReceivedFile alloc] init];
                  file.transferID = SZFriendsColumnText(statement, 0) ?: @"";
                  file.path = path;
                  file.receivedAt = SZFriendsColumnDate(statement, 2) ?: [NSDate date];
                  NSInteger via = SZFriendsColumnInt(statement, 3);
                  file.source = via == SZFriendsReceivedSourceLink     ? SZFriendsReceivedSourceLink
                                : via == SZFriendsReceivedSourceDevice ? SZFriendsReceivedSourceDevice
                                                                       : SZFriendsReceivedSourceFriend;
                  [files addObject:file];
              }
            error:NULL];
    }];
    return files;
}

@end

NS_ASSUME_NONNULL_END
