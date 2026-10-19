#import <Cocoa/Cocoa.h>

#import "SPDFMacSelectionClick.h"

#include "shenzhen_pdf_core.h"

typedef NS_ENUM(NSInteger, SPDFMacSelectionStatus) {
    SPDFMacSelectionStatusError = -1,
    SPDFMacSelectionStatusNone = 0,
    SPDFMacSelectionStatusSelected = 1,
};

@interface SPDFMacSelectionResult : NSObject
@property(nonatomic, readonly) SPDFMacSelectionStatus status;
@property(nonatomic, copy, readonly) NSString* text;
@property(nonatomic, copy, readonly) NSArray<NSValue*>* rects;
@property(nonatomic, copy, readonly) NSString* errorMessage;
@property(nonatomic, readonly) unsigned flags;
@property(nonatomic, readonly) BOOL hasSelection;
@end

// Owns the complete core call boundary: granularity mapping, dynamic result
// lifetime, UTF-8 conversion, and page-rectangle conversion.
SPDFMacSelectionResult* spdf_mac_select_text(spdf_document* document, NSInteger pageIndex,
                                             SPDFMacSelectionGranularity granularity, NSPoint start, NSPoint end);
