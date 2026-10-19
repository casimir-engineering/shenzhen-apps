#pragma once
#import <Foundation/Foundation.h>
@class SPDFMacCollectionStore;

NS_ASSUME_NONNULL_BEGIN
// Explicit worker-only lookup. Resolves the current linked original by stable
// document ID; when unavailable, materializes its latest protected revision.
// Result keys: URL, label, document, archived, and version for an archive.
NSDictionary* _Nullable SPDFCollectionResolveLatestComparison(SPDFMacCollectionStore* store,
                                                              NSString* documentID, NSError** error);
NS_ASSUME_NONNULL_END
