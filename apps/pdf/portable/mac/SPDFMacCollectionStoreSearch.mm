#import "SPDFMacCollectionStorePrivate.h"
#import "SPDFMacSearchFileCache.h"

@implementation SPDFMacCollectionStore (Search)
- (NSArray*)search:(NSString*)query titlesOnly:(BOOL)titlesOnly excludingPaths:(NSSet<NSString*>*)paths
             limit:(NSUInteger)limit {
    return [self search:query titlesOnly:titlesOnly excludingPaths:paths limit:limit progress:nil];
}
- (NSArray*)search:(NSString*)query titlesOnly:(BOOL)titlesOnly excludingPaths:(NSSet<NSString*>*)paths
             limit:(NSUInteger)limit progress:(NSProgress*)progress {
    if (progress.cancelled) return @[];
    query=[query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray* matches=[NSMutableArray array];
    NSStringCompareOptions flags=NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch;
    NSString* manifestPath = [[self.rootURL URLByAppendingPathComponent:@"manifest.json"] path];
    NSDictionary* manifest = SPDFSearchCachedJSON(manifestPath);
    NSArray* documents = [manifest[@"documents"] isKindOfClass:NSDictionary.class]
        ? [manifest[@"documents"] allValues] : @[];
    for (NSDictionary* doc in documents) {
        if (progress.cancelled) return @[];
        if ((!([doc[@"sourceReplaced"] boolValue]) && [paths containsObject:doc[@"path"]]) || ![doc[@"versions"] count]) continue;
        NSDictionary* version=[doc[@"versions"] lastObject]; NSString* title=doc[@"title"] ?: @"";
        if (titlesOnly) {
            NSMutableArray* names=[NSMutableArray arrayWithObject:title]; [names addObjectsFromArray:doc[@"aliases"] ?: @[]];
            BOOL match=!query.length;
            for (NSString* name in names) if ([name rangeOfString:query options:flags].location!=NSNotFound) { match=YES; break; }
            if (!match) continue;
            NSMutableDictionary* row=[doc mutableCopy];
            row[@"rank"]=@([title compare:query options:flags]==NSOrderedSame ? 0 :
                           ([title rangeOfString:query options:flags].location==0 ? 1 : 2));
            [matches addObject:row];
        } else if (query.length && ![version[@"encrypted"] boolValue]) {
            for (NSDictionary* page in [self textIndexForVersion:version][@"textPages"]) {
                if (progress.cancelled) return @[];
                NSString* text=page[@"text"]; NSRange range=[text rangeOfString:query options:flags];
                if (range.location==NSNotFound) continue;
                NSUInteger start=range.location>70 ? range.location-70 : 0;
                NSUInteger length=MIN(text.length-start,query.length+140);
                NSMutableDictionary* row=[doc mutableCopy];
                row[@"page"]=page[@"page"]; row[@"query"]=query;
                row[@"snippet"]=[[text substringWithRange:NSMakeRange(start,length)]
                                  stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
                row[@"rank"]=@0; [matches addObject:row];
                // A document contributes its best first-page match, avoiding one long PDF filling the palette.
                break;
            }
        }
    }
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
        NSComparisonResult rank=[a[@"rank"] compare:b[@"rank"]];
        return rank!=NSOrderedSame ? rank : [b[@"capturedAt"] compare:a[@"capturedAt"]];
    }];
    if (limit && matches.count>limit) [matches removeObjectsInRange:NSMakeRange(limit,matches.count-limit)];
    return matches;
}
- (NSArray*)locateCandidatesForDocumentID:(NSString*)documentID roots:(NSArray<NSURL*>*)roots
                              cancelled:(BOOL (^)(void))cancelled error:(NSError**)error {
    NSDictionary* doc=[self readManifest][@"documents"][documentID]; NSDictionary* latest=[doc[@"versions"] lastObject];
    if (!latest) { if(error)*error=SPDFCollectionError(8,@"No protected revision is available to match."); return @[]; }
    NSMutableArray* matches=[NSMutableArray array]; NSMutableSet* seen=[NSMutableSet set];
    NSArray* keys=@[NSURLFileSizeKey,NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey,NSURLContentModificationDateKey];
    NSUInteger checked=0; __block NSError* searchError;
    for (NSURL* root in roots) {
        if (cancelled && cancelled()) break;
        NSDirectoryEnumerator* enumerator=[NSFileManager.defaultManager enumeratorAtURL:root
          includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsPackageDescendants|
            NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL* URL,NSError* failure) {
                (void)URL; if(!searchError)searchError=failure; return YES;
            }];
        for (NSURL* URL in enumerator) {
            if ((cancelled && cancelled()) || ++checked>500000) break;
            NSString* path=URL.path;
            if ([self isArchivePath:path]) { [enumerator skipDescendants]; continue; }
            if ([seen containsObject:path]) continue; [seen addObject:path];
            NSDictionary* values=[URL resourceValuesForKeys:keys error:nil];
            if (![values[NSURLIsRegularFileKey] boolValue] || [values[NSURLIsSymbolicLinkKey] boolValue] ||
                ![values[NSURLFileSizeKey] isEqual:latest[@"size"]]) continue;
            struct stat before={},after={}; if (lstat(URL.fileSystemRepresentation,&before)!=0) continue;
            NSString* hash=SPDFCollectionHashURL(URL,nil);
            if (![hash isEqual:latest[@"hash"]] || lstat(URL.fileSystemRepresentation,&after)!=0 ||
                before.st_ino!=after.st_ino || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec ||
                before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec) continue;
            [matches addObject:@{@"path":path,@"hash":hash,@"size":latest[@"size"],@"exact":@YES,
                 @"modifiedAt":@((double)after.st_mtimespec.tv_sec+after.st_mtimespec.tv_nsec/1e9),
                 @"referenceCapturedAt":latest[@"capturedAt"]}];
        }
        if (checked>500000) {
            if(error)*error=SPDFCollectionError(14,@"Search reached its file limit. Choose a narrower folder to continue."); break;
        }
    }
    if (error && !*error) *error=searchError;
    [matches sortUsingComparator:^NSComparisonResult(NSDictionary* a,NSDictionary* b) {
        NSComparisonResult order=[a[@"modifiedAt"] compare:b[@"modifiedAt"]];
        return order==NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : order;
    }]; return matches;
}
@end
