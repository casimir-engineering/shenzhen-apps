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
NS_ASSUME_NONNULL_END
