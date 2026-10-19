#pragma once
#import "SPDFMacCollectionStore.h"
NS_ASSUME_NONNULL_BEGIN
@interface SPDFMacCollectionStore (ContextSearch)
// Explicit manager search only; empty queries do not read the manifest/indexes.
// Groups: {document, versions:[{version, latest, titleMatch, textAvailable,
//   matchCount, truncated, matches:[{page, query, snippet, ranges, pageRanges,
//   snippetRange, canonicalRanges?}]}]}. Versions are newest first.
// matchCount counts occurrences in retained indexed text (not title matches).
// At most 32 contexts/version; truncated means some occurrences are omitted.
// ranges/pageRanges/canonicalRanges contain NSValue UTF-16 NSRanges relative to
// snippet/indexed page/Markdown canonical string respectively. snippetRange is
// the indexed page slice, excluding the displayed leading/trailing ellipses.
// Page 0 means the index has no rendered page mapping. Title-only matches have
// matches=[]; missing/encrypted indexes are never parsed or invented as hits.
- (NSArray<NSDictionary*>*)searchGroups:(NSString*)query allVersions:(BOOL)allVersions;
@end
NS_ASSUME_NONNULL_END
