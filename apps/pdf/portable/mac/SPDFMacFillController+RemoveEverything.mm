// Edit ▸ Remove Everything Added with Fill & Sign: the text, marks, signatures, pen lines and arrows Fill & Sign put on
// the pages go, and every field of the PDF's own form it filled in gets back the value it had before (the one the PDF
// came with, kept in the file by spdf_form_set_*; see spdf_form.h). All of it is one change and one undo step.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillOverlayView.h"

#include "spdf_form.h"

#include <vector>

typedef BOOL (^SPDFFillEverythingWrite)(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t errLen);

// SPDFMacFillController+Drawing.mm. Entries are SPDFFillEntry objects: an item, a whole comb entry or a signature.
NSArray<SPDFFillItem*>* SPDFFillDrawingsIn(NSArray* entriesOrItems);
@interface SPDFMacFillController (DrawingShared)
- (NSArray*)entriesForItems:(NSArray<SPDFFillItem*>*)items;
- (BOOL)applyRemoving:(NSArray*)removed adding:(NSArray*)added fields:(SPDFFillEverythingWrite)fields;
- (NSArray<SPDFFillItem*>*)itemsOnPagesWithPrefix:(const char*)prefix drawingsOnly:(BOOL)drawingsOnly;
@end

@implementation SPDFMacFillController (RemoveEverything)

- (void)removeEverythingAdded {
    [self flushPendingChanges];
    SPDFFillSession* session = [self session];
    spdf_document* doc = [self.host fillDocument];
    char err[256];
    BOOL fields = doc && spdf_form_filled_count(doc, err, sizeof(err)) > 0;
    BOOL placing = !session.hasSummary || session.summary.can_add_items;
    NSArray<SPDFFillItem*>* items = placing ? [self itemsOnPagesWithPrefix:SPDF_FILL_NM_PREFIX drawingsOnly:NO] : @[];
    if ((!items.count && !fields) || ![self clearEntries:[self entriesForItems:items] fields:fields]) NSBeep();
    else if (items.count) [self selectItems:@[] page:items.firstObject.page];
    self.overlay.selectedItem = nil;
}

- (BOOL)clearEntries:(NSArray*)entries fields:(BOOL)fields {
    __block NSString* snapshot = nil;
    NSInteger pageCount = MAX([self pageCount], (NSInteger)1);
    SPDFFillEverythingWrite reset = nil;
    if (fields)
        reset = ^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
          std::vector<int> changed((size_t)pageCount);
          char* undo = NULL;
          int count = spdf_form_reset_filled(doc, &undo, changed.data(), (int)changed.size(), err, len);
          snapshot = undo ? @(undo) : nil;
          free(undo);
          for (int i = 0; i < MIN(count, (int)pageCount); ++i) [pages addIndex:(NSUInteger)changed[(size_t)i]];
          return count >= 0;
        };
    [self.overlay holdInk:@[] washes:SPDFFillDrawingsIn(entries)];
    if (![self applyRemoving:entries adding:@[] fields:reset]) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target restoreEntries:entries fields:snapshot];
    }];
    return YES;
}

- (BOOL)restoreEntries:(NSArray*)entries fields:(NSString*)snapshot {
    NSInteger pageCount = MAX([self pageCount], (NSInteger)1);
    SPDFFillEverythingWrite restore = nil;
    if (snapshot)
        restore = ^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
          std::vector<int> changed((size_t)pageCount);
          int count = spdf_form_restore_filled(doc, snapshot.UTF8String, changed.data(), (int)changed.size(), err, len);
          for (int i = 0; i < MIN(count, (int)pageCount); ++i) [pages addIndex:(NSUInteger)changed[(size_t)i]];
          return count >= 0;
        };
    [self.overlay holdInk:SPDFFillDrawingsIn(entries) washes:nil];
    if (![self applyRemoving:@[] adding:entries fields:restore]) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target clearEntries:entries fields:snapshot != nil];
    }];
    return YES;
}

@end
