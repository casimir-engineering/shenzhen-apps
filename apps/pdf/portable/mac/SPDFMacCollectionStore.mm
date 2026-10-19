#import "SPDFMacCollectionStorePrivate.h"
#import "SPDFMacSearchFileCache.h"

NSNotificationName const SPDFCollectionStoreDidChangeNotification = @"SPDFCollectionStoreDidChange";

NSError* SPDFCollectionError(NSInteger code, NSString* message) {
    return [NSError errorWithDomain:@"SPDFCollection" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
NSString* SPDFCollectionPath(NSString* path) { return path.stringByStandardizingPath; }
BOOL SPDFCollectionMakeDirectory(NSURL* URL, NSError** error) {
    BOOL ok = [NSFileManager.defaultManager createDirectoryAtURL:URL withIntermediateDirectories:YES
                  attributes:@{NSFilePosixPermissions:@0700} error:error];
    return ok;
}
BOOL SPDFCollectionAtomicData(NSData* data, NSURL* URL, mode_t mode, NSError** error) {
    NSURL* temporary = [URL.URLByDeletingLastPathComponent URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, mode);
    if (fd < 0) { if (error) *error = SPDFCollectionError(errno, @"Cannot write Collection storage."); return NO; }
    const uint8_t* bytes = (const uint8_t*)data.bytes; NSUInteger written = 0; BOOL ok = YES;
    while (written < data.length) {
        ssize_t n = write(fd, bytes + written, data.length - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = NO; break; } written += n;
    }
    if (ok) ok = fsync(fd) == 0;
    close(fd);
    if (ok) ok = rename(temporary.fileSystemRepresentation, URL.fileSystemRepresentation) == 0;
    if (ok) {
        int dirfd = open(URL.URLByDeletingLastPathComponent.fileSystemRepresentation, O_RDONLY);
        if (dirfd >= 0) { ok = fsync(dirfd) == 0; close(dirfd); }
    }
    if (!ok) {
        unlink(temporary.fileSystemRepresentation);
        if (error) *error = SPDFCollectionError(errno, @"Collection could not durably save the revision.");
    }
    return ok;
}
NSString* SPDFCollectionHashURL(NSURL* URL, NSError** error) {
    int fd = open(URL.fileSystemRepresentation, O_RDONLY|O_NOFOLLOW);
    if (fd < 0) { if (error) *error = SPDFCollectionError(errno,@"Cannot read the complete source document."); return nil; }
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); unsigned char bytes[65536]; ssize_t n;
    while ((n = read(fd, bytes, sizeof(bytes))) > 0) CC_SHA256_Update(&ctx, bytes, (CC_LONG)n);
    close(fd);
    if (n < 0) { if (error) *error = SPDFCollectionError(errno,@"Source read failed."); return nil; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest,&ctx);
    NSMutableString* hash = [NSMutableString string];
    for (int i=0; i<CC_SHA256_DIGEST_LENGTH; ++i) [hash appendFormat:@"%02x",digest[i]];
    return hash;
}
@implementation SPDFMacCollectionStore
+ (instancetype)defaultStore {
    static SPDFMacCollectionStore* store; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* root = NSProcessInfo.processInfo.environment[@"SPDF_STATE_DIR"];
        if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ShenzhenPDF"];
        store = [[self alloc] initWithRootURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Collection"]]];
    });
    return store;
}
- (instancetype)initWithRootURL:(NSURL*)URL {
    if ((self = [super init])) { _rootURL = URL.URLByStandardizingPath; _originalRootURL = _rootURL; _localLock = [NSRecursiveLock new]; }
    return self;
}
- (NSURL*)rootURL {
    NSURL* URL = self.originalRootURL ?: _rootURL;
    for (NSUInteger depth=0; depth<8; ++depth) {
        NSData* bytes=[NSData dataWithContentsOfURL:[URL URLByAppendingPathComponent:@"redirect.json"]];
        NSDictionary* redirect=bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
        NSString* next=[redirect isKindOfClass:NSDictionary.class] ? redirect[@"path"] : nil;
        if (![next isKindOfClass:NSString.class] || !next.isAbsolutePath) break;
        URL=[NSURL fileURLWithPath:next];
    }
    return URL;
}
- (NSMutableDictionary*)readManifest {
    NSData* bytes = [NSData dataWithContentsOfURL:[self.rootURL URLByAppendingPathComponent:@"manifest.json"]];
    id value = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:NSJSONReadingMutableContainers error:nil] : nil;
    if ([value isKindOfClass:NSDictionary.class] && [value[@"documents"] isKindOfClass:NSDictionary.class]) return value;
    return [@{@"format":@1, @"settings":[NSMutableDictionary dictionary],
              @"documents":[NSMutableDictionary dictionary]} mutableCopy];
}
- (BOOL)transaction:(BOOL (^)(NSMutableDictionary*, NSError**))body error:(NSError**)error {
    NSString* previousRoot=self.rootURL.path;
    BOOL committed = [self manifestTransaction:body writeBack:YES error:error];
    // Deliver only after releasing both locks; observers may read the committed store.
    if (committed) {
        NSString* currentRoot=self.rootURL.path;
        NSDictionary* info=@{@"processID":@(NSProcessInfo.processInfo.processIdentifier),
            @"roots":@[self.originalRootURL.path,previousRoot,currentRoot]};
        [NSNotificationCenter.defaultCenter postNotificationName:SPDFCollectionStoreDidChangeNotification object:self userInfo:info];
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"SPDFCollectionStoreDidChangeAcrossProcesses"
            object:currentRoot userInfo:info deliverImmediately:YES];
    }
    return committed;
}
- (BOOL)withLockedManifest:(BOOL (^)(NSMutableDictionary*, NSError**))body error:(NSError**)error {
    return [self manifestTransaction:body writeBack:NO error:error];
}
- (BOOL)manifestTransaction:(BOOL (^)(NSMutableDictionary*, NSError**))body
                 writeBack:(BOOL)writeBack error:(NSError**)error {
    [self.localLock lock];
    NSURL* lockedRoot=self.rootURL;
    if (![lockedRoot isEqual:self.originalRootURL] &&
        ![NSFileManager.defaultManager fileExistsAtPath:[lockedRoot URLByAppendingPathComponent:@"manifest.json"].path]) {
        [self.localLock unlock];
        if(error)*error=SPDFCollectionError(17,@"Collection location is unavailable. Reconnect its drive or choose its saved folder.");
        return NO;
    }
    if (!SPDFCollectionMakeDirectory(lockedRoot,error)) { [self.localLock unlock]; return NO; }
    int fd = open([lockedRoot URLByAppendingPathComponent:@"collection.lock"].fileSystemRepresentation,
                  O_CREAT|O_RDWR|O_NOFOLLOW,0600);
    if (fd < 0 || flock(fd,LOCK_EX) != 0) {
        if (fd >= 0) close(fd); [self.localLock unlock];
        if (error) *error = SPDFCollectionError(errno,@"Collection is unavailable for writing."); return NO;
    }
    if (![lockedRoot isEqual:self.rootURL]) {
        flock(fd,LOCK_UN); close(fd); [self.localLock unlock];
        return [self manifestTransaction:body writeBack:writeBack error:error];
    }
    NSURL* manifestURL = [lockedRoot URLByAppendingPathComponent:@"manifest.json"];
    NSData* existing = [NSData dataWithContentsOfURL:manifestURL];
    // Never overwrite an unreadable/corrupt index with an empty one.
    id decoded = existing ? [NSJSONSerialization JSONObjectWithData:existing options:NSJSONReadingMutableContainers error:nil] : nil;
    BOOL valid = (![NSFileManager.defaultManager fileExistsAtPath:manifestURL.path] || existing) &&
                 (!existing || ([decoded isKindOfClass:NSDictionary.class] &&
                              [decoded[@"documents"] isKindOfClass:NSDictionary.class]));
    BOOL ok = NO;
    if (!valid) { if (error) *error = SPDFCollectionError(2,@"Collection index is damaged; retained snapshots are untouched."); }
    else {
        // Decode once while holding the file lock. Re-reading here doubled the
        // parse cost for every capture and every visible Collection thumbnail.
        NSMutableDictionary* manifest = decoded ?: [@{@"format":@1,
            @"settings":[NSMutableDictionary dictionary],@"documents":[NSMutableDictionary dictionary]} mutableCopy];
        ok = body(manifest,error);
        if (ok && writeBack && [lockedRoot isEqual:self.rootURL]) {
            BOOL collect=[manifest[@"_collectUnreferencedFiles"] boolValue];
            [manifest removeObjectForKey:@"_collectUnreferencedFiles"];
            NSData* bytes = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:error];
            ok = bytes && SPDFCollectionAtomicData(bytes,manifestURL,0600,error);
            if (ok && collect) [self collectUnreferencedFilesInManifest:manifest];
        }
    }
    flock(fd,LOCK_UN); close(fd); [self.localLock unlock]; return ok;
}
- (NSDictionary*)settings {
    NSURL* URL=[self.rootURL URLByAppendingPathComponent:@"manifest.json"];
    NSData* data=[NSData dataWithContentsOfURL:URL];
    if (![self.rootURL isEqual:self.originalRootURL] && !data)
        return @{@"choice":@"enabled",@"storageLimitBytes":@0,@"locationUnavailable":@YES};
    id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([NSFileManager.defaultManager fileExistsAtPath:URL.path] &&
        (![decoded isKindOfClass:NSDictionary.class] || ![decoded[@"documents"] isKindOfClass:NSDictionary.class]))
        return @{@"choice":@"enabled",@"storageLimitBytes":@0,@"indexDamaged":@YES};
    NSDictionary* saved = [self readManifest][@"settings"];
    NSMutableDictionary* values = [SPDFCollectionStorageSettings(saved) mutableCopy];
    values[@"choice"] = @"unset";
    [values addEntriesFromDictionary:saved ?: @{}];
    [values addEntriesFromDictionary:SPDFCollectionStorageSettings(saved)]; return values;
}
- (BOOL)updateSettings:(NSDictionary*)changes error:(NSError**)error {
    // Browsing preferences are persisted by the manager itself, not document mutations.
    return [self manifestTransaction:^BOOL(NSMutableDictionary* m,NSError** e) {
        (void)e; NSMutableDictionary* normalized=[changes mutableCopy];
        if (changes[@"storageLimitBytes"] && !changes[@"storageMode"])
            normalized[@"storageMode"]=[changes[@"storageLimitBytes"] unsignedLongLongValue] ? @"static" : @"unlimited";
        [m[@"settings"] addEntriesFromDictionary:normalized];
        [m[@"settings"] addEntriesFromDictionary:SPDFCollectionStorageSettings(m[@"settings"])]; return YES;
    } writeBack:YES error:error];
}
- (BOOL)isEnabled { return [[self settings][@"choice"] isEqual:@"enabled"]; }
- (NSArray*)documents {
    NSArray* rows = [[self readManifest][@"documents"] allValues];
    return [rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
        return [b[@"capturedAt"] ?: @0 compare:a[@"capturedAt"] ?: @0];
    }];
}
- (NSDictionary*)documentForPath:(NSString*)path {
    NSDictionary* editable=[self editableInfoForPath:path];
    if (editable) return editable[@"document"];
    path = SPDFCollectionPath(path);
    NSArray* rows=[self documents];
    for (NSDictionary* row in rows)
        if (![row[@"sourceReplaced"] boolValue] && [row[@"path"] isEqual:path]) return row;
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        for (NSDictionary* row in rows)
            if (![row[@"sourceReplaced"] boolValue] && [row[@"aliases"] containsObject:path]) return row;
    return nil;
}
- (NSArray*)versionsForDocumentID:(NSString*)documentID {
    return [self readManifest][@"documents"][documentID][@"versions"] ?: @[];
}
- (NSDictionary*)versionID:(NSString*)versionID document:(NSDictionary*)document {
    for (NSDictionary* row in document[@"versions"]) if ([row[@"id"] isEqual:versionID]) return row;
    return nil;
}
- (NSURL*)blobURL:(NSString*)hash {
    return [[self.rootURL URLByAppendingPathComponent:@"objects"] URLByAppendingPathComponent:hash];
}
- (BOOL)installBytes:(NSData*)data hash:(NSString*)hash error:(NSError**)error {
    NSURL* URL = [self blobURL:hash];
    if ([NSFileManager.defaultManager fileExistsAtPath:URL.path]) {
        if ([[SPDFCollectionHashURL(URL,error) lowercaseString] isEqual:hash]) return YES;
        if (error) *error = SPDFCollectionError(3,@"A retained Collection object failed its integrity check."); return NO;
    }
    return SPDFCollectionMakeDirectory(URL.URLByDeletingLastPathComponent,error) &&
           SPDFCollectionAtomicData(data,URL,0400,error);
}
- (NSDictionary*)textIndexForVersion:(NSDictionary*)version {
    if ([version[@"encrypted"] boolValue]) return @{};
    if ([version[@"textPages"] isKindOfClass:NSArray.class]) return version;
    NSString* filename=version[@"indexFile"];
    if (![filename isKindOfClass:NSString.class] || ![filename isEqual:filename.lastPathComponent]) return @{};
    NSURL* URL=[[self.rootURL URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:filename];
    return SPDFSearchCachedJSON(URL.path) ?: @{};
}
- (unsigned long long)storageUsedBytes {
    return [self retainedBytesInManifest:[self readManifest]];
}
- (BOOL)isArchivePath:(NSString*)path {
    if ([self editableInfoForPath:path]) return NO;
    NSString* root = self.rootURL.path.stringByResolvingSymlinksInPath;
    NSString* resolved = path.stringByResolvingSymlinksInPath;
    NSString* original=self.originalRootURL.path.stringByResolvingSymlinksInPath;
    return [resolved isEqual:root] || [resolved hasPrefix:[root stringByAppendingString:@"/"]] ||
           [resolved isEqual:original] || [resolved hasPrefix:[original stringByAppendingString:@"/"]];
}
@end
