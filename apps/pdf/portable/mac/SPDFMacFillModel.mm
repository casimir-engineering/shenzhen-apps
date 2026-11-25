#import "SPDFMacFillModel.h"
#import "SPDFMacSignatureStore.h"

#include "spdf_fill_ink_geometry.h"

static NSString* SPDFFillString(const char* utf8) {
    return utf8 && *utf8 ? ([NSString stringWithUTF8String:utf8] ?: @"") : @"";
}

@implementation SPDFFillField
- (BOOL)readOnly {
    return (self.flags & (SPDF_FIELD_READ_ONLY | SPDF_FIELD_SIGNED)) != 0;
}
- (BOOL)hidden {
    return (self.flags & SPDF_FIELD_HIDDEN) != 0;
}
- (BOOL)isOn {
    return (self.flags & SPDF_FIELD_ON) != 0;
}
- (BOOL)filled {
    switch (self.type) {
        case SPDF_FIELD_CHECKBOX:
        case SPDF_FIELD_RADIO: return self.isOn;
        case SPDF_FIELD_SIGNATURE: return (self.flags & SPDF_FIELD_SIGNED) != 0;
        default: return self.value.length > 0;
    }
}
+ (NSArray<SPDFFillField*>*)fieldsFromWidgets:(const spdf_form_widgets*)widgets {
    NSMutableArray* fields = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, widgets ? widgets->count : 0)];
    for (int i = 0; widgets && i < widgets->count; ++i) {
        const spdf_form_widget* w = &widgets->items[i];
        SPDFFillField* field = [SPDFFillField new];
        field.page = w->page_index;
        field.objectNumber = w->object_number;
        field.groupID = w->group_id;
        field.rect = SPDFFillRectFromCore(w->rect);
        field.type = w->type;
        field.flags = w->flags;
        field.maxLen = w->max_len;
        field.fontSize = w->font_size;
        field.name = SPDFFillString(w->name);
        field.label = SPDFFillString(w->label);
        field.value = SPDFFillString(w->value);
        NSMutableArray* options = [NSMutableArray array];
        for (int k = 0; k < w->option_count && w->options; ++k) [options addObject:SPDFFillString(w->options[k])];
        field.options = options;
        if (NSWidth(field.rect) > 0.5 && NSHeight(field.rect) > 0.5) [fields addObject:field];
    }
    return fields;
}
@end

@implementation SPDFFillItem
- (BOOL)isMark {
    return self.kind == SPDF_FILL_CHECK || self.kind == SPDF_FILL_CROSS;
}
- (BOOL)isSignature {
    return self.kind == SPDF_FILL_SIGNATURE || self.kind == SPDF_FILL_INITIALS;
}
- (BOOL)isDrawing {
    return self.kind == SPDF_FILL_PEN || self.kind == SPDF_FILL_ARROW;
}
- (const spdf_fill_point*)pointBytes {
    return (const spdf_fill_point*)self.points.bytes;
}
- (int)pointCount {
    return (int)(self.points.length / sizeof(spdf_fill_point));
}
+ (SPDFFillItem*)strokeOfKind:(spdf_fill_kind)kind page:(NSInteger)page points:(const spdf_fill_point*)points
                        count:(int)count color:(SPDFFillRGB)color width:(CGFloat)width {
    SPDFFillItem* item = [SPDFFillItem new];
    item.kind = kind;
    item.page = page;
    item.color = color;
    item.lineWidth = width;
    item.points = [NSData dataWithBytes:points length:sizeof(spdf_fill_point) * (size_t)MAX(0, count)];
    NSString* prefix = kind == SPDF_FILL_ARROW ? @SPDF_FILL_ARROW_NM_PREFIX : @SPDF_FILL_PEN_NM_PREFIX;
    item.nm = [prefix stringByAppendingString:SPDFFillNewIdentifier()];
    item.group = item.nm;
    item.cell = -1;
    [item updateDrawingBounds];
    return item;
}
- (void)updateDrawingBounds {
    int count = self.pointCount;
    if (!count) return;
    float half = (float)self.lineWidth / 2;
    spdf_rect r = spdf_ink_bounds(self.pointBytes, count, half);
    if (self.kind == SPDF_FILL_ARROW && count >= 2) {
        spdf_fill_point head[3];
        spdf_ink_arrow_head(self.pointBytes[0], self.pointBytes[1], (float)self.lineWidth, head);
        spdf_rect h = spdf_ink_bounds(head, 3, half);
        r.x0 = MIN(r.x0, h.x0), r.y0 = MIN(r.y0, h.y0), r.x1 = MAX(r.x1, h.x1), r.y1 = MAX(r.y1, h.y1);
    }
    self.rect = SPDFFillRectFromCore(r);
}
- (SPDFFillItem*)itemMovedBy:(NSSize)delta {
    SPDFFillItem* moved = [SPDFFillItem new];
    moved.kind = self.kind;
    moved.page = self.page;
    moved.rect = NSOffsetRect(self.rect, delta.width, delta.height);
    moved.fontSize = self.fontSize;
    moved.nm = self.nm;
    moved.group = self.group;
    moved.cell = self.cell;
    moved.text = self.text;
    moved.color = self.color;
    moved.lineWidth = self.lineWidth;
    if (self.points.length) {
        NSMutableData* points = [self.points mutableCopy];
        spdf_fill_point* p = (spdf_fill_point*)points.mutableBytes;
        for (int i = 0; i < self.pointCount; ++i) p[i].x += (float)delta.width, p[i].y += (float)delta.height;
        moved.points = points;
    }
    return moved;
}
+ (NSArray<SPDFFillItem*>*)itemsFromCore:(const spdf_fill_items*)items {
    NSMutableArray* out = [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, items ? items->count : 0)];
    for (int i = 0; items && i < items->count; ++i) {
        const spdf_fill_item* it = &items->items[i];
        SPDFFillItem* item = [SPDFFillItem new];
        item.kind = it->kind;
        item.page = it->page_index;
        item.rect = SPDFFillRectFromCore(it->rect);
        item.fontSize = it->font_size;
        item.nm = SPDFFillString(it->nm);
        item.group = it->group ? SPDFFillString(it->group) : item.nm;
        item.cell = it->cell;
        item.text = it->text ? SPDFFillString(it->text) : nil;
        SPDFFillRGB color = {it->rgb[0], it->rgb[1], it->rgb[2]};
        item.color = color;
        item.lineWidth = it->width;
        if (it->points && it->point_count > 0)
            item.points = [NSData dataWithBytes:it->points length:sizeof(spdf_fill_point) * (size_t)it->point_count];
        [out addObject:item];
    }
    return out;
}
@end

@implementation SPDFFillSnapPage {
    spdf_snap_geometry _geometry;
}
- (instancetype)initTakingGeometry:(spdf_snap_geometry)geometry {
    if ((self = [super init])) _geometry = geometry;
    return self;
}
- (const spdf_snap_geometry*)geometry {
    return &_geometry;
}
- (void)dealloc {
    spdf_snap_geometry_free(&_geometry);
}
@end

// The tab's Fill & Sign undo manager. What one click, key or menu command registers is one step, as grouping by event
// gives, but the step is closed by this manager itself on the next turn of the main queue, so it always posts
// NSUndoManagerDidCloseUndoGroupNotification: Annotate puts every step on the tab's one undo stack from it
// (SPDFMacFillController+AnnotatePDF.mm). A menu command or a click whose group AppKit closed silently was missing
// from that stack, so Cmd-Z skipped it (Remove Everything Added with Annotate).
@interface SPDFFillUndoManager : NSUndoManager
@end

@implementation SPDFFillUndoManager {
    BOOL _turnGroupOpen;
}
- (instancetype)init {
    if ((self = [super init])) self.groupsByEvent = NO;
    return self;
}
- (void)closeTurnGroup {
    if (_turnGroupOpen && self.groupingLevel == 1) [self endUndoGrouping];
    _turnGroupOpen = NO;
}
- (void)openTurnGroup {
    if (self.groupingLevel > 0 || self.isUndoing || self.isRedoing) return;
    [self beginUndoGrouping];
    _turnGroupOpen = YES;
    __weak SPDFFillUndoManager* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf closeTurnGroup]; });
}
- (void)registerUndoWithTarget:(id)target handler:(void (^)(id))handler {
    [self openTurnGroup];
    [super registerUndoWithTarget:target handler:handler];
}
- (void)registerUndoWithTarget:(id)target selector:(SEL)selector object:(id)object {
    [self openTurnGroup];
    [super registerUndoWithTarget:target selector:selector object:object];
}
- (BOOL)canUndo {
    [self closeTurnGroup];
    return [super canUndo];
}
- (BOOL)canRedo {
    [self closeTurnGroup];
    return [super canRedo];
}
- (void)undo {
    [self closeTurnGroup];
    [super undo];
}
- (void)redo {
    [self closeTurnGroup];
    [super redo];
}
@end

@implementation SPDFFillSession {
    NSUndoManager* _undoManager;
}
- (instancetype)init {
    if ((self = [super init])) {
        _tool = SPDFFillToolText;
        _selection = @[];
    }
    return self;
}
- (NSUndoManager*)undoManager {
    if (!_undoManager) _undoManager = [SPDFFillUndoManager new];
    return _undoManager;
}
- (BOOL)isForm {
    return self.hasSummary && self.summary.kind == SPDF_FORM_FILLABLE;
}
@end

NSString* SPDFFillNewIdentifier(void) {
    return [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
}

NSString* SPDFFillSignatureIDFromName(NSString* nm) {
    for (NSString* prefix in @[ @SPDF_FILL_SIGNATURE_NM_PREFIX, @SPDF_FILL_INITIALS_NM_PREFIX ]) {
        if (![nm hasPrefix:prefix]) continue;
        NSString* rest = [nm substringFromIndex:prefix.length];
        NSRange dash = [rest rangeOfString:@"-"];
        return dash.location == NSNotFound ? nil : [rest substringToIndex:dash.location];
    }
    return nil;
}
