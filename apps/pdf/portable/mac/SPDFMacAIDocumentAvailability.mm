#import "SPDFMacAIDocumentAvailability.h"
#import "SPDFMacAICitations.h"
#import "SPDFMacAITools.h"
#import "SPDFMacCollectionStore.h"
#import "SPDFMacCollectionAvailability.h"
#import "SPDFMacCollectionThumbnail.h"
#import <objc/runtime.h>

static char issuedKey, reportedKey, indexKey, indexDateKey, buildingKey, changedKey, thumbnailsKey;
static NSString* (^const Identify)(NSString*) = ^NSString*(NSString* path) { return SPDFAIDocumentIdentifier(path); };

NSArray<NSDictionary*>* SPDFMacAILinkableCollectionRows(SPDFMacCollectionStore* store) {
    if (![NSFileManager.defaultManager fileExistsAtPath:store.rootURL.path]) return @[];
    NSMutableArray* rows = [NSMutableArray array];
    for (NSDictionary* row in [store documents]) {
        NSArray* copies = [store editablePathsForDocument:row];
        if (!SPDFCollectionOriginalAvailable(row) && ![row[@"versions"] count] && !copies.count) continue;
        NSMutableDictionary* linkable = [row mutableCopy];
        linkable[@"editablePaths"] = copies;
        [rows addObject:linkable];
    }
    return rows;
}

@implementation ShenzhenMacDelegate (SPDFMacAIDocumentAvailability)

- (NSMutableDictionary<NSString*, NSString*>*)aiIssuedDocuments {
    NSMutableDictionary* issued = objc_getAssociatedObject(self, &issuedKey);
    if (!issued) objc_setAssociatedObject(self, &issuedKey, issued = [NSMutableDictionary dictionary],
                                          OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return issued;
}

- (void)aiNoteDocumentIdentifier:(NSString*)identifier path:(NSString*)path {
    if (identifier.length && path.length) [self aiIssuedDocuments][identifier] = path;
}

- (NSArray<NSString*>*)aiKnownDocumentPaths {
    NSMutableArray* paths = [[_recentlyOpenedPaths copy] ?: @[] mutableCopy];
    [paths addObjectsFromArray:[self aiIssuedDocuments].allValues];
    return paths;
}

- (NSSet<NSString*>*)aiOpenDocumentPathSet {
    NSMutableSet* open = [NSMutableSet set];
    for (SPDFDocumentTab* tab in _tabs) if (tab.path.length) [open addObject:tab.path];
    return open;
}

- (NSString*)aiClosedDocumentMessage:(NSString*)identifier {
    NSString* path = [identifier isKindOfClass:NSString.class] ? [self aiIssuedDocuments][identifier] : nil;
    if (!path) return @"Use an opaque document ID from list_workspace.";
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        return @"This document was deleted or moved and can no longer be opened. Do not cite it.";
    return @"This document is no longer open, so it cannot be read now; citations you already gave still open it. "
           @"To read it again, find it with list_collection and open_collection, or ask the user to open it.";
}

- (NSDictionary*)aiResultNotingUnavailableDocuments:(NSDictionary*)result {
    if (![result isKindOfClass:NSDictionary.class]) return nil;
    NSMutableSet* reported = objc_getAssociatedObject(self, &reportedKey);
    NSSet* open = [self aiOpenDocumentPathSet];
    NSMutableArray* gone = [NSMutableArray array];
    NSDictionary* issued = [self aiIssuedDocuments];
    for (NSString* identifier in issued) {
        NSString* path = issued[identifier];
        if ([reported containsObject:identifier] || [open containsObject:path] ||
            [NSFileManager.defaultManager fileExistsAtPath:path]) continue;
        [gone addObject:identifier];
    }
    if (!gone.count) return nil;
    if (!reported) objc_setAssociatedObject(self, &reportedKey, reported = [NSMutableSet set],
                                            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [reported addObjectsFromArray:gone];
    NSMutableDictionary* noted = [result mutableCopy];
    noted[@"documentsNoLongerAvailable"] = @{@"documents" : [gone sortedArrayUsingSelector:@selector(compare:)],
        @"note" : @"These documents were deleted or moved after you read them. Do not cite them or use their IDs."};
    return noted;
}

- (void)aiBuildDocumentIndex:(void (^)(NSDictionary<NSString*, NSDictionary*>*))completion {
    NSArray* open = [self aiOpenDocumentPathSet].allObjects;
    NSArray* known = [self aiKnownDocumentPaths];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSMutableArray* existing = [NSMutableArray array];
      for (NSString* path in known)
          if ([NSFileManager.defaultManager fileExistsAtPath:path]) [existing addObject:path];
      NSArray* rows = SPDFMacAILinkableCollectionRows(SPDFMacCollectionStore.defaultStore);
      NSDictionary* index = SPDFMacAIDocumentIndex(open, existing, rows, Identify);
      dispatch_async(dispatch_get_main_queue(), ^{ completion(index); });
    });
}

- (void)aiSetDocumentIndexChanged:(void (^)(void))changed {
    objc_setAssociatedObject(self, &changedKey, changed, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (void)aiRefreshDocumentIndex {
    if ([objc_getAssociatedObject(self, &buildingKey) boolValue]) return;
    objc_setAssociatedObject(self, &buildingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak ShenzhenMacDelegate* weakSelf = self;
    [self aiBuildDocumentIndex:^(NSDictionary* index) {
      ShenzhenMacDelegate* owner = weakSelf;
      if (!owner) return;
      NSDictionary* previous = objc_getAssociatedObject(owner, &indexKey);
      objc_setAssociatedObject(owner, &indexKey, index, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      objc_setAssociatedObject(owner, &indexDateKey, NSDate.date, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      objc_setAssociatedObject(owner, &buildingKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      void (^changed)(void) = objc_getAssociatedObject(owner, &changedKey);
      if (changed && ![[NSSet setWithArray:previous.allKeys] isEqual:[NSSet setWithArray:index.allKeys]]) changed();
    }];
}

- (BOOL)aiDocumentLinkAvailable:(NSURL*)URL {
    NSDictionary* link = SPDFMacAIDocumentLinkArguments(URL);
    NSString* identifier = link[@"path"];
    // Collection IDs and file names keep their own lookup, which says when nothing is found.
    if (![identifier hasPrefix:@"doc:"]) return YES;
    NSDictionary* index = objc_getAssociatedObject(self, &indexKey);
    NSDate* built = objc_getAssociatedObject(self, &indexDateKey);
    if (!index || -built.timeIntervalSinceNow > 3) [self aiRefreshDocumentIndex];
    if (!index || index[identifier]) return YES;
    for (NSString* path in [self aiOpenDocumentPathSet]) if ([Identify(path) isEqual:identifier]) return YES;
    return NO;
}

- (void)aiSourceThumbnailForLink:(NSURL*)URL page:(NSInteger)page completion:(void (^)(NSImage*))completion {
    NSString* identifier = SPDFMacAIDocumentLinkArguments(URL)[@"path"];
    if (![identifier hasPrefix:@"doc:"]) { completion(nil); return; }
    NSCache* cache = objc_getAssociatedObject(self, &thumbnailsKey);
    if (!cache) {
        cache = [NSCache new]; cache.countLimit = 40;
        objc_setAssociatedObject(self, &thumbnailsKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSString* key = [NSString stringWithFormat:@"%@#%ld", identifier, (long)page];
    NSImage* cached = [cache objectForKey:key];
    if (cached) { completion(cached); return; }
    [self aiBuildDocumentIndex:^(NSDictionary* index) {
      NSDictionary* target = index[identifier], *row = target[@"collection"];
      NSString* path = target[@"path"] ?: (SPDFCollectionOriginalAvailable(row) ? row[@"path"]
                                                                              : [row[@"editablePaths"] firstObject]);
      if (!path.length) { completion(nil); return; }
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURL* file = [NSURL fileURLWithPath:path];
        NSString* extension = path.pathExtension.lowercaseString;
        NSImage* image = [extension isEqual:@"pdf"]
            ? SPDFCollectionPDFThumbnail(file, MAX(1, page), NSMakeSize(260, 300), nil, NULL)
            : [@[ @"png", @"jpg", @"jpeg", @"heic", @"tif", @"tiff", @"gif", @"webp" ] containsObject:extension]
            ? SPDFCollectionImageThumbnail(file, 1, 300) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (image) [cache setObject:image forKey:key];
          completion(image);
        });
      });
    }];
}

@end
