#import "SPDFMacCollectionStorePrivate.h"
NSDictionary* SPDFCollectionFingerprint(NSString* path) {
    struct stat st={};
    if (stat(path.fileSystemRepresentation,&st)!=0 || !S_ISREG(st.st_mode)) return @{};
    return SPDFCollectionFingerprintFromStat(&st);
}
NSDictionary* SPDFCollectionFingerprintFromStat(const struct stat* value) {
    struct stat st=*value;
    return @{@"device":@((unsigned long long)st.st_dev),@"inode":@((unsigned long long)st.st_ino),
      @"size":@((unsigned long long)st.st_size),@"mtime":@((long long)st.st_mtimespec.tv_sec),
      @"mtimeNS":@(st.st_mtimespec.tv_nsec),@"ctime":@((long long)st.st_ctimespec.tv_sec),@"ctimeNS":@(st.st_ctimespec.tv_nsec)};
}
@implementation SPDFMacCollectionStore (Fingerprint)
- (NSData*)readCaptureBytesForPath:(NSString*)path error:(NSError**)error {
    NSDictionary* context = NSThread.currentThread.threadDictionary[[NSString stringWithFormat:@"SPDFCollectionCapture.%p",self]];
    NSDictionary* copy = [context[@"path"] isEqual:SPDFCollectionPath(path)] ? context[@"userOpenState"][@"authorizedCopy"] : nil;
    if ([context[@"directSourceProtection"] boolValue]) copy = nil;
    if (!copy) return [NSData dataWithContentsOfFile:path options:0 error:error];
    NSString* readPath = copy[@"path"];
    NSDictionary* sourceStat = copy[@"source"], *copyStat = copy[@"copy"];
    if (![sourceStat isKindOfClass:NSDictionary.class] || !sourceStat.count ||
        ![sourceStat isEqual:SPDFCollectionFingerprint(path)]) {
        if (error) *error=SPDFCollectionSourceUnavailable(@"The original changed before capture. Reopen the document to refresh it.");
        return nil;
    }
    if (![readPath isKindOfClass:NSString.class] || ![copyStat isKindOfClass:NSDictionary.class] ||
        !copyStat.count || ![copyStat isEqual:SPDFCollectionFingerprint(readPath)]) {
        if (error) *error=SPDFCollectionError(5,@"The authorized reading copy is unavailable or changed. Reopen the document to refresh it.");
        return nil;
    }
    NSError* copyError=nil;
    NSData* bytes = [NSData dataWithContentsOfFile:readPath options:0 error:&copyError];
    if (!bytes || ![copyStat isEqual:SPDFCollectionFingerprint(readPath)] || bytes.length != [sourceStat[@"size"] unsignedLongLongValue]) {
        if (error) *error=SPDFCollectionError(5,copyError.localizedDescription ?: @"The private reading copy changed during capture. Retry after reopening.");
        return nil;
    }
    if (![sourceStat isEqual:SPDFCollectionFingerprint(path)]) {
        if (error) *error=SPDFCollectionSourceUnavailable(@"The original changed during capture. Reopen the document to refresh it.");
        return nil;
    }
    return bytes;
}
- (void)recordFingerprints:(NSMutableDictionary*)doc source:(NSDictionary*)source dependencies:(NSDictionary*)dependencies {
    NSDictionary* version=[doc[@"versions"] lastObject];
    doc[@"sourceFingerprint"]=source;
    NSMutableDictionary* objects=[NSMutableDictionary dictionary];
    objects[version[@"hash"]]=SPDFCollectionFingerprint([self blobURL:version[@"hash"]].path);
    for (NSDictionary* asset in version[@"assets"]) {
        objects[asset[@"hash"]]=SPDFCollectionFingerprint([self blobURL:asset[@"hash"]].path);
    }
    doc[@"dependencyFingerprints"]=dependencies; doc[@"objectFingerprints"]=objects;
}
- (BOOL)canReuseProtection:(NSDictionary*)doc path:(NSString*)path {
    if (![doc[@"status"] isEqual:@"Protected"] || ![doc[@"path"] isEqual:path]) return NO;
    NSDictionary* version=[doc[@"versions"] lastObject];
    // Missing dependencies can become available without source edits; a capture retries those explicitly.
    if (!version || [version[@"assetWarnings"] count]) return NO;
    NSDictionary* source=SPDFCollectionFingerprint(path);
    if (!source.count || ![source isEqual:doc[@"sourceFingerprint"]]) return NO;
    NSDictionary* dependencies=doc[@"dependencyFingerprints"]; NSDictionary* objects=doc[@"objectFingerprints"];
    if (!objects[version[@"hash"]] || dependencies.count!=[version[@"assets"] count]) return NO;
    for (NSDictionary* asset in version[@"assets"]) if (!objects[asset[@"hash"]]) return NO;
    for (NSString* relative in dependencies) {
        NSString* assetPath=[path.stringByDeletingLastPathComponent stringByAppendingPathComponent:relative];
        if (![SPDFCollectionFingerprint(assetPath) isEqual:dependencies[relative]]) return NO;
    }
    for (NSString* hash in objects)
        if (![SPDFCollectionFingerprint([self blobURL:hash].path) isEqual:objects[hash]]) return NO;
    return YES;
}
@end
