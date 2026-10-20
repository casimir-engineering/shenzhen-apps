#import "SPDFMacFriendsReceivedFiles.h"
#import "SPDFMacCollectionStore.h"

NSString* const SPDFMacFriendsReceivedFolderCapability = @"received.folder";

@implementation SPDFMacFriendsReceivedFiles {
    SPDFMacCollectionStore* _store;
    BOOL (^_isDocument)(NSString*);
    __weak SZFriendsHelperLink* _link;
    NSString* _subscription;
    // On _queue only: transfers already decided (taken, someone else's, history, or not a document), so a snapshot
    // that lists them again costs no manifest read.
    NSMutableSet<NSString*>* _settled;
    BOOL _started;
    dispatch_queue_t _queue;
}

- (instancetype)initWithStore:(SPDFMacCollectionStore*)store isDocument:(BOOL (^)(NSString*))isDocument {
    if (!(self = [super init])) return nil;
    _store = store;
    _isDocument = [isDocument copy];
    _settled = [NSMutableSet set];
    // Claims read and write the Collection manifest under its file lock: never on the main thread.
    _queue = dispatch_queue_create("com.intuition.shenzhenpdf.friends-received", DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_queue, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    return self;
}

- (void)followLink:(SZFriendsHelperLink*)link {
    if (_subscription || link.state != SZFriendsLinkStateReady ||
        ![link.helperCapabilities containsObject:SPDFMacFriendsReceivedFolderCapability])
        return;
    _link = link;
    __weak SPDFMacFriendsReceivedFiles* weakSelf = self;
    _subscription = [link subscribeToView:@"received" params:nil handler:^(NSDictionary* data, NSInteger rev) {
        (void)rev;
        [weakSelf takeSnapshot:data];
    }];
}

- (void)stop {
    if (_subscription) [_link unsubscribe:_subscription];
    _subscription = nil;
    _link = nil;
}

- (void)takeSnapshot:(NSDictionary*)data {
    NSMutableArray<NSDictionary*>* files = [NSMutableArray array];
    id listed = [data isKindOfClass:NSDictionary.class] ? data[@"files"] : nil;
    for (NSDictionary* file in [listed isKindOfClass:NSArray.class] ? listed : @[]) {
        if (![file isKindOfClass:NSDictionary.class]) continue;
        id identifier = file[@"transfer_id"], path = file[@"path"], receivedAt = file[@"received_at"];
        if ([identifier isKindOfClass:NSString.class] && [path isKindOfClass:NSString.class] &&
            [path isAbsolutePath] && [receivedAt isKindOfClass:NSNumber.class])
            [files addObject:@{@"id" : identifier, @"path" : path, @"at" : receivedAt}];
    }
    dispatch_async(_queue, ^{ [self claimFiles:files]; });
}

- (void)claimFiles:(NSArray<NSDictionary*>*)files {
    NSMutableDictionary<NSString*, NSNumber*>* candidates = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, NSString*>* paths = [NSMutableDictionary dictionary];
    for (NSDictionary* file in files) {
        NSString* identifier = file[@"id"];
        if ([_settled containsObject:identifier] || paths[identifier]) continue;
        NSString* path = file[@"path"];
        NSDictionary* attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if (![attributes.fileType isEqual:NSFileTypeRegular] || !_isDocument(path)) {
            if (attributes) [_settled addObject:identifier]; // a file still being moved into place is looked at again
            continue;
        }
        candidates[identifier] = file[@"at"];
        paths[identifier] = path;
    }
    NSArray<NSString*>* claimed = nil;
    // The first snapshot records the start even when it lists nothing new.
    if (candidates.count || !_started) {
        claimed = [_store claimReceivedFiles:candidates];
        if (claimed) {
            _started = YES;
            [_settled addObjectsFromArray:candidates.allKeys];
        }
    }
    NSMutableArray<NSString*>* capturing = [NSMutableArray array];
    for (NSString* identifier in claimed) [capturing addObject:paths[identifier]];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString* path in capturing) {
            [self->_store capturePath:path reason:@"Received" completion:^(NSDictionary* document, NSError* error) {
                if (self.captured) self.captured(path, document, error);
            }];
        }
        if (self.snapshotHandled) self.snapshotHandled(capturing);
    });
}

@end
