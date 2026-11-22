// Keyboard focus in Fill & Sign: Space and Return on the focused field or drawn box, and Tab through the PDF's fields
// (or, on a page without fields, its lines and boxes) in reading order. Moved out of +Interaction.mm.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillEditor.h"
#import "SPDFMacFillOverlayView.h"

#include <vector>

// Rows whose centres are within 4 pt, then left to right, as spdf_snap_targets_in_order sorts them.
static BOOL SPDFFillReadsBefore(NSRect a, NSRect b) {
    return NSMidY(a) < NSMidY(b) - 4 || (fabs(NSMidY(a) - NSMidY(b)) <= 4 && NSMinX(a) < NSMinX(b));
}

@implementation SPDFMacFillController (Focus)

- (BOOL)isFieldFocused:(SPDFFillField*)field {
    SPDFFillField* focused = self.editor.field ?: self.overlay.focusedField;
    return focused && focused.page == field.page && focused.objectNumber == field.objectNumber;
}

- (void)toggleFocusedField {
    SPDFFillField* field = self.overlay.focusedField;
    if (field) {
        for (SPDFFillField* f in [self fieldsOnPage:field.page])
            if (f.objectNumber == field.objectNumber) field = f;
        if (!field.readOnly) [self activateField:field];
        return;
    }
    NSRect target = self.overlay.focusedTargetRect;
    NSInteger page = self.overlay.focusedTargetPage;
    if (NSIsEmptyRect(target)) return;
    for (SPDFFillItem* item in [self itemsOnPage:page])
        if (item.isMark && NSIntersectsRect(NSInsetRect(item.rect, 1, 1), target)) {
            [self deleteItem:item];
            return;
        }
    spdf_snap_result snap;
    [self.overlay resolveAt:NSMakePoint(NSMidX(target), NSMidY(target)) page:page purpose:SPDF_SNAP_FOR_MARK aspect:1
                   snapping:YES result:&snap];
    [self addMarkOnPage:page box:SPDFFillRectFromCore(snap.place) cross:[self session].markCross];
}

// Fields in reading order on one page: rows (centres within 4 pt), then left to right.
- (NSArray<SPDFFillField*>*)orderedFieldsOnPage:(NSInteger)page {
    NSMutableArray* fields = [NSMutableArray array];
    for (SPDFFillField* field in [self fieldsOnPage:page])
        if (!field.hidden && !field.readOnly) [fields addObject:field];
    [fields sortUsingComparator:^NSComparisonResult(SPDFFillField* a, SPDFFillField* b) {
      if (fabs(NSMidY(a.rect) - NSMidY(b.rect)) > 4) return NSMidY(a.rect) < NSMidY(b.rect) ? NSOrderedAscending : NSOrderedDescending;
      return NSMinX(a.rect) < NSMinX(b.rect) ? NSOrderedAscending : NSMinX(a.rect) > NSMinX(b.rect) ? NSOrderedDescending : NSOrderedSame;
    }];
    return fields;
}

- (void)moveFocusForward:(BOOL)forward {
    NSInteger pages = [self pageCount];
    if (pages <= 0) return;
    SPDFFillField* from = self.overlay.focusedField;
    NSInteger page = from ? from.page : [self.overlay.visiblePages.firstObject integerValue];
    if (!from && !NSIsEmptyRect(self.overlay.focusedTargetRect)) page = self.overlay.focusedTargetPage;
    if ([self session].isForm) {
        for (NSInteger step = 0; step <= pages; ++step) {
            NSInteger p = (page + (forward ? step : -step) + pages * 2) % pages;
            NSArray<SPDFFillField*>* fields = [self orderedFieldsOnPage:p];
            if (!fields.count) continue;
            NSInteger index = forward ? -1 : (NSInteger)fields.count;
            if (step == 0 && from)
                for (NSUInteger i = 0; i < fields.count; ++i)
                    if (fields[i].objectNumber == from.objectNumber) index = (NSInteger)i;
            NSInteger next = index + (forward ? 1 : -1);
            if (next < 0 || next >= (NSInteger)fields.count) continue;
            SPDFFillField* target = fields[(NSUInteger)next];
            self.overlay.focusedField = target;
            [self.overlay revealPageRect:target.rect page:target.page];
            if (target.type == SPDF_FIELD_TEXT) [self openEditorForField:target];
            self.overlay.needsDisplay = YES;
            return;
        }
        return;
    }
    [self moveFlatFocusForward:forward page:page];
}

// A page without fields: its drawn boxes, small squares and lines, as the snap pass found them.
- (void)moveFlatFocusForward:(BOOL)forward page:(NSInteger)page {
    const spdf_snap_geometry* geometry = [self geometryForPage:page];
    if (!geometry) return;  // still reading the page; the next Tab finds it
    int count = spdf_snap_targets_in_order(geometry, NULL, 0);
    if (count <= 0) return;
    std::vector<spdf_snap_target> targets((size_t)count);
    spdf_snap_targets_in_order(geometry, targets.data(), count);
    NSRect current = !NSIsEmptyRect(self.overlay.focusedTargetRect) ? self.overlay.focusedTargetRect : NSZeroRect;
    int index = forward ? -1 : count;
    for (int i = 0; i < count && !NSIsEmptyRect(current); ++i)
        if (NSIntersectsRect(NSInsetRect(SPDFFillRectFromCore(targets[(size_t)i].rect), 1, 1), current)) index = i;
    // From text on none of them (a table cell): on from where it is, in reading order.
    if (!NSIsEmptyRect(current) && index == (forward ? -1 : count)) {
        int firstAfter = count, lastBefore = -1;
        for (int i = 0; i < count; ++i) {
            NSRect r = SPDFFillRectFromCore(targets[(size_t)i].rect);
            if (firstAfter == count && SPDFFillReadsBefore(current, r)) firstAfter = i;
            if (SPDFFillReadsBefore(r, current)) lastBefore = i;
        }
        index = forward ? firstAfter - 1 : lastBefore + 1;
    }
    int next = index + (forward ? 1 : -1);
    if (next < 0 || next >= count) return;
    const spdf_snap_target& target = targets[(size_t)next];
    self.overlay.focusedField = nil;
    self.overlay.focusedTargetRect = SPDFFillRectFromCore(target.rect);
    self.overlay.focusedTargetPage = page;
    [self.overlay revealPageRect:self.overlay.focusedTargetRect page:page];
    if (target.kind != SPDF_SNAP_CHECKBOX) {
        // Text already there opens to be changed; nothing is stacked on it.
        for (SPDFFillItem* item in [self itemsOnPage:page])
            if (item.text && NSIntersectsRect(NSInsetRect(item.rect, 1, 1), self.overlay.focusedTargetRect)) {
                [self openEditorForItem:item];
                self.overlay.needsDisplay = YES;
                return;
            }
        spdf_snap_result snap;
        [self.overlay resolveAt:NSMakePoint(target.probe_x, target.probe_y) page:page purpose:SPDF_SNAP_FOR_TEXT aspect:1
                       snapping:YES result:&snap];
        [self openEditorForNewTextOnPage:page snap:&snap];
    }
    self.overlay.needsDisplay = YES;
}

@end
