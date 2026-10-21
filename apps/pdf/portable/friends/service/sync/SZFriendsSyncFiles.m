// Files between own devices (friends-multi-device.md § Sync, Files): every device knows every transfer record at once;
// the bytes copy by themselves up to SZFriendsSyncAutoCopyMax, always in the You conversation, and otherwise when the
// person asks ("On MacBook Pro · Get"). The copy itself runs on a session (SZFriendsSyncExchange.m); here is which
// files to copy, where their bytes are, and what a finished copy becomes.

#import "service/sync/SZFriendsSyncInternal.h"

NS_ASSUME_NONNULL_BEGIN

static NSString *SZFriendsSyncWantKey(NSString *transferID) {
    return [@"want/" stringByAppendingString:transferID];
}

static BOOL SZFriendsSyncIsWholeFile(NSString *_Nullable path, uint64_t size) {
    if (path.length == 0) return NO;
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    return [attributes.fileType isEqualToString:NSFileTypeRegular] && attributes.fileSize == size;
}

NSString *_Nullable SZFriendsSyncLocalPathOfTransfer(SZFriendsTransferRecord *transfer) {
    if (!transfer.outgoing) {
        // Received here (or copied from another of our devices): the published file, where it was saved.
        BOOL received = transfer.state == SZFriendsTransferStateReceived;
        return received && SZFriendsSyncIsWholeFile(transfer.receivedPath, transfer.size) ? transfer.receivedPath : nil;
    }
    // Ours: the snapshot while it is kept, a copy from another of our devices, or the file it was sent from while it
    // is unchanged since (ADR 0016).
    if (SZFriendsSyncIsWholeFile(transfer.stagedPath, transfer.size)) return transfer.stagedPath;
    if (SZFriendsSyncIsWholeFile(transfer.receivedPath, transfer.size)) return transfer.receivedPath;
    BOOL unchanged = transfer.sourceModifiedNs != 0 &&
                     SZFriendsFileModifiedNs(transfer.sourcePath) == transfer.sourceModifiedNs;
    return unchanged && SZFriendsSyncIsWholeFile(transfer.sourcePath, transfer.size) ? transfer.sourcePath : nil;
}

@implementation SZFriendsSyncEngine (Files)

- (nullable NSString *)localPathOfFile:(NSString *)transferID {
    SZFriendsTransferRecord *transfer = [self.store transferRecordWithID:transferID];
    return transfer ? SZFriendsSyncLocalPathOfTransfer(transfer) : nil;
}

- (NSArray<SZFriendsSyncFileRecord *> *)filesWanted {
    NSData *me = self.identity.publicKey;
    NSMutableArray<SZFriendsSyncFileRecord *> *asked = [NSMutableArray array], *automatic = [NSMutableArray array];
    for (SZFriendsSyncFileRecord *file in [self.store syncFiles]) {
        SZFriendsTransferRecord *here = [self.store transferRecordWithID:file.transferID];
        if (here != nil && SZFriendsSyncLocalPathOfTransfer(here) != nil) continue; // its bytes are here
        BOOL elsewhere = NO;
        for (NSData *holder in file.holders) elsewhere = elsewhere || ![holder isEqualToData:me];
        if (!elsewhere) continue;
        if ([self.store syncStateForKey:SZFriendsSyncWantKey(file.transferID)] != nil) [asked addObject:file];
        // What the person moved or deleted here comes back only when they ask (Get).
        else if (here == nil && SZFriendsSyncCopiesAutomatically(file.size, file.conversationID)) {
            [automatic addObject:file];
        }
    }
    NSComparator older = ^NSComparisonResult(SZFriendsSyncFileRecord *a, SZFriendsSyncFileRecord *b) {
        NSComparisonResult order = [a.createdAt compare:b.createdAt];
        return order != NSOrderedSame ? order : [a.transferID compare:b.transferID];
    };
    [asked sortUsingComparator:older];
    [automatic sortUsingComparator:older];
    return [asked arrayByAddingObjectsFromArray:automatic];
}

- (BOOL)requestFile:(NSString *)transferID error:(NSError **)error {
    if ([self.store syncFileWithID:transferID] == nil) {
        return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"no such file record");
    }
    if (![self.store setSyncState:@1 forKey:SZFriendsSyncWantKey(transferID) error:error]) return NO;
    if (self.onNewEvents) self.onNewEvents(); // sessions look for something to copy
    return YES;
}

- (BOOL)isFileRequested:(NSString *)transferID {
    return [self.store syncStateForKey:SZFriendsSyncWantKey(transferID)] != nil;
}

- (BOOL)cancelFileRequest:(NSString *)transferID error:(NSError **)error {
    if (![self.store setSyncState:nil forKey:SZFriendsSyncWantKey(transferID) error:error]) return NO;
    if (self.onNewEvents) self.onNewEvents(); // sessions let a copy of it go
    return YES;
}

- (BOOL)adoptCopiedFile:(NSString *)transferID atPath:(NSString *)path error:(NSError **)error {
    SZFriendsSyncFileRecord *file = [self.store syncFileWithID:transferID];
    if (file == nil) return SZFriendsSyncFail(error, SZFriendsSyncErrorMalformed, @"no such file record");
    NSFileManager *files = NSFileManager.defaultManager;
    // Where every received file goes (the chosen folder, else Downloads), quarantined, never replacing anything.
    NSString *destination = SZFriendsPublishReceivedFile(path, SZFriendsSanitizedFileName(file.fileName),
                                                         self.receivedDirectory.stringByDeletingLastPathComponent,
                                                         nil, error);
    if (destination == nil) return NO;
    SZFriendsTransferRecord *transfer = [[SZFriendsTransferRecord alloc] init];
    transfer.transferID = file.transferID;
    transfer.conversationID = file.conversationID;
    transfer.outgoing = file.outgoing;
    transfer.state = file.state;
    transfer.fileName = file.fileName;
    transfer.uniformType = file.uniformType;
    transfer.size = file.size;
    transfer.contentDigest = file.contentDigest;
    transfer.createdAt = file.createdAt;
    if (![self.store insertCopiedTransfer:transfer path:destination error:error]) {
        [files removeItemAtPath:destination error:NULL];
        return NO;
    }
    [self.store setSyncState:nil forKey:SZFriendsSyncWantKey(transferID) error:NULL];
    [self noteChangedConversation:file.conversationID];
    [self flushChanges];
    // Now held here too: the next capture says so, and other devices may copy it from this one.
    [self captureLocalChanges];
    return YES;
}

@end

NS_ASSUME_NONNULL_END
