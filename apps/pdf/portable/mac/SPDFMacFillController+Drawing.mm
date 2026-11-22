// Pen lines, arrows, the eraser and the Select tool: the changes they make, each one a step of the tab's undo, and the
// short wait that writes lines drawn in quick succession together (docs/plans/fill-and-sign.md, "Pen and arrow").
//
// Every change goes through -change:write: like the rest of Fill & Sign (check, write into the main-thread document,
// save, redraw the changed pages in the same turn). Before it, the overlay is told which lines to keep drawing and
// which to cover until a page image made after the write is on screen, so no frame shows a line vanish or come back.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillDrawingStyle.h"
#import "SPDFMacFillEditor.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacSignatureStore.h"

#include "spdf_fill_ink.h"

#import <objc/runtime.h>

#include <vector>

typedef BOOL (^SPDFFillDrawingWrite)(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t errLen);

// SPDFMacFillController+Edits.mm.
@interface SPDFMacFillController (EditsShared)
- (BOOL)change:(BOOL)fieldsOnly write:(SPDFFillDrawingWrite)write;
- (BOOL)writeItem:(SPDFFillItem*)spec cells:(NSArray<NSValue*>*)cells signature:(SPDFMacSignature*)signature
              doc:(spdf_document*)doc err:(char*)err length:(size_t)len;
- (NSArray<NSValue*>*)combCellsOf:(SPDFFillItem*)item text:(NSString**)textOut;
- (SPDFMacSignature*)signatureForItem:(SPDFFillItem*)item;
@end

// One thing taken off a page or put back: an item, a whole comb entry (its cells), or a signature with its drawing.
@interface SPDFFillEntry : NSObject
@property(nonatomic, strong) SPDFFillItem* item;
@property(nonatomic, copy) NSArray<NSValue*>* cells;
@property(nonatomic, strong) SPDFMacSignature* signature;
@end
@implementation SPDFFillEntry
@end

// Lines drawn but not written yet, and the wait before they are.
@interface SPDFFillPendingStrokes : NSObject
@property(nonatomic, strong) NSMutableArray<SPDFFillItem*>* strokes;
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic, strong) id resignObserver;
@end
@implementation SPDFFillPendingStrokes
@end

static char kSPDFFillPendingKey;
static const NSTimeInterval kSPDFFillPendingRest = 0.35;

static NSArray<SPDFFillItem*>* SPDFFillDrawingsIn(NSArray* entriesOrItems) {
    NSMutableArray* drawings = [NSMutableArray array];
    for (id object in entriesOrItems) {
        SPDFFillItem* item = [object isKindOfClass:SPDFFillEntry.class] ? [(SPDFFillEntry*)object item] : object;
        if (item.isDrawing) [drawings addObject:item];
    }
    return drawings;
}

@implementation SPDFMacFillController (Drawing)

#pragma mark - Tools

- (void)chooseTool:(SPDFFillTool)tool {
    SPDFFillSession* session = [self session];
    if (!session) return;
    BOOL placing = !session.hasSummary || session.summary.can_add_items;
    if (tool != SPDFFillToolText && !placing) {
        NSBeep();
        return;
    }
    SPDFMacFillDrawingStyle* style = [SPDFMacFillDrawingStyle sharedStyle];  // the remembered choice, read on first use
    if (tool == SPDFFillToolEraser && session.tool == SPDFFillToolEraser) style.eraserParts = !style.eraserParts;
    [self endInteraction];  // writes what is pending and closes the text box
    if (tool != SPDFFillToolSelect) session.selection = @[];
    session.tool = tool;
    [self refreshChrome];
}

#pragma mark - Lines waiting to be written

- (SPDFFillPendingStrokes*)existingPending {
    return objc_getAssociatedObject(self, &kSPDFFillPendingKey);
}

- (SPDFFillPendingStrokes*)pending {
    SPDFFillPendingStrokes* pending = [self existingPending];
    if (pending) return pending;
    pending = [SPDFFillPendingStrokes new];
    pending.strokes = [NSMutableArray array];
    __weak SPDFMacFillController* weakSelf = self;
    // Another window or app taking the keys is a way of leaving the page: what was drawn is written first.
    pending.resignObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidResignKeyNotification
                    object:[self.host fillWindow]
                     queue:nil
                usingBlock:^(NSNotification* note) {
                  (void)note;
                  [weakSelf writePendingStrokes];
                }];
    objc_setAssociatedObject(self, &kSPDFFillPendingKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return pending;
}

- (void)addDrawnStrokes:(NSArray<SPDFFillItem*>*)strokes {
    if (!strokes.count) return;
    [[self pending].strokes addObjectsFromArray:strokes];
    [self postponePendingStrokes];
    self.overlay.needsDisplay = YES;
}

- (NSArray<SPDFFillItem*>*)pendingStrokesOnPage:(NSInteger)page {
    NSMutableArray* found = [NSMutableArray array];
    for (SPDFFillItem* stroke in [self existingPending].strokes)
        if (stroke.page == page) [found addObject:stroke];
    return found;
}

- (BOOL)hasPendingStrokes {
    return [self existingPending].strokes.count > 0;
}

- (void)postponePendingStrokes {
    SPDFFillPendingStrokes* pending = [self existingPending];
    if (!pending.strokes.count) return;
    [pending.timer invalidate];
    pending.timer = [NSTimer scheduledTimerWithTimeInterval:kSPDFFillPendingRest target:self
                                                   selector:@selector(pendingRestEnded:) userInfo:nil repeats:NO];
}

- (void)pendingRestEnded:(NSTimer*)timer {
    (void)timer;
    [self writePendingStrokes];
}

- (void)discardPendingStrokes {
    SPDFFillPendingStrokes* pending = [self existingPending];
    [pending.timer invalidate];
    pending.timer = nil;
    [pending.strokes removeAllObjects];
}

- (void)writePendingStrokes {
    SPDFFillPendingStrokes* pending = [self existingPending];
    if (!pending.strokes.count) return;
    [pending.timer invalidate];
    pending.timer = nil;
    if (self.busy) {  // another change is being written: these follow it
        [self postponePendingStrokes];
        return;
    }
    NSArray<SPDFFillItem*>* strokes = [pending.strokes copy];
    [pending.strokes removeAllObjects];
    NSArray<SPDFFillEntry*>* entries = [self entriesForItems:strokes];
    [self.overlay holdInk:strokes washes:nil];
    if (![self applyRemoving:@[] adding:entries]) {
        [self.overlay dropDrawingHolds];
        return;
    }
    // One undo step per line, even when several lines were written together.
    NSUndoManager* undo = [self session].undoManager;
    BOOL separate = undo.groupingLevel == 0, byEvent = undo.groupsByEvent;
    if (separate) undo.groupsByEvent = NO;
    for (SPDFFillEntry* entry in entries) {
        if (separate) [undo beginUndoGrouping];
        [self registerUndoRemoving:@[ entry ] adding:@[]];
        if (separate) [undo endUndoGrouping];
    }
    if (separate) undo.groupsByEvent = byEvent;
}

- (void)flushPendingChanges {
    [self flushEditor];
    [self writePendingStrokes];
}

#pragma mark - Selection

- (NSArray<SPDFFillItem*>*)selectedItems {
    SPDFFillSession* session = [self session];
    if (!session.selection.count) return @[];
    NSSet* names = [NSSet setWithArray:session.selection];
    NSMutableArray* found = [NSMutableArray array];
    for (SPDFFillItem* item in [self itemsOnPage:session.selectionPage])
        if ([names containsObject:item.nm]) [found addObject:item];
    return found;
}

- (void)selectItems:(NSArray<SPDFFillItem*>*)items page:(NSInteger)page {
    SPDFFillSession* session = [self session];
    NSMutableArray* names = [NSMutableArray array];
    for (SPDFFillItem* item in items)
        if (![names containsObject:item.nm]) [names addObject:item.nm];
    session.selection = names;
    session.selectionPage = page;
    self.overlay.needsDisplay = YES;
    [self.palette updateFromSession:session progress:[self progressText] note:[self paletteNote]];
}

- (BOOL)selectionHasDrawings {
    return SPDFFillDrawingsIn([self selectedItems]).count > 0;
}

- (NSInteger)selectionColorIndex {
    NSInteger shared = -1;
    for (SPDFFillItem* item in SPDFFillDrawingsIn([self selectedItems])) {
        NSInteger index = [SPDFMacFillDrawingStyle indexOfColor:item.color];
        if (index < 0 || (shared >= 0 && index != shared)) return -1;
        shared = index;
    }
    return shared;
}

- (NSInteger)selectionWidthIndex {
    NSInteger shared = -1;
    for (SPDFFillItem* item in SPDFFillDrawingsIn([self selectedItems])) {
        NSInteger index = [SPDFMacFillDrawingStyle indexOfWidth:item.lineWidth];
        if (index < 0 || (shared >= 0 && index != shared)) return -1;
        shared = index;
    }
    return shared;
}

#pragma mark - Removing and putting back

- (SPDFFillEntry*)entryForItem:(SPDFFillItem*)item {
    SPDFFillEntry* entry = [SPDFFillEntry new];
    entry.item = item;
    if (item.cell >= 0) {  // a comb entry goes and comes back whole, as Delete does
        NSString* text = nil;
        entry.cells = [self combCellsOf:item text:&text];
        SPDFFillItem* spec = [SPDFFillItem new];
        spec.kind = SPDF_FILL_TEXT;
        spec.page = item.page;
        spec.fontSize = item.fontSize;
        spec.text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length ? text : @"";
        spec.group = item.group;
        spec.nm = item.group;
        spec.cell = 0;
        entry.item = spec;
    }
    if (item.isSignature) entry.signature = [self signatureForItem:item];
    return entry;
}

- (NSArray<SPDFFillEntry*>*)entriesForItems:(NSArray<SPDFFillItem*>*)items {
    NSMutableArray* entries = [NSMutableArray array];
    NSMutableSet* seen = [NSMutableSet set];
    for (SPDFFillItem* item in items) {
        NSString* key = [NSString stringWithFormat:@"%ld|%@", (long)item.page, item.cell >= 0 ? item.group : item.nm];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [entries addObject:[self entryForItem:item]];
    }
    return entries;
}

// One change: removes `removed`, then writes `added`.
- (BOOL)applyRemoving:(NSArray<SPDFFillEntry*>*)removed adding:(NSArray<SPDFFillEntry*>*)added {
    for (SPDFFillEntry* entry in added)
        if (entry.signature) self.usedSignatures[entry.signature.identifier] = entry.signature;
    return [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      NSMutableDictionary<NSNumber*, NSMutableArray<NSString*>*>* names = [NSMutableDictionary dictionary];
      for (SPDFFillEntry* entry in removed) {
          NSNumber* page = @(entry.item.page);
          if (!names[page]) names[page] = [NSMutableArray array];
          [names[page] addObject:entry.cells.count ? entry.item.group : entry.item.nm];
      }
      for (NSNumber* page in names) {
          std::vector<const char*> list;
          for (NSString* name in names[page]) list.push_back(name.UTF8String);
          [pages addIndex:page.unsignedIntegerValue];
          if (!spdf_fill_delete_items(doc, page.intValue, list.data(), (int)list.size(), err, len)) return NO;
      }
      NSMutableDictionary<NSNumber*, NSMutableArray<SPDFFillItem*>*>* strokes = [NSMutableDictionary dictionary];
      for (SPDFFillEntry* entry in added) {
          [pages addIndex:(NSUInteger)entry.item.page];
          if (entry.item.isDrawing) {
              NSNumber* page = @(entry.item.page);
              if (!strokes[page]) strokes[page] = [NSMutableArray array];
              [strokes[page] addObject:entry.item];
          } else if (![self writeItem:entry.item cells:entry.cells signature:entry.signature doc:doc err:err length:len]) {
              return NO;
          }
      }
      for (NSNumber* page in strokes) {
          std::vector<spdf_fill_stroke> list;
          for (SPDFFillItem* item in strokes[page]) {
              spdf_fill_stroke stroke;
              memset(&stroke, 0, sizeof(stroke));
              stroke.kind = item.kind;
              stroke.nm = item.nm.UTF8String;
              stroke.rgb[0] = item.color.r, stroke.rgb[1] = item.color.g, stroke.rgb[2] = item.color.b;
              stroke.width = (float)item.lineWidth;
              stroke.points = item.pointBytes;
              stroke.point_count = item.pointCount;
              list.push_back(stroke);
          }
          if (!spdf_fill_add_strokes(doc, page.intValue, list.data(), (int)list.size(), err, len)) return NO;
      }
      return YES;
    }];
}

- (void)registerUndoRemoving:(NSArray<SPDFFillEntry*>*)removing adding:(NSArray<SPDFFillEntry*>*)adding {
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target replaceEntries:removing with:adding];
    }];
}

- (BOOL)replaceEntries:(NSArray<SPDFFillEntry*>*)removed with:(NSArray<SPDFFillEntry*>*)added {
    if (!removed.count && !added.count) return NO;
    [self.overlay holdInk:SPDFFillDrawingsIn(added) washes:SPDFFillDrawingsIn(removed)];
    if (![self applyRemoving:removed adding:added]) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [self registerUndoRemoving:added adding:removed];
    return YES;
}

- (BOOL)removeItems:(NSArray<SPDFFillItem*>*)items {
    if (!items.count) return NO;
    BOOL ok = [self replaceEntries:[self entriesForItems:items] with:@[]];
    if (ok) [self selectItems:@[] page:items.firstObject.page];
    return ok;
}

- (BOOL)replaceItems:(NSArray<SPDFFillItem*>*)removed withStrokes:(NSArray<SPDFFillItem*>*)strokes {
    return [self replaceEntries:[self entriesForItems:removed] with:[self entriesForItems:strokes]];
}

- (NSArray<SPDFFillItem*>*)itemsOnPagesWithPrefix:(const char*)prefix drawingsOnly:(BOOL)drawingsOnly {
    spdf_document* doc = [self.host fillDocument];
    NSInteger pageCount = [self pageCount];
    if (!doc || pageCount <= 0) return @[];
    std::vector<int> pages((size_t)pageCount);
    char err[256];
    int found = spdf_fill_pages_with_items(doc, prefix, pages.data(), (int)pageCount, err, sizeof(err));
    NSMutableArray* items = [NSMutableArray array];
    for (int i = 0; i < MIN(found, (int)pageCount); ++i)
        for (SPDFFillItem* item in [self itemsOnPage:pages[(size_t)i]])
            if (!drawingsOnly || item.isDrawing) [items addObject:item];
    return items;
}

- (void)removeAllDrawings {
    [self flushPendingChanges];
    NSArray* items = [self itemsOnPagesWithPrefix:SPDF_FILL_NM_PREFIX drawingsOnly:YES];
    if (!items.count || ![self removeItems:items]) NSBeep();
}

- (void)removeEverythingAdded {
    [self flushPendingChanges];
    NSArray* items = [self itemsOnPagesWithPrefix:SPDF_FILL_NM_PREFIX drawingsOnly:NO];
    if (!items.count || ![self removeItems:items]) NSBeep();
    self.overlay.selectedItem = nil;
}

#pragma mark - Moving and restyling

- (BOOL)moveItems:(NSArray<SPDFFillItem*>*)items by:(NSSize)delta {
    NSMutableArray<SPDFFillItem*>* movable = [NSMutableArray array];
    for (SPDFFillItem* item in items)
        if (item.cell < 0) [movable addObject:item];  // comb cells stay in their boxes, as they always have
    if (!movable.count || (fabs(delta.width) < 0.01 && fabs(delta.height) < 0.01)) return NO;
    NSInteger page = movable.firstObject.page;
    NSMutableArray<SPDFFillItem*>* moved = [NSMutableArray array];
    for (SPDFFillItem* item in movable) [moved addObject:[item itemMovedBy:delta]];
    [self.overlay holdInk:SPDFFillDrawingsIn(moved) washes:SPDFFillDrawingsIn(movable)];
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      std::vector<const char*> names;
      for (SPDFFillItem* item in movable) names.push_back(item.nm.UTF8String);
      [pages addIndex:(NSUInteger)page];
      return spdf_fill_move_items(doc, (int)page, names.data(), (int)names.size(), (float)delta.width,
                                  (float)delta.height, err, len);
    }];
    if (!ok) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target moveItems:moved by:NSMakeSize(-delta.width, -delta.height)];
    }];
    return YES;
}

// Gives each of `previous` the colour and width of the item of the same name in `targets`.
- (BOOL)applyStyles:(NSArray<SPDFFillItem*>*)targets previous:(NSArray<SPDFFillItem*>*)previous {
    if (!targets.count) return NO;
    [self.overlay holdInk:targets washes:previous];
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      for (SPDFFillItem* item in targets) {
          const char* name = item.nm.UTF8String;
          float rgb[3] = {item.color.r, item.color.g, item.color.b};
          [pages addIndex:(NSUInteger)item.page];
          if (!spdf_fill_restyle_strokes(doc, (int)item.page, &name, 1, rgb, (float)item.lineWidth, err, len)) return NO;
      }
      return YES;
    }];
    if (!ok) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target applyStyles:previous previous:targets];
    }];
    return YES;
}

- (void)restyleSelectionWithColor:(NSInteger)colorIndex width:(NSInteger)widthIndex {
    NSArray<SPDFFillItem*>* drawings = SPDFFillDrawingsIn([self selectedItems]);
    NSMutableArray<SPDFFillItem*>* targets = [NSMutableArray array];
    NSMutableArray<SPDFFillItem*>* previous = [NSMutableArray array];
    for (SPDFFillItem* item in drawings) {
        SPDFFillItem* target = [item itemMovedBy:NSZeroSize];
        if (colorIndex >= 0) target.color = [SPDFMacFillDrawingStyle colorAtIndex:colorIndex];
        if (widthIndex >= 0) target.lineWidth = [SPDFMacFillDrawingStyle widthAtIndex:widthIndex];
        [target updateDrawingBounds];
        SPDFFillRGB a = target.color, b = item.color;
        if (a.r == b.r && a.g == b.g && a.b == b.b && target.lineWidth == item.lineWidth) continue;
        [targets addObject:target];
        [previous addObject:item];
    }
    [self applyStyles:targets previous:previous];
}

- (BOOL)setArrow:(SPDFFillItem*)arrow tail:(NSPoint)tail tip:(NSPoint)tip {
    if (arrow.kind != SPDF_FILL_ARROW || arrow.pointCount < 2) return NO;
    spdf_fill_point newTail = {(float)tail.x, (float)tail.y}, newTip = {(float)tip.x, (float)tip.y};
    spdf_fill_point ends[2] = {newTail, newTip};
    if (memcmp(ends, arrow.pointBytes, sizeof(ends)) == 0) return NO;
    SPDFFillItem* changed = [arrow itemMovedBy:NSZeroSize];
    changed.points = [NSData dataWithBytes:ends length:sizeof(ends)];
    [changed updateDrawingBounds];
    NSInteger page = arrow.page;
    NSString* nm = arrow.nm;
    NSPoint oldTail = NSMakePoint(arrow.pointBytes[0].x, arrow.pointBytes[0].y);
    NSPoint oldTip = NSMakePoint(arrow.pointBytes[1].x, arrow.pointBytes[1].y);
    [self.overlay holdInk:@[ changed ] washes:@[ arrow ]];
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)page];
      return spdf_fill_set_arrow_ends(doc, (int)page, nm.UTF8String, newTail, newTip, err, len);
    }];
    if (!ok) {
        [self.overlay dropDrawingHolds];
        return NO;
    }
    [[self session].undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target setArrow:changed tail:oldTail tip:oldTip];
    }];
    return YES;
}

@end
