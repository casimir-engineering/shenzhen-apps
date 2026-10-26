#import "SPDFMacAICollectionTools.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacDocumentActivity.h"
static NSDictionary* Failure(NSString* message) { return @{@"error":message}; }
NSDictionary* SPDFAICollectionDocuments(NSString* query, NSUInteger first, NSProgress* progress) {
    if (progress.cancelled) return Failure(@"Cancelled.");
    NSArray* documents=[SPDFMacCollectionStore.defaultStore documents]; NSMutableArray* filtered=[NSMutableArray array],*sources=[NSMutableArray array];
    for (NSDictionary* doc in documents) {
        if (progress.cancelled) return Failure(@"Cancelled.");
        NSString* title=doc[@"title"] ?: [doc[@"path"] lastPathComponent] ?: @"Document";
        if (query.length && [title rangeOfString:query options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location==NSNotFound) continue;
        // Neither its source nor a saved copy can be opened: the assistant is never shown it.
        if (!SPDFCollectionOriginalAvailable(doc) && ![doc[@"versions"] count]) continue;
        [filtered addObject:@{@"documentID":[@"collection:" stringByAppendingString:doc[@"id"]],@"title":title,
            @"versionCount":@([doc[@"versions"] count]),@"originalAvailable":@(SPDFCollectionOriginalAvailable(doc))}];
        [sources addObject:doc];
    }
    NSUInteger start=first ? first-1 : 0;
    if (start>filtered.count) return Failure(@"Collection result offset is outside the list.");
    NSUInteger count=MIN((NSUInteger)50,filtered.count-start);
    // A document's original, the names it had and its History copies are one document: the latest of each date.
    NSMutableArray* page=[NSMutableArray array],*paths=[NSMutableArray array],*groups=[NSMutableArray array];
    for (NSDictionary* doc in [sources subarrayWithRange:NSMakeRange(start,count)]) {
        NSMutableArray* own=[NSMutableArray array];
        for (id path in [@[doc[@"path"] ?: @""] arrayByAddingObjectsFromArray:[doc[@"aliases"] isKindOfClass:NSArray.class] ? doc[@"aliases"] : @[]])
            if ([path isKindOfClass:NSString.class] && [path length]) [own addObject:[path stringByStandardizingPath]];
        for (NSString* copy in [SPDFMacCollectionStore.defaultStore editablePathsForDocument:doc]) [own addObject:copy.stringByStandardizingPath];
        [groups addObject:own]; [paths addObjectsFromArray:own];
    }
    NSDictionary* entries=progress.cancelled ? @{} : [SPDFMacDocumentActivityStore.sharedStore entriesForPaths:paths];
    for (NSUInteger index=0;index<count;index++) {
        NSMutableArray* found=[NSMutableArray array];
        for (NSString* path in groups[index]) if (entries[path]) [found addObject:entries[path]];
        NSMutableDictionary* row=[filtered[start+index] mutableCopy];
        [row addEntriesFromDictionary:SPDFDocumentActivityFields(SPDFDocumentActivityCombine(found),NSTimeZone.localTimeZone)];
        [page addObject:row];
    }
    return @{@"documents":page,@"total":@(filtered.count),
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
