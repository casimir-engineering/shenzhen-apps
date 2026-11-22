// Pictures' text in Collection: see SPDFMacPictureTextStore.h.
#import "SPDFMacPictureTextStore.h"
#import "SPDFMacCollectionStorePrivate.h"

static NSString* const NoTextKey = @"picturesWithoutText";  // manifest: {hash: when it was looked at}
static const NSUInteger NoTextLimit = 20000;                // the oldest are forgotten past this

static NSMutableDictionary* LatestRow(NSMutableDictionary* manifest, NSString* documentID) {
    NSMutableDictionary* doc = manifest[@"documents"][documentID];
    return [doc isKindOfClass:NSMutableDictionary.class] && [doc[@"versions"] count] ? doc : nil;
}

static NSString* PageText(NSDictionary* page) {
    NSMutableArray* texts = [NSMutableArray array];
    for (NSDictionary* line in page[@"lines"])
        if ([line[@"text"] isKindOfClass:NSString.class]) [texts addObject:line[@"text"]];
    return [texts componentsJoinedByString:@"\n"];
}

@implementation SPDFMacCollectionStore (PictureText)

- (NSDictionary*)pictureTextForPath:(NSString*)path hash:(NSString*)hash {
    NSDictionary* doc = [self documentForPath:path];
    NSDictionary* latest = [doc[@"versions"] lastObject];
    if (!hash.length || ![latest[@"hash"] isEqual:hash] || ![latest[@"pictureText"] isEqual:@"found"]) return nil;
    NSDictionary* recognized = [self textIndexForVersion:latest][@"pictureText"];
    return [recognized isKindOfClass:NSDictionary.class] ? recognized : nil;
}

- (BOOL)pictureHashHasNoText:(NSString*)hash {
    NSDictionary* seen = [self readManifest][NoTextKey];
    return hash.length && [seen isKindOfClass:NSDictionary.class] && seen[hash] != nil;
}

- (void)setPictureHash:(NSString*)hash hasNoText:(BOOL)noText {
    if (!hash.length || noText == [self pictureHashHasNoText:hash]) return;
    [self manifestTransaction:^BOOL(NSMutableDictionary* m, NSError** e) {
        (void)e;
        NSMutableDictionary* seen = [m[NoTextKey] isKindOfClass:NSDictionary.class] ? [m[NoTextKey] mutableCopy]
                                                                                    : [NSMutableDictionary dictionary];
        if (noText) seen[hash] = @(floor(NSDate.date.timeIntervalSince1970));
        else [seen removeObjectForKey:hash];
        if (seen.count > NoTextLimit) {
            NSArray* oldest = [seen keysSortedByValueUsingSelector:@selector(compare:)];
            [seen removeObjectsForKeys:[oldest subarrayWithRange:NSMakeRange(0, seen.count - NoTextLimit)]];
        }
        m[NoTextKey] = seen;
        return YES;
    } writeBack:YES error:nil];
}

- (BOOL)attachPictureText:(NSDictionary*)recognized documentID:(NSString*)documentID hash:(NSString*)hash
                    error:(NSError**)error {
    NSMutableArray* pages = [NSMutableArray array];
    for (NSDictionary* page in recognized[@"pages"])
        [pages addObject:@{@"page": page[@"page"] ?: @1, @"text": PageText(page)}];
    NSData* index = [NSJSONSerialization dataWithJSONObject:@{@"textPages": pages, @"encrypted": @NO,
                                                              @"pictureText": recognized} options:0 error:error];
    if (!index) return NO;
    return [self transaction:^BOOL(NSMutableDictionary* m, NSError** e) {
        NSMutableDictionary* doc = LatestRow(m, documentID);
        NSMutableDictionary* latest = [[doc[@"versions"] lastObject] mutableCopy];
        if (!latest || ![latest[@"hash"] isEqual:hash]) {
            if (e) *e = SPDFCollectionError(8, @"The picture changed before its text was kept.");
            return NO;
        }
        NSString* filename = [latest[@"id"] stringByAppendingPathExtension:@"json"];
        NSURL* URL = [[self.rootURL URLByAppendingPathComponent:@"indexes"] URLByAppendingPathComponent:filename];
        if (!SPDFCollectionMakeDirectory(URL.URLByDeletingLastPathComponent, e) ||
            !SPDFCollectionAtomicData(index, URL, 0400, e)) return NO;
        latest[@"indexFile"] = filename;
        latest[@"pictureText"] = @"found";
        NSMutableArray* versions = [doc[@"versions"] mutableCopy];
        versions[versions.count - 1] = latest;
        doc[@"versions"] = versions;
        return YES;
    } error:error];
}

- (BOOL)removePictureWithoutTextDocumentID:(NSString*)documentID error:(NSError**)error {
    NSDictionary* doc = [self readManifest][@"documents"][documentID];
    NSString* path = doc[@"path"];
    BOOL directory = NO;
    BOOL originalThere = [path isKindOfClass:NSString.class] && ![doc[@"sourceReplaced"] boolValue] &&
        [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory;
    if (originalThere) return [self purgeDocumentIDs:@[documentID] error:error];
    [self transaction:^BOOL(NSMutableDictionary* m, NSError** e) {
        (void)e;
        NSMutableDictionary* row = LatestRow(m, documentID);
        NSMutableDictionary* latest = [[row[@"versions"] lastObject] mutableCopy];
        if (!latest) return NO;
        latest[@"pictureText"] = @"none";
        NSMutableArray* versions = [row[@"versions"] mutableCopy];
        versions[versions.count - 1] = latest;
        row[@"versions"] = versions;
        return YES;
    } error:nil];
    return NO;
}

- (NSArray*)picturesAwaitingText:(BOOL (^)(NSString*))isPicture {
    NSMutableArray* waiting = [NSMutableArray array];
    NSDictionary* documents = [self readManifest][@"documents"];
    for (NSString* documentID in documents) {
        NSDictionary* doc = documents[documentID];
        NSDictionary* latest = [doc[@"versions"] lastObject];
        NSString* name = latest[@"filename"] ?: doc[@"title"] ?: [doc[@"path"] lastPathComponent];
        if (!latest || [doc[@"excluded"] boolValue] || latest[@"pictureText"] || ![name isKindOfClass:NSString.class] ||
            !isPicture(name) || [doc[@"editableCopies"] count])
            continue;
        [waiting addObject:@{@"documentID": documentID, @"versionID": latest[@"id"] ?: @"", @"hash": latest[@"hash"] ?: @"",
                             @"path": doc[@"path"] ?: @""}];
    }
    return waiting;
}
@end
