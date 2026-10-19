#pragma once
#import "SPDFMacModels.h"
// Archive labels are persisted and copied with tabs; Save As clears them. This
// provenance stays available during drawing and drag/drop without opening a store.
static inline BOOL SPDFTabIsCollectionCopy(SPDFDocumentTab* tab) {
    return tab.collectionVersionLabel.length > 0;
}
