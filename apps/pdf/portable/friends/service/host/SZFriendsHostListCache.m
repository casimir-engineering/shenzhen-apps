// The newest verified host list, cached in <state dir>/hosts.json, with the list bundled in the helper as a floor
// (ADR 0005 § Signed host list). The cache is re-verified against the pinned keys on every load, so a release
// that drops a compromised key also drops every cached list only that key signed.

#import "service/host/SZFriendsHostInternal.h"

#import <os/log.h>

@implementation SZFriendsHostListCache {
    NSString *_cachePath;
    NSArray<NSData *> *_pinnedKeys;
    SZFriendsHostList *_current;
    NSObject *_lock;
}

- (instancetype)initWithCachePath:(NSString *)cachePath
                    bootstrapData:(NSData *)bootstrapData
                       pinnedKeys:(NSArray<NSData *> *)pinnedKeys {
    if ((self = [super init])) {
        _cachePath = [cachePath copy];
        _pinnedKeys = [pinnedKeys copy];
        _lock = [[NSObject alloc] init];
        _current = [self loadWithBootstrap:bootstrapData];
    }
    return self;
}

- (SZFriendsHostList *)loadWithBootstrap:(NSData *)bootstrapData {
    NSError *error = nil;
    SZFriendsHostList *bootstrap = [SZFriendsHostList listFromSignedData:bootstrapData
                                                              pinnedKeys:_pinnedKeys
                                                                   error:&error];
    if (bootstrap == nil) {
        // A build whose bundled list does not verify with its own pinned keys; the host suite's consistency test
        // is meant to stop that before release. Without a trusted list there is nothing safe to connect to.
        os_log_error(OS_LOG_DEFAULT, "Friends: bundled host list does not verify: %{public}@",
                     error.localizedDescription);
    }
    NSData *cached = [NSData dataWithContentsOfFile:_cachePath];
    SZFriendsHostList *cache = cached ? [SZFriendsHostList listFromSignedData:cached pinnedKeys:_pinnedKeys error:NULL]
                                      : nil;
    if (cached != nil && cache == nil) {
        // Corrupt, or signed only by a key this release no longer pins.
        [[NSFileManager defaultManager] removeItemAtPath:_cachePath error:NULL];
    }
    if (bootstrap == nil) return cache ?: [SZFriendsHostList emptyList];
    BOOL sameAsBundled = cache.version == bootstrap.version && [cache.payloadData isEqualToData:bootstrap.payloadData];
    if (cache != nil && (cache.version > bootstrap.version || sameAsBundled)) return cache;
    // The bundled list is a floor: an older cache, or one claiming the bundled version with other contents, is
    // replaced so the next start agrees with this one.
    if (![cached isEqualToData:bootstrap.signedData]) [self write:bootstrap.signedData];
    return bootstrap;
}

- (BOOL)write:(NSData *)data {
    NSError *error = nil;
    NSString *directory = [_cachePath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions : @0700}
                                                    error:NULL];
    if (![data writeToFile:_cachePath options:NSDataWritingAtomic error:&error]) {
        os_log_error(OS_LOG_DEFAULT, "Friends: could not cache the host list: %{public}@", error.localizedDescription);
        return NO;
    }
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @0600} ofItemAtPath:_cachePath error:NULL];
    return YES;
}

- (SZFriendsHostList *)currentList {
    @synchronized(_lock) {
        return _current;
    }
}

- (BOOL)offerSignedList:(NSData *)data error:(NSError **)error {
    SZFriendsHostList *list = [SZFriendsHostList listFromSignedData:data pinnedKeys:_pinnedKeys error:error];
    if (list == nil) return NO;
    @synchronized(_lock) {
        if (list.version < _current.version) {
            if (error) *error = SZFriendsHostMakeError(SZFriendsHostErrorStale, @"Older than the current host list.");
            return NO;
        }
        if (list.version == _current.version) {
            BOOL same = [list.payloadData isEqualToData:_current.payloadData];
            if (error) {
                *error = same ? SZFriendsHostMakeError(SZFriendsHostErrorAlreadyCurrent, @"Already the current list.")
                              : SZFriendsHostMakeError(SZFriendsHostErrorSubstituted,
                                                       @"Same version as the current list with different contents.");
            }
            return NO;
        }
        // Adopted even if the write fails: this run uses the newer list, and the next start falls back to the
        // last cached or bundled one, which is still a list the admin signed.
        [self write:list.signedData];
        _current = list;
        return YES;
    }
}

@end
