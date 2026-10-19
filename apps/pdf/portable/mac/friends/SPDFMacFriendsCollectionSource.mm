#import "SPDFMacFriendsCollectionSource.h"
#import "SPDFMacCollectionStore.h"

@implementation SPDFMacFriendsCollectionSource {
    SPDFMacCollectionStore* _store;
}

- (instancetype)initWithStore:(SPDFMacCollectionStore*)store {
    if (!(self = [super init])) return nil;
    _store = store;
    return self;
}

- (BOOL)friendsCollectionEnabled { return [_store isEnabled]; }
- (NSDictionary*)friendsArchiveInfoForPath:(NSString*)path { return [_store archiveInfoForPath:path]; }
- (NSDictionary*)friendsDocumentForPath:(NSString*)path { return [_store documentForPath:path]; }
- (NSArray<NSDictionary*>*)friendsVersionsForDocumentID:(NSString*)documentID {
    return [_store versionsForDocumentID:documentID] ?: @[];
}
- (NSArray<NSDictionary*>*)friendsDocuments { return [_store documents] ?: @[]; }

// Materializing writes an archive preview inside Collection, as opening a history version does; the copy is
// immutable, so a chip bound to it keeps sending exactly that version.
- (NSURL*)friendsFileForVersionID:(NSString*)versionID documentID:(NSString*)documentID {
    return [_store materializeVersionID:versionID documentID:documentID error:nil];
}

@end
