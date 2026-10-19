#import "SPDFMacSelectionAdapter.h"

@interface SPDFMacSelectionResult ()
@property(nonatomic) SPDFMacSelectionStatus status;
@property(nonatomic, copy) NSString* text;
@property(nonatomic, copy) NSArray<NSValue*>* rects;
@property(nonatomic, copy) NSString* errorMessage;
@property(nonatomic) unsigned flags;
@end

@implementation SPDFMacSelectionResult
- (BOOL)hasSelection {
    return self.status == SPDFMacSelectionStatusSelected && self.text.length > 0 && self.rects.count > 0;
}
@end

static spdf_selection_granularity spdf_core_selection_granularity(SPDFMacSelectionGranularity granularity) {
    if (granularity == SPDFMacSelectionGranularityWord) return SPDF_SELECTION_WORD;
    if (granularity == SPDFMacSelectionGranularityBlock) return SPDF_SELECTION_BLOCK;
    return SPDF_SELECTION_RANGE;
}

SPDFMacSelectionResult* spdf_mac_select_text(spdf_document* document, NSInteger pageIndex,
                                             SPDFMacSelectionGranularity granularity, NSPoint start, NSPoint end) {
    char error[1024] = {};
    spdf_text_selection coreSelection = {};
    spdf_selection_status coreStatus =
        spdf_select_text(document, (int)pageIndex, spdf_core_selection_granularity(granularity), (float)start.x,
                         (float)start.y, (float)end.x, (float)end.y, &coreSelection, error, sizeof(error));

    SPDFMacSelectionResult* result = [SPDFMacSelectionResult new];
    result.flags = coreSelection.flags;
    result.errorMessage = error[0] ? [NSString stringWithUTF8String:error] : @"";
    if (coreStatus == SPDF_SELECTION_OK) {
        result.text = coreSelection.text ? [NSString stringWithUTF8String:coreSelection.text] : @"";
        NSMutableArray<NSValue*>* rects = [NSMutableArray arrayWithCapacity:(NSUInteger)coreSelection.rect_count];
        for (int i = 0; i < coreSelection.rect_count; ++i) {
            spdf_rect rect = coreSelection.rects[i];
            [rects addObject:[NSValue valueWithRect:NSMakeRect(rect.x0, rect.y0, rect.x1 - rect.x0,
                                                               rect.y1 - rect.y0)]];
        }
        result.rects = rects;
        result.status = result.text && rects.count > 0 ? SPDFMacSelectionStatusSelected : SPDFMacSelectionStatusError;
    } else {
        result.status = coreStatus == SPDF_SELECTION_NONE ? SPDFMacSelectionStatusNone : SPDFMacSelectionStatusError;
        result.text = @"";
        result.rects = @[];
    }
    spdf_free_text_selection(&coreSelection);
    return result;
}
