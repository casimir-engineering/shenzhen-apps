#pragma once
#import "SPDFMacModels.h"
// A path alone never identifies a recoverable placeholder: another document may
// now occupy it. Existing recovered tabs win so Locator Preview cannot duplicate them.
static inline SPDFDocumentTab* SPDFCollectionMissingTab(NSArray<SPDFDocumentTab*>* tabs,
    NSString* identifier, NSString* previousPath) {
    for (SPDFDocumentTab* tab in tabs)
        if ([tab.collectionHistoryDocumentID isEqual:identifier] &&
            ((tab.missingFile && [tab.path isEqual:previousPath]) || [tab.path.pathComponents containsObject:@"editable"])) return tab;
    return nil;
}
static inline SPDFDocumentTab* SPDFCollectionExistingRestoredTab(NSArray<SPDFDocumentTab*>* tabs, NSString* path) {
    for (SPDFDocumentTab* tab in tabs) if ([tab.path isEqual:path] && !tab.missingFile) return tab;
    return nil;
}
static inline void SPDFCollectionRestoreReadingPosition(SPDFDocumentTab* source, SPDFDocumentTab* target) {
    target.pageIndex = source.pageIndex; target.zoom = source.zoom; target.customZoom = source.customZoom;
    target.fitMode = source.fitMode; target.scrollOrigin = source.scrollOrigin; target.hasScrollOrigin = source.hasScrollOrigin;
}
