#pragma once
#import <AppKit/AppKit.h>
#import <PDFKit/PDFKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface SPDFCollectionPagePair : NSObject
@property(nonatomic) NSInteger oldIndex; // -1 is an inserted/deleted counterpart.
@property(nonatomic) NSInteger newIndex;
@property(nonatomic, copy) NSArray<NSValue*>* removedRects;
@property(nonatomic, copy) NSArray<NSValue*>* addedRects;
@end
@interface SPDFCollectionComparison : NSObject
@property(nonatomic, strong) PDFDocument* oldDocument;
@property(nonatomic, strong) PDFDocument* updatedDocument;
@property(nonatomic, copy) NSArray<SPDFCollectionPagePair*>* pairs;
@end
// Pure bounded alignment: each entry is @[oldIndex, newIndex], -1 for a gap.
NSArray<NSArray<NSNumber*>*>* SPDFCollectionAlignPages(NSArray<NSString*>* oldKeys,
                                                     NSArray<NSString*>* newKeys);
// No queues, files, or services are created until explicitly requested.
PDFDocument* _Nullable SPDFCollectionLoadPreviewDocument(NSURL* URL, NSProgress* progress, NSError** error);
SPDFCollectionComparison* _Nullable SPDFCollectionBuildComparison(NSURL* oldURL, NSURL* newURL,
                                                                NSProgress* progress, NSError** error);
void SPDFMacShowCollectionComparison(NSURL* oldURL, NSURL* newURL, NSString* oldLabel,
                                    NSString* newLabel, NSWindow* _Nullable parent);
// While YES, a comparison window opens without coming forward: just above `parent` when it shows (so it stays behind
// whatever is in front of the reader), else behind every window; it is never made key. `szpdf version compare` sets
// it around its call; every other comparison opens in front as before.
void SPDFMacComparisonSetOpensInBackground(BOOL background);
// Posted on the main queue when a comparison window has laid out both documents (or failed to): object the window,
// userInfo @{"changes": count} or @{"error": message}.
FOUNDATION_EXPORT NSNotificationName const SPDFMacComparisonDidFinishLoadingNotification;
// The same window for two different documents (Compare to Current Document in the tab menu): neither is older, so
// it says "Document Comparison" and each pane's marks are named for the other document instead of OLD / NEW.
void SPDFMacShowDocumentComparison(NSURL* oldURL, NSURL* newURL, NSString* oldLabel, NSString* newLabel,
                                   NSWindow* _Nullable parent);
NS_ASSUME_NONNULL_END
