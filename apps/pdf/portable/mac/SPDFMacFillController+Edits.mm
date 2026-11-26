// Every change Fill & Sign makes to a PDF: the check before it, the core call on the main-thread document, the save
// and redraw, and the step that undoes it. Undo replays the same calls, so an undone fill is saved like any other.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillEditor.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacSignatureStore.h"

#include <vector>

typedef BOOL (^SPDFFillWrite)(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t errLen);

@implementation SPDFMacFillController (Edits)

#pragma mark - The change cycle

- (BOOL)change:(BOOL)fieldsOnly write:(SPDFFillWrite)write {
    return [self change:fieldsOnly write:write emptySaves:YES];
}

// emptySaves NO: a write that changed no page (Annotate's write back of a page it left as it was) saves nothing.
- (BOOL)change:(BOOL)fieldsOnly write:(SPDFFillWrite)write emptySaves:(BOOL)emptySaves {
    if (self.busy) return NO;
    self.busy = YES;
    BOOL ok = [self.host fillPrepareForChangeOfFieldsOnly:fieldsOnly];
    spdf_document* doc = ok ? [self.host fillDocument] : NULL;
    NSMutableIndexSet* pages = [NSMutableIndexSet indexSet];
    char err[1024] = {0};
    if (doc) {
        ok = write(doc, pages, err, sizeof(err));
        if (!ok) [self.host fillShowError:@"Couldn't save what you filled in" detail:err[0] ? @(err) : @""];
    } else {
        ok = NO;
    }
    if (ok && (pages.count || emptySaves)) {
        [pages enumerateIndexesUsingBlock:^(NSUInteger page, BOOL* stop) {
          (void)stop;
          [self invalidatePage:(NSInteger)page];
        }];
        ok = [self.host fillSaveAndRedrawPages:pages];
        SPDFMacSignatureStore* store = [SPDFMacSignatureStore sharedStore];
        if ([self session].isForm && !store.formHintSeen) store.formHintSeen = YES;
    }
    self.busy = NO;
    if (ok) {
        [self.overlay refresh];
        [self.palette updateFromSession:[self session] progress:[self progressText] note:[self paletteNote]];
    }
    return ok;
}

- (NSUndoManager*)undoManager {
    return [self session].undoManager;
}

- (void)undo {
    [self.editor commitAndClose];
    if ([self.undoManager canUndo]) [self.undoManager undo];
    else NSBeep();
}

- (void)redo {
    if ([self.undoManager canRedo]) [self.undoManager redo];
    else NSBeep();
}

- (BOOL)canUndo { return [self.undoManager canUndo]; }
- (BOOL)canRedo { return [self.undoManager canRedo]; }

static BOOL SPDFAddPages(NSMutableIndexSet* pages, const int* changed, int count) {
    for (int i = 0; i < count; ++i) [pages addIndex:(NSUInteger)changed[i]];
    return count > 0;
}

#pragma mark - The PDF's own fields

- (SPDFFillField*)fieldOnPage:(NSInteger)page object:(int)objectNumber {
    for (SPDFFillField* field in [self fieldsOnPage:page])
        if (field.objectNumber == objectNumber) return field;
    return nil;
}

- (BOOL)setText:(NSString*)text forField:(SPDFFillField*)field {
    NSString* old = field.value ?: @"";
    if ([old isEqual:text ?: @""]) return YES;
    NSInteger page = field.page;
    int object = field.objectNumber;
    BOOL ok = [self change:YES write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      int changed[64];
      int count = spdf_form_set_text(doc, (int)page, object, (text ?: @"").UTF8String, changed, 64, err, len);
      return count > 0 && SPDFAddPages(pages, changed, count);
    }];
    if (ok)
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          SPDFFillField* current = [target fieldOnPage:page object:object];
          if (current) [target setText:old forField:current];
        }];
    return ok;
}

- (BOOL)setChoice:(NSString*)choice forField:(SPDFFillField*)field {
    NSString* old = field.value ?: @"";
    if ([old isEqual:choice ?: @""]) return YES;
    NSInteger page = field.page;
    int object = field.objectNumber;
    BOOL ok = [self change:YES write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      int changed[64];
      int count = spdf_form_set_choice(doc, (int)page, object, (choice ?: @"").UTF8String, changed, 64, err, len);
      return count > 0 && SPDFAddPages(pages, changed, count);
    }];
    if (ok)
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          SPDFFillField* current = [target fieldOnPage:page object:object];
          if (current) [target setChoice:old forField:current];
        }];
    return ok;
}

- (BOOL)setOn:(BOOL)on forField:(SPDFFillField*)field {
    if (field.isOn == on) return YES;
    NSInteger page = field.page;
    int object = field.objectNumber;
    // A radio button turned on turns its sibling off: undo turns that sibling back on.
    __block int previousSibling = 0;
    __block NSInteger siblingPage = page;
    int groupID = field.groupID;
    BOOL radioOn = field.type == SPDF_FIELD_RADIO && on;
    if (radioOn)
        for (SPDFFillField* other in [self fieldsOnPage:page])
            if (other.groupID == groupID && other.isOn && other.objectNumber != object) previousSibling = other.objectNumber;
    BOOL ok = [self change:YES write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      int changed[64];
      if (radioOn && !previousSibling) {
          // The group's chosen button may be on another page. Setting this button to the state it already has (off)
          // changes nothing and lists the pages that hold the group.
          int found = spdf_form_set_on(doc, (int)page, object, 0, changed, 64, err, len);
          for (int i = 0; i < found && !previousSibling; ++i)
              if (changed[i] != page)
                  for (SPDFFillField* other in [self fieldsOnPage:changed[i]])
                      if (other.groupID == groupID && other.isOn) previousSibling = other.objectNumber, siblingPage = changed[i];
      }
      int count = spdf_form_set_on(doc, (int)page, object, on ? 1 : 0, changed, 64, err, len);
      return count > 0 && SPDFAddPages(pages, changed, count);
    }];
    if (ok)
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          SPDFFillField* sibling = previousSibling ? [target fieldOnPage:siblingPage object:previousSibling] : nil;
          SPDFFillField* current = [target fieldOnPage:page object:object];
          if (sibling) [target setOn:YES forField:sibling];
          else if (current) [target setOn:!on forField:current];
        }];
    return ok;
}

#pragma mark - Placed items

// Writes one item (or a comb entry, given its cells) as described, under its own /NM.
- (BOOL)writeItem:(SPDFFillItem*)spec cells:(NSArray<NSValue*>*)cells signature:(SPDFMacSignature*)signature
              doc:(spdf_document*)doc err:(char*)err length:(size_t)len {
    int page = (int)spec.page;
    spdf_rect rect = SPDFFillRectToCore(spec.rect);
    const char* nm = spec.nm.UTF8String;
    switch (spec.kind) {
        case SPDF_FILL_TEXT: {
            if (cells.count) {
                std::vector<spdf_rect> boxes;
                for (NSValue* value in cells) boxes.push_back(SPDFFillRectToCore(value.rectValue));
                return spdf_fill_add_comb_text(doc, page, boxes.data(), (int)boxes.size(), (float)spec.fontSize,
                                               spec.text.UTF8String, spec.group.UTF8String,
                                               [self.host fillAuthor].UTF8String, err, len);
            }
            return spdf_fill_add_text(doc, page, rect, (float)spec.fontSize, spec.text.UTF8String, nm,
                                      [self.host fillAuthor].UTF8String, err, len);
        }
        case SPDF_FILL_CHECK:
        case SPDF_FILL_CROSS: return spdf_fill_add_mark(doc, page, rect, spec.kind == SPDF_FILL_CROSS, nm, err, len);
        case SPDF_FILL_SIGNATURE:
        case SPDF_FILL_INITIALS: {
            if (!signature) {
                snprintf(err, len, "%s", "This signature is no longer saved.");
                return NO;
            }
            if (signature.png.length)
                return spdf_fill_add_signature_png(doc, page, rect, (const unsigned char*)signature.png.bytes,
                                                   signature.png.length, nm, err, len);
            std::vector<const char*> paths;
            for (NSString* path in signature.paths) paths.push_back(path.UTF8String);
            float rgb[3];
            [signature getRGB:rgb];
            return spdf_fill_add_signature_paths(doc, page, rect, (float)signature.aspect, paths.data(),
                                                 (int)paths.size(), rgb, nm, err, len);
        }
        case SPDF_FILL_PEN:
        case SPDF_FILL_ARROW: break;  // written with spdf_fill_add_strokes (+Drawing.mm)
    }
    return NO;
}

- (BOOL)insertItem:(SPDFFillItem*)spec cells:(NSArray<NSValue*>*)cells signature:(SPDFMacSignature*)signature {
    if (signature) self.usedSignatures[signature.identifier] = signature;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)spec.page];
      return [self writeItem:spec cells:cells signature:signature doc:doc err:err length:len];
    }];
    if (ok)
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          [target removeItem:spec cells:cells signature:signature];
        }];
    return ok;
}

- (BOOL)removeItem:(SPDFFillItem*)spec cells:(NSArray<NSValue*>*)cells signature:(SPDFMacSignature*)signature {
    NSString* name = cells.count ? spec.group : spec.nm;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)spec.page];
      return spdf_fill_delete(doc, (int)spec.page, name.UTF8String, err, len);
    }];
    if (ok)
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          [target insertItem:spec cells:cells signature:signature];
        }];
    return ok;
}

- (SPDFFillItem*)addTextItem:(NSString*)text page:(NSInteger)page rect:(NSRect)rect size:(CGFloat)size {
    if (!text.length) return nil;
    SPDFFillItem* spec = [SPDFFillItem new];
    spec.kind = SPDF_FILL_TEXT;
    spec.page = page;
    spec.rect = rect;
    spec.fontSize = size;
    spec.text = text;
    spec.nm = [@SPDF_FILL_NM_PREFIX stringByAppendingString:SPDFFillNewIdentifier()];
    spec.group = spec.nm;
    spec.cell = -1;
    return [self insertItem:spec cells:nil signature:nil] ? spec : nil;
}

- (BOOL)addCombText:(NSString*)text page:(NSInteger)page cells:(NSArray<NSValue*>*)cells size:(CGFloat)size {
    if (!text.length || !cells.count) return NO;
    SPDFFillItem* spec = [SPDFFillItem new];
    spec.kind = SPDF_FILL_TEXT;
    spec.page = page;
    NSRect all = cells.firstObject.rectValue;
    for (NSValue* value in cells) all = NSUnionRect(all, value.rectValue);
    spec.rect = all;
    spec.fontSize = size;
    spec.text = text;
    spec.group = [@SPDF_FILL_NM_PREFIX stringByAppendingString:SPDFFillNewIdentifier()];
    spec.nm = spec.group;
    spec.cell = 0;
    return [self insertItem:spec cells:cells signature:nil];
}

- (BOOL)addMarkOnPage:(NSInteger)page box:(NSRect)box cross:(BOOL)cross {
    SPDFFillItem* spec = [SPDFFillItem new];
    spec.kind = cross ? SPDF_FILL_CROSS : SPDF_FILL_CHECK;
    spec.page = page;
    CGFloat side = MIN(NSWidth(box), NSHeight(box));
    spec.rect = NSMakeRect(NSMidX(box) - side / 2, NSMidY(box) - side / 2, side, side);
    spec.nm = [@SPDF_FILL_NM_PREFIX stringByAppendingString:SPDFFillNewIdentifier()];
    spec.group = spec.nm;
    spec.cell = -1;
    return [self insertItem:spec cells:nil signature:nil];
}

- (SPDFFillItem*)addSignature:(SPDFMacSignature*)signature page:(NSInteger)page rect:(NSRect)rect {
    if (!signature) return nil;
    SPDFFillItem* spec = [SPDFFillItem new];
    spec.kind = signature.initials ? SPDF_FILL_INITIALS : SPDF_FILL_SIGNATURE;
    spec.page = page;
    spec.rect = rect;
    NSString* prefix = signature.initials ? @SPDF_FILL_INITIALS_NM_PREFIX : @SPDF_FILL_SIGNATURE_NM_PREFIX;
    spec.nm = [NSString stringWithFormat:@"%@%@-%@", prefix, signature.identifier, SPDFFillNewIdentifier()];
    spec.group = spec.nm;
    spec.cell = -1;
    if (![self insertItem:spec cells:nil signature:signature]) return nil;
    [[SPDFMacSignatureStore sharedStore] markUsed:signature];
    return spec;
}

// A comb entry's cells and text, read back from the page.
- (NSArray<NSValue*>*)combCellsOf:(SPDFFillItem*)item text:(NSString**)textOut {
    NSMutableArray<SPDFFillItem*>* cells = [NSMutableArray array];
    for (SPDFFillItem* other in [self itemsOnPage:item.page])
        if (other.cell >= 0 && [other.group isEqual:item.group]) [cells addObject:other];
    [cells sortUsingComparator:^NSComparisonResult(SPDFFillItem* a, SPDFFillItem* b) {
      return a.cell < b.cell ? NSOrderedAscending : a.cell > b.cell ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray* rects = [NSMutableArray array];
    NSMutableString* text = [NSMutableString string];
    for (SPDFFillItem* cell in cells) {
        [rects addObject:[NSValue valueWithRect:cell.rect]];
        [text appendString:cell.text.length ? cell.text : @" "];
    }
    if (textOut) *textOut = text;
    return rects;
}

- (SPDFMacSignature*)signatureForItem:(SPDFFillItem*)item {
    NSString* identifier = SPDFFillSignatureIDFromName(item.nm);
    if (!identifier) return nil;
    return self.usedSignatures[identifier] ?: [[SPDFMacSignatureStore sharedStore] signatureWithIdentifier:identifier];
}

- (BOOL)deleteItem:(SPDFFillItem*)item {
    if (!item) return NO;
    SPDFFillItem* spec = item;
    NSArray* cells = nil;
    if (item.cell >= 0) {
        NSString* text = nil;
        cells = [self combCellsOf:item text:&text];
        spec = [SPDFFillItem new];
        spec.kind = SPDF_FILL_TEXT;
        spec.page = item.page;
        spec.fontSize = item.fontSize;
        spec.text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length ? text : @"";
        spec.group = item.group;
        spec.nm = item.group;
        spec.cell = 0;
    }
    return [self removeItem:spec cells:cells signature:item.isSignature ? [self signatureForItem:item] : nil];
}

- (BOOL)updateItem:(SPDFFillItem*)item rect:(NSRect)rect {
    if (!item || item.cell >= 0 || NSEqualRects(item.rect, rect)) return NO;
    NSRect old = item.rect;
    NSString* nm = item.nm;
    NSInteger page = item.page;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)page];
      spdf_rect r = SPDFFillRectToCore(rect);
      return spdf_fill_update(doc, (int)page, nm.UTF8String, &r, 0, NULL, err, len);
    }];
    if (ok) {
        SPDFFillItem* moved = [SPDFFillItem new];
        moved.kind = item.kind;
        moved.page = page;
        moved.rect = rect;
        moved.nm = nm;
        moved.group = item.group;
        moved.cell = -1;
        moved.text = item.text;
        moved.fontSize = item.fontSize;
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          [target updateItem:moved rect:old];
        }];
    }
    return ok;
}

- (BOOL)updateItem:(SPDFFillItem*)item text:(NSString*)text size:(CGFloat)size {
    if (!item) return NO;
    if (!text.length) return [self deleteItem:item];
    NSString* oldText = item.text ?: @"";
    CGFloat oldSize = item.fontSize;
    NSRect oldRect = item.rect;
    if ([oldText isEqual:text] && fabs(oldSize - size) < 0.01) return YES;
    NSString* nm = item.nm;
    NSInteger page = item.page;
    // The box follows the text: as wide and as many lines as it now needs, on the same first baseline.
    float baseline = spdf_fill_text_baseline(SPDFFillRectToCore(oldRect), (float)oldSize);
    CGFloat width = NSWidth(oldRect);
    NSDictionary* attrs = @{NSFontAttributeName : [NSFont fontWithName:@"Helvetica" size:size] ?: [NSFont systemFontOfSize:size]};
    for (NSString* line in [text componentsSeparatedByString:@"\n"]) width = MAX(width, [line sizeWithAttributes:attrs].width + 2);
    NSRect rect = SPDFFillRectFromCore(spdf_fill_text_rect((float)NSMinX(oldRect), baseline, (float)width, (float)size,
                                                           (int)[text componentsSeparatedByString:@"\n"].count));
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)page];
      spdf_rect r = SPDFFillRectToCore(rect);
      return spdf_fill_update(doc, (int)page, nm.UTF8String, &r, (float)size, text.UTF8String, err, len);
    }];
    if (ok) {
        SPDFFillItem* changed = [SPDFFillItem new];
        changed.kind = SPDF_FILL_TEXT;
        changed.page = page;
        changed.rect = rect;
        changed.nm = nm;
        changed.group = nm;
        changed.cell = -1;
        changed.text = text;
        changed.fontSize = size;
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          [target restoreText:changed text:oldText size:oldSize rect:oldRect];
        }];
    }
    return ok;
}

- (void)restoreText:(SPDFFillItem*)item text:(NSString*)text size:(CGFloat)size rect:(NSRect)rect {
    NSString* currentText = item.text;
    CGFloat currentSize = item.fontSize;
    NSRect currentRect = item.rect;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)item.page];
      spdf_rect r = SPDFFillRectToCore(rect);
      return spdf_fill_update(doc, (int)item.page, item.nm.UTF8String, &r, (float)size, text.UTF8String, err, len);
    }];
    if (!ok) return;
    SPDFFillItem* restored = [SPDFFillItem new];
    restored.kind = SPDF_FILL_TEXT;
    restored.page = item.page;
    restored.rect = rect;
    restored.nm = item.nm;
    restored.group = item.nm;
    restored.cell = -1;
    restored.text = text;
    restored.fontSize = size;
    [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
      [target restoreText:restored text:currentText size:currentSize rect:currentRect];
    }];
}

- (BOOL)setItem:(SPDFFillItem*)item cross:(BOOL)cross {
    if (!item.isMark || (item.kind == SPDF_FILL_CROSS) == cross) return NO;
    NSString* nm = item.nm;
    NSInteger page = item.page;
    BOOL ok = [self change:NO write:^BOOL(spdf_document* doc, NSMutableIndexSet* pages, char* err, size_t len) {
      [pages addIndex:(NSUInteger)page];
      return spdf_fill_set_mark_kind(doc, (int)page, nm.UTF8String, cross ? 1 : 0, err, len);
    }];
    if (ok) {
        SPDFFillItem* changed = [SPDFFillItem new];
        changed.kind = cross ? SPDF_FILL_CROSS : SPDF_FILL_CHECK;
        changed.page = page;
        changed.rect = item.rect;
        changed.nm = nm;
        changed.group = nm;
        changed.cell = -1;
        [self.undoManager registerUndoWithTarget:self handler:^(SPDFMacFillController* target) {
          [target setItem:changed cross:!cross];
        }];
    }
    return ok;
}

@end
