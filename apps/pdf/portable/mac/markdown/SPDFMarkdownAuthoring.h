#pragma once
#import "SPDFMarkdownPaginator.h"

NS_ASSUME_NONNULL_BEGIN
// Flat front-matter keys: paper-size (A3/A4/A5/Letter/Legal),
// paper-orientation (portrait/landscape), paper-margin and
// paper-margin-top/right/bottom/left (nonnegative points).
// No recognized keys returns fallback by identity: no configuration allocation.
// Invalid author values return nil with an actionable error; never silently clip.
FOUNDATION_EXPORT SPDFMarkdownPageConfiguration* _Nullable SPDFMarkdownPageConfigurationForFrontMatter(
    NSDictionary<NSString*, NSString*>* frontMatter, SPDFMarkdownPageConfiguration* fallback,
    NSError* _Nullable* _Nullable error);
FOUNDATION_EXPORT BOOL SPDFMarkdownHasAuthorPageConfiguration(NSDictionary<NSString*, NSString*>* frontMatter);
FOUNDATION_EXPORT SPDFMarkdownPageConfiguration* SPDFMarkdownPageConfigurationByOrienting(
    SPDFMarkdownPageConfiguration* configuration, SPDFMarkdownPageOrientation orientation);

// Explicit, on-demand inspection. JSON-safe dictionary; canonical UTF-16 ranges
// refer ONLY to rendered.attributedString. Coordinates are points, y down from
// the printable area's top. Pages are one-based. Source offsets are unavailable.
// Per-page fractions count visible canonical UTF-16 units, excluding structural
// separators that produce no fragments. No analysis runs until this is called.
FOUNDATION_EXPORT NSDictionary* SPDFMarkdownLayoutReport(SPDFMarkdownDocumentModel* model,
    SPDFMarkdownRenderedDocument* rendered, SPDFMarkdownPaginationPlan* plan);
NS_ASSUME_NONNULL_END
