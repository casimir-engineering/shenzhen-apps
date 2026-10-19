#pragma once
#import "SPDFMacCollectionStore.h"
static inline BOOL SPDFCollectionImportURLMatchesSource(NSURL* URL, NSString* source) {
    return URL.isFileURL && [URL.path.stringByStandardizingPath isEqual:source.stringByStandardizingPath];
}
// A recovery decision runs on main. The importer owns destination and deletes
// it after capture. Return a bound raw-copy hint after grant, nil after Skip.
// skipRemaining suppresses further permission sheets, not readable imports.
typedef void (^SPDFCollectionImportReply)(NSDictionary* copy, BOOL skipRemaining, NSError* error);
typedef void (^SPDFCollectionImportRecovery)(NSString* source, NSURL* destination,
                                           SPDFCollectionImportReply reply);
@interface SPDFMacCollectionStore (InitialImport)
- (void)importRecentPaths:(NSArray<NSString*>*)paths recovery:(SPDFCollectionImportRecovery)recovery
              completion:(void (^)(NSError* error))completion;
@end
