#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Explicit, read-only agent inspection through the same MuPDF core as the reader.
// At most 100 pages per request; page selects one page. Text ranges are UTF-16
// offsets into each page's canonicalText, geometry is page-top-left points.
FOUNDATION_EXPORT NSDictionary* _Nullable SPDFMacAgentInspectPDF(NSDictionary* command,
    NSError* _Nullable* _Nullable error);
NS_ASSUME_NONNULL_END
