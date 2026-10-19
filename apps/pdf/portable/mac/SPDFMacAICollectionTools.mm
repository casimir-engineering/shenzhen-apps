#import "SPDFMacAICollectionTools.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionAvailability.h"
static NSDictionary* Failure(NSString* message) { return @{@"error":message}; }
NSDictionary* SPDFAICollectionDocuments(NSString* query, NSUInteger first, NSProgress* progress) {
    if (progress.cancelled) return Failure(@"Cancelled.");
    NSArray* documents=[SPDFMacCollectionStore.defaultStore documents]; NSMutableArray* filtered=[NSMutableArray array];
    for (NSDictionary* doc in documents) {
        if (progress.cancelled) return Failure(@"Cancelled.");
        NSString* title=doc[@"title"] ?: [doc[@"path"] lastPathComponent] ?: @"Document";
        if (query.length && [title rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location==NSNotFound) continue;
        [filtered addObject:@{@"documentID":[@"collection:" stringByAppendingString:doc[@"id"]],@"title":title,
            @"versionCount":@([doc[@"versions"] count]),@"originalAvailable":@(SPDFCollectionOriginalAvailable(doc))}];
    }
    NSUInteger start=first ? first-1 : 0;
    if (start>filtered.count) return Failure(@"Collection result offset is outside the list.");
    NSUInteger count=MIN((NSUInteger)50,filtered.count-start);
    return @{@"documents":[filtered subarrayWithRange:NSMakeRange(start,count)],@"total":@(filtered.count),
        @"next":start+count<filtered.count ? @(start+count+1) : NSNull.null};
}
NSDictionary* SPDFAICollectionOpenTarget(NSString* identifier, BOOL savedCopy, NSProgress* progress) {
    if (progress.cancelled || ![identifier hasPrefix:@"collection:"]) return Failure(@"Use a documentID returned by list_collection.");
    NSString* raw=[identifier substringFromIndex:11]; NSDictionary* document=nil;
    SPDFMacCollectionStore* store=SPDFMacCollectionStore.defaultStore;
    for (NSDictionary* row in [store documents]) if ([row[@"id"] isEqual:raw]) { document=row; break; }
    if (!document) return Failure(@"This document is no longer in Collection.");
    if (progress.cancelled) return Failure(@"Cancelled.");
    if (!savedCopy && SPDFCollectionOriginalAvailable(document) && [NSFileManager.defaultManager isReadableFileAtPath:document[@"path"]])
        return @{@"readPath":document[@"path"],@"archived":@NO};
    NSString* version=document[@"latestVersionID"];
    if (!version.length) version=[document[@"versions"] lastObject][@"id"];
    if (!version.length) return Failure(@"This document has no saved copy and its original is unavailable.");
    NSError* error=nil; NSURL* target=[store editableVersionID:version documentID:raw error:&error];
    if (!target) return Failure(error.localizedDescription ?: @"Saved copy could not be prepared.");
    if (progress.cancelled) return Failure(@"Cancelled.");
    return @{@"readPath":target.path,@"archived":@YES};
}
