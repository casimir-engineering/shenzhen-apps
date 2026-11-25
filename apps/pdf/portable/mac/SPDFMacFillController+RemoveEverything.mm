// Edit ▸ Remove Everything Added with Fill & Sign: the text, marks, signatures, pen lines and arrows Fill & Sign put on
// the pages go, and every field of the PDF's own form it filled in gets back the value it had before (the one the PDF
// came with, kept in the file by spdf_form_set_*; see spdf_form.h), and everything Annotate wrote on the pages goes too
// (spdf_paint_pdf_remove_all_ex keeps it, so undo puts it back). All of it is one change and one undo step.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillOverlayView.h"

#include "spdf_fill_ink.h"
#include "spdf_form.h"
#include "spdf_paint.h"

#include <vector>

typedef BOOL (^SPDFFillEverythingWrite)(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t errLen);

// SPDFMacFillController+Drawing.mm. Entries are SPDFFillEntry objects: an item, a whole comb entry or a signature.
NSArray<SPDFFillItem*>* SPDFFillDrawingsIn(NSArray* entriesOrItems);
@interface SPDFMacFillController (DrawingShared)
- (NSArray*)entriesForItems:(NSArray<SPDFFillItem*>*)items;
- (BOOL)applyRemoving:(NSArray*)removed adding:(NSArray*)added fields:(SPDFFillEverythingWrite)fields;
- (NSArray<SPDFFillItem*>*)itemsOnPagesWithPrefix:(const char*)prefix drawingsOnly:(BOOL)drawingsOnly;
@end

// What Annotate's removal took off the pages, kept for the undo (freed with the undo step).
@interface SPDFAnnotateRemovedItems : NSObject
@property(nonatomic) spdf_paint_pdf_removed* removed;
@end
@implementation SPDFAnnotateRemovedItems
- (void)dealloc {
    spdf_paint_pdf_free_removed(_removed);
}
@end

static void SPDFFillAddPages(NSMutableIndexSet* pages, const int* changed, int count, NSInteger max) {
    for (int i = 0; i < MIN(count, (int)max); ++i) [pages addIndex:(NSUInteger)changed[(size_t)i]];
}

@implementation SPDFMacFillController (RemoveEverything)

- (void)removeEverythingAdded {
    [self flushPendingChanges];
    SPDFFillSession* session = [self session];
    spdf_document* doc = [self.host fillDocument];
    char err[256];
    BOOL fields = doc && spdf_form_filled_count(doc, err, sizeof(err)) > 0;
    BOOL placing = !session.hasSummary || session.summary.can_add_items;
    BOOL annotated = placing && doc && spdf_fill_pages_with_items(doc, SPDF_PAINT_NM_PREFIX, NULL, 0, err, sizeof(err)) > 0;
    NSArray<SPDFFillItem*>* items = placing ? [self itemsOnPagesWithPrefix:SPDF_FILL_NM_PREFIX drawingsOnly:NO] : @[];
    if ((!items.count && !fields && !annotated) ||
        ![self clearEntries:[self entriesForItems:items] fields:fields annotated:annotated])
        NSBeep();
    else if (items.count) [self selectItems:@[] page:items.firstObject.page];
    self.overlay.selectedItem = nil;
}

- (BOOL)clearEntries:(NSArray*)entries fields:(BOOL)fields annotated:(BOOL)annotated {
    __block NSString* snapshot = nil;
    SPDFAnnotateRemovedItems* removed = annotated ? [SPDFAnnotateRemovedItems new] : nil;
    NSInteger pageCount = MAX([self pageCount], (NSInteger)1);
    SPDFFillEverythingWrite reset = nil;
    if (fields || annotated)
        reset = ^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
          std::vector<int> changed((size_t)pageCount);
          int count = 0;
          if (fields) {
              char* undo = NULL;
              count = spdf_form_reset_filled(doc, &undo, changed.data(), (int)changed.size(), err, len);
              snapshot = undo ? @(undo) : nil;
              free(undo);
              SPDFFillAddPages(pages, changed.data(), count, pageCount);
          }
          if (count >= 0 && removed) {
              spdf_paint_pdf_removed* kept = NULL;
              if (spdf_paint_pdf_remove_all_ex(doc, &kept, changed.data(), (int)changed.size(), &count, err, len) !=
                  SPDF_PAINT_OK)
                  return NO;
              removed.removed = kept;
              SPDFFillAddPages(pages, changed.data(), count, pageCount);
          }
          return count >= 0;
        };
    [self.overlay holdInk:@[] washes:SPDFFillDrawingsIn(entries)];
    if (![self applyRemoving:entries adding:@[] fields:reset]) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target restoreEntries:entries fields:snapshot annotated:removed];
    }];
    return YES;
}

- (BOOL)restoreEntries:(NSArray*)entries fields:(NSString*)snapshot annotated:(SPDFAnnotateRemovedItems*)removed {
    NSInteger pageCount = MAX([self pageCount], (NSInteger)1);
    SPDFFillEverythingWrite restore = nil;
    if (snapshot || removed.removed)
        restore = ^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
          std::vector<int> changed((size_t)pageCount);
          int count = 0;
          if (snapshot) {
              count = spdf_form_restore_filled(doc, snapshot.UTF8String, changed.data(), (int)changed.size(), err, len);
              SPDFFillAddPages(pages, changed.data(), count, pageCount);
          }
          if (count >= 0 && removed.removed) {
              if (spdf_paint_pdf_restore_removed(doc, removed.removed, changed.data(), (int)changed.size(), &count, err,
                                                 len) != SPDF_PAINT_OK)
                  return NO;
              SPDFFillAddPages(pages, changed.data(), count, pageCount);
          }
          return count >= 0;
        };
    [self.overlay holdInk:SPDFFillDrawingsIn(entries) washes:nil];
    if (![self applyRemoving:@[] adding:entries fields:restore]) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target clearEntries:entries fields:snapshot != nil annotated:removed.removed != NULL];
    }];
    return YES;
}

@end
