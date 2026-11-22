#import "SPDFMacFillModel.h"
#import "SPDFMacSignatureStore.h"

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

@implementation SPDFFillSession {
    NSUndoManager* _undoManager;
}
- (instancetype)init {
    if ((self = [super init])) _tool = SPDFFillToolText;
    return self;
}
- (NSUndoManager*)undoManager {
    if (!_undoManager) _undoManager = [NSUndoManager new];
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
