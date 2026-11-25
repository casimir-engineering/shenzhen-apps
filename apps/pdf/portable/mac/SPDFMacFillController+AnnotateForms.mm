// The fill_on_pdf route of -applyOperation:tab:completion: (docs/plans/annotate.md § 6 "Pen and arrow" and "Forms"):
// on a PDF these operations are carried out by Fill & Sign's own code, exactly as its tools do them (snapping, the
// commit cycle, its undo steps, which also land on the tab's one undo stack), so an agent's signature or line is the
// same thing the person's click or drag makes. Answers are § 6 JSON; ids are the objects' ids on the page's canvas.
#import "SPDFMacFillController+AnnotatePDF.h"

#import "SPDFMacFillControllerPrivate.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacSignatureStore.h"

#include "spdf_fill_ink_geometry.h"

#include <vector>

// SPDFMacFillController+Drawing.mm.
@interface SPDFMacFillController (AnnotateFormsDrawingShared)
- (NSArray<SPDFFillItem*>*)itemsOnPagesWithPrefix:(const char*)prefix drawingsOnly:(BOOL)drawingsOnly;
@end

static NSDictionary* SPDFAnnotateFail(NSString* code, NSString* message) {
    return @{@"ok": @NO, @"error": code, @"message": message};
}

static NSDictionary* SPDFAnnotateOK(NSDictionary* extra) {
    NSMutableDictionary* answer = [NSMutableDictionary dictionaryWithObject:@YES forKey:@"ok"];
    if (extra) [answer addEntriesFromDictionary:extra];
    return answer;
}

static NSDictionary* SPDFAnnotateRect(NSRect r) {
    return @{@"x": @(NSMinX(r)), @"y": @(NSMinY(r)), @"w": @(NSWidth(r)), @"h": @(NSHeight(r))};
}

static BOOL SPDFAnnotateColor(id value, SPDFFillRGB* out) {
    NSString* text = [value isKindOfClass:[NSString class]] ? value : @"#000000";
    unsigned v = 0;
    if (![text hasPrefix:@"#"] || (text.length != 7 && text.length != 9)) return NO;
    [[NSScanner scannerWithString:[text substringWithRange:NSMakeRange(1, 6)]] scanHexInt:&v];
    out->r = (float)((v >> 16) & 0xFF) / 255.0f, out->g = (float)((v >> 8) & 0xFF) / 255.0f, out->b = (float)(v & 0xFF) / 255.0f;
    return YES;
}

static std::vector<spdf_fill_point> SPDFAnnotatePoints(NSArray* points) {
    std::vector<spdf_fill_point> out;
    for (id p in [points isKindOfClass:[NSArray class]] ? points : @[])
        if ([p isKindOfClass:[NSArray class]] && [p count] >= 2)
            out.push_back({[p[0] floatValue], [p[1] floatValue]});
    return out;
}

static NSString* SPDFAnnotateFieldKind(spdf_field_type type) {
    switch (type) {
    case SPDF_FIELD_TEXT: return @"text";
    case SPDF_FIELD_CHECKBOX: return @"checkbox";
    case SPDF_FIELD_RADIO: return @"radio";
    case SPDF_FIELD_COMBO: return @"combo";
    case SPDF_FIELD_LIST: return @"list";
    case SPDF_FIELD_SIGNATURE: return @"signature";
    }
    return @"text";
}

static NSString* SPDFAnnotateItemKind(spdf_fill_kind kind) {
    NSArray* names = @[@"text", @"check", @"cross", @"signature", @"initials", @"pen", @"arrow"];
    return (NSUInteger)kind < names.count ? names[(NSUInteger)kind] : @"text";
}

@implementation SPDFMacFillController (AnnotateForms)

// The id of the object named nm on the page's canvas (opened for it), or nil.
- (NSNumber*)annotateIDForName:(NSString*)nm page:(NSInteger)page tab:(SPDFDocumentTab*)tab {
    SPDFMacAnnotateSession* session = [self annotateSessionForTab:tab create:YES];
    spdf_paint_doc* canvas = [session canvasForPage:page document:[self.host fillDocument] create:YES];
    spdf_paint_id found = canvas && nm ? spdf_paint_pdf_object_for_name(canvas, nm.UTF8String) : 0;
    return found ? @(found) : nil;
}

- (NSString*)annotateNewItemOnPage:(NSInteger)page besides:(NSSet<NSString*>*)before {
    for (SPDFFillItem* item in [self itemsOnPage:page])
        if (![before containsObject:item.group]) return item.group;
    return nil;
}

- (NSSet<NSString*>*)annotateItemNamesOnPage:(NSInteger)page {
    NSMutableSet* names = [NSMutableSet set];
    for (SPDFFillItem* item in [self itemsOnPage:page]) [names addObject:item.group];
    return names;
}

- (NSDictionary*)annotatePlacedAnswer:(NSString*)nm page:(NSInteger)page tab:(SPDFDocumentTab*)tab {
    NSNumber* object = nm ? [self annotateIDForName:nm page:page tab:tab] : nil;
    return SPDFAnnotateOK(object ? @{@"id": object, @"name": nm} : (nm ? @{@"name": nm} : nil));
}

#pragma mark - Pen lines and arrows

- (NSDictionary*)annotateAddStroke:(spdf_fill_kind)kind points:(const std::vector<spdf_fill_point>&)points
                              page:(NSInteger)page op:(NSDictionary*)op tab:(SPDFDocumentTab*)tab {
    SPDFFillRGB color;
    if (!SPDFAnnotateColor(op[@"color"], &color)) return SPDFAnnotateFail(@"invalid_argument", @"The colour isn't one I can read.");
    CGFloat width = op[@"width"] ? [op[@"width"] doubleValue] : 2;
    SPDFFillItem* item = [SPDFFillItem strokeOfKind:kind page:page points:points.data() count:(int)points.size()
                                              color:color width:width];
    [self addDrawnStrokes:@[ item ]];
    [self writePendingStrokes];  // an agent's line is in the file when it gets its answer
    if (![[self annotateItemNamesOnPage:page] containsObject:item.nm])
        return SPDFAnnotateFail(@"failed", @"The line couldn't be added to this PDF.");
    return [self annotatePlacedAnswer:item.nm page:page tab:tab];
}

- (NSDictionary*)annotateEraseLines:(NSDictionary*)op page:(NSInteger)page tab:(SPDFDocumentTab*)tab {
    std::vector<spdf_fill_point> swath = SPDFAnnotatePoints(op[@"points"]);
    float reach = 0.5f * (op[@"size"] ? [op[@"size"] floatValue] : 10);
    NSMutableArray<SPDFFillItem*>* touched = [NSMutableArray array];
    NSMutableArray* ids = [NSMutableArray array];
    [self writePendingStrokes];
    for (SPDFFillItem* item in [self itemsOnPage:page]) {
        if (!item.isDrawing || !item.pointCount) continue;
        float d = spdf_ink_polyline_distance(item.pointBytes, item.pointCount, swath.data(), (int)swath.size());
        if (d > reach + 0.5f * (float)item.lineWidth) continue;
        [touched addObject:item];
        NSNumber* object = [self annotateIDForName:item.nm page:page tab:tab];
        if (object) [ids addObject:object];
    }
    if (touched.count && ![self removeItems:touched]) return SPDFAnnotateFail(@"failed", @"The lines couldn't be removed.");
    return SPDFAnnotateOK(@{@"removed": ids});
}

#pragma mark - The form

- (NSDictionary*)annotateFormState {
    NSMutableArray* fields = [NSMutableArray array];
    NSMutableArray* items = [NSMutableArray array];
    // A checkbox's or a radio group's value as the file holds it (/V): the option that is on, else "Off".
    NSMutableDictionary<NSString*, NSString*>* chosen = [NSMutableDictionary dictionary];
    for (NSInteger page = 0; page < [self pageCount]; ++page)
        for (SPDFFillField* f in [self fieldsOnPage:page])
            if ((f.type == SPDF_FIELD_CHECKBOX || f.type == SPDF_FIELD_RADIO) && f.isOn && f.name)
                chosen[f.name] = f.value.length ? f.value : @"Yes";
    for (NSInteger page = 0; page < [self pageCount]; ++page) {
        for (SPDFFillField* f in [self fieldsOnPage:page]) {
            NSMutableDictionary* field = [@{@"name": f.name ?: @"", @"kind": SPDFAnnotateFieldKind(f.type),
                                           @"page": @(page + 1), @"rect": SPDFAnnotateRect(f.rect),
                                           @"readOnly": @(f.readOnly), @"filled": @(f.filled),
                                           @"required": @((f.flags & SPDF_FIELD_REQUIRED) != 0)} mutableCopy];
            if (f.label.length) field[@"label"] = f.label;
            if (f.type == SPDF_FIELD_CHECKBOX || f.type == SPDF_FIELD_RADIO) {
                field[@"on"] = @(f.isOn);
                field[@"option"] = f.value ?: @"";
                field[@"value"] = (f.name ? chosen[f.name] : nil) ?: @"Off";
            } else {
                field[@"value"] = f.value ?: @"";
            }
            if (f.options.count) field[@"options"] = f.options;
            [fields addObject:field];
        }
        NSMutableSet* groups = [NSMutableSet set];
        for (SPDFFillItem* it in [self itemsOnPage:page]) {
            if ([groups containsObject:it.group]) continue;  // a comb entry once
            [groups addObject:it.group];
            NSMutableDictionary* item = [@{@"name": it.group, @"kind": SPDFAnnotateItemKind(it.kind), @"page": @(page + 1),
                                          @"rect": SPDFAnnotateRect(it.rect)} mutableCopy];
            if (it.text) item[@"text"] = it.text;
            [items addObject:item];
        }
    }
    NSString* progress = [self progressText];
    return SPDFAnnotateOK(@{@"fields": fields, @"items": items, @"progress": progress ?: [NSNull null]});
}

- (NSDictionary*)annotateSetField:(NSString*)name value:(id)value {
    NSMutableArray<SPDFFillField*>* matches = [NSMutableArray array];
    for (NSInteger page = 0; page < [self pageCount]; ++page)
        for (SPDFFillField* f in [self fieldsOnPage:page])
            if ([f.name isEqual:name]) [matches addObject:f];
    SPDFFillField* field = matches.firstObject;
    if (!field) return SPDFAnnotateFail(@"not_found", [NSString stringWithFormat:@"There is no field named \"%@\".", name]);
    if (field.readOnly) return SPDFAnnotateFail(@"locked", @"This field can't be changed");
    BOOL ok;
    NSString* text = [value isKindOfClass:[NSString class]] ? value : nil;
    switch (field.type) {
    case SPDF_FIELD_SIGNATURE:
        return SPDFAnnotateFail(@"invalid_argument", @"A signature field takes a signature: use form.signature_place.");
    case SPDF_FIELD_CHECKBOX: {
        BOOL on = text ? !([text caseInsensitiveCompare:@"off"] == NSOrderedSame || [text isEqual:@"false"] || !text.length)
                       : [value boolValue];
        ok = [self setOn:on forField:field];
        break;
    }
    case SPDF_FIELD_RADIO: {
        SPDFFillField* target = nil;
        for (SPDFFillField* f in matches)
            if (text ? [f.value isEqual:text] : ([value boolValue] ? f == field : f.isOn)) target = f;
        if (!target) return SPDFAnnotateFail(@"invalid_argument", @"That radio button has no such option.");
        ok = [self setOn:(text != nil || [value boolValue]) forField:target];
        break;
    }
    case SPDF_FIELD_COMBO:
    case SPDF_FIELD_LIST:
        ok = [self setChoice:text ?: @"" forField:field];
        break;
    default:
        ok = [self setText:text ?: [value description] forField:field];
        break;
    }
    return ok ? SPDFAnnotateOK(nil) : SPDFAnnotateFail(@"failed", @"The field couldn't be filled in.");
}

- (NSDictionary*)annotateTextAt:(NSPoint)p page:(NSInteger)page op:(NSDictionary*)op tab:(SPDFDocumentTab*)tab {
    NSString* text = op[@"text"];
    spdf_snap_result snap;
    SPDFFillField* field = [self fieldAt:p page:page];
    if (field && field.type == SPDF_FIELD_TEXT) {  // on a real field: the field takes it, as a click does
        if (field.readOnly) return SPDFAnnotateFail(@"locked", @"This field can't be changed");
        return [self setText:text forField:field] ? SPDFAnnotateOK(@{@"field": field.name ?: @""})
                                                  : SPDFAnnotateFail(@"failed", @"The field couldn't be filled in.");
    }
    [self.overlay resolveAt:p page:page purpose:SPDF_SNAP_FOR_TEXT aspect:1 snapping:YES result:&snap];
    CGFloat size = op[@"size"] ? [op[@"size"] doubleValue] : (snap.font_size > 0 ? snap.font_size : 11);
    NSSet* before = [self annotateItemNamesOnPage:page];
    if (snap.kind == SPDF_SNAP_COMB && snap.cells && snap.cell_count > 0) {
        NSMutableArray* cells = [NSMutableArray array];
        for (int i = 0; i < snap.cell_count; ++i) [cells addObject:[NSValue valueWithRect:SPDFFillRectFromCore(snap.cells[i])]];
        if (![self addCombText:text page:page cells:cells size:size])
            return SPDFAnnotateFail(@"failed", @"The text couldn't be placed.");
    } else {
        int lines = (int)[text componentsSeparatedByString:@"\n"].count;
        spdf_rect box = spdf_fill_text_rect(snap.place.x0, snap.baseline > 0 ? snap.baseline : (float)p.y,
                                            snap.place.x1 - snap.place.x0, (float)size, lines);
        if (![self addTextItem:text page:page rect:SPDFFillRectFromCore(box) size:size])
            return SPDFAnnotateFail(@"failed", @"The text couldn't be placed.");
    }
    return [self annotatePlacedAnswer:[self annotateNewItemOnPage:page besides:before] page:page tab:tab];
}

- (NSDictionary*)annotateMarkAt:(NSPoint)p page:(NSInteger)page cross:(BOOL)cross tab:(SPDFDocumentTab*)tab {
    SPDFFillField* field = [self fieldAt:p page:page];
    if (field && field.type == SPDF_FIELD_CHECKBOX) {  // a real checkbox: ticked, as a click does
        if (field.readOnly) return SPDFAnnotateFail(@"locked", @"This field can't be changed");
        return [self setOn:YES forField:field] ? SPDFAnnotateOK(@{@"field": field.name ?: @""})
                                               : SPDFAnnotateFail(@"failed", @"The box couldn't be ticked.");
    }
    spdf_snap_result snap;
    [self.overlay resolveAt:p page:page purpose:SPDF_SNAP_FOR_MARK aspect:1 snapping:YES result:&snap];
    NSSet* before = [self annotateItemNamesOnPage:page];
    if (![self addMarkOnPage:page box:SPDFFillRectFromCore(snap.place) cross:cross])
        return SPDFAnnotateFail(@"failed", @"The mark couldn't be placed.");
    return [self annotatePlacedAnswer:[self annotateNewItemOnPage:page besides:before] page:page tab:tab];
}

- (NSDictionary*)annotateSignatureIn:(NSRect)rect page:(NSInteger)page initials:(BOOL)initials tab:(SPDFDocumentTab*)tab {
    SPDFMacSignature* signature = [[SPDFMacSignatureStore sharedStore] lastUsedForInitials:initials];
    if (!signature)  // agents never draw one: the person adds theirs first
        return SPDFAnnotateFail(@"no_signature", initials ? @"No initials are saved yet. Add them with Signature > Add Initials… first."
                                                          : @"No signature is saved yet. Add one with Signature > Add Signature… first.");
    CGFloat aspect = signature.aspect > 0.01 ? signature.aspect : 3;
    CGFloat w = MIN(NSWidth(rect), NSHeight(rect) * aspect), h = w / aspect;  // fitted inside, aspect kept
    NSRect fitted = NSMakeRect(NSMidX(rect) - w / 2, NSMidY(rect) - h / 2, w, h);
    SPDFFillItem* item = [self addSignature:signature page:page rect:fitted];
    if (!item) return SPDFAnnotateFail(@"failed", @"The signature couldn't be placed.");
    return [self annotatePlacedAnswer:item.group ?: item.nm page:page tab:tab];
}

- (NSDictionary*)annotateSaveFinalCopy:(NSString*)path {
    [self flushPendingChanges];
    NSString* source = [self.host fillWorkingPath];
    if (!source.length) return SPDFAnnotateFail(@"io_error", @"This document has no file to copy.");
    if ([path.stringByStandardizingPath isEqual:source.stringByStandardizingPath])
        return SPDFAnnotateFail(@"invalid_argument", @"The final copy needs its own name.");
    char err[512] = "";
    if (!spdf_save_final_copy(source.fileSystemRepresentation, NULL, path.fileSystemRepresentation, err, sizeof err))
        return SPDFAnnotateFail(@"io_error", err[0] ? @(err) : @"The final copy couldn't be saved.");
    return SPDFAnnotateOK(@{@"path": path});
}

#pragma mark - The route

- (BOOL)annotateApplyFillOperation:(NSDictionary*)op info:(const spdf_paint_op_info*)info tab:(SPDFDocumentTab*)tab
                        completion:(SPDFAnnotateCompletion)completion {
    SPDFDocumentTab* shown = [self.host fillTab];
    if (!info || info->route != SPDF_PAINT_ROUTE_FILL_ON_PDF || [self.host fillHidden] || !shown) return NO;
    if (tab && tab != shown) return NO;  // Fill & Sign works on the document in front; the canvas route takes the rest
    if (![self.host fillDocument]) return NO;
    // One operation, one undo step: agents' operations arrive outside any event, so grouping by event would merge
    // every operation since the person's last click into one step.
    NSUndoManager* undo = [self session].undoManager;
    BOOL group = (info->flags & SPDF_PAINT_OP_UNDOABLE) && undo.groupingLevel == 0, byEvent = undo.groupsByEvent;
    if (group) undo.groupsByEvent = NO, [undo beginUndoGrouping];
    NSDictionary* answer = [self annotateCarryOut:op info:info shown:shown];
    if (group) {
        [undo endUndoGrouping];
        undo.groupsByEvent = byEvent;
    }
    if (!answer) return NO;
    if (completion) completion(answer);
    return YES;
}

- (nullable NSDictionary*)annotateCarryOut:(NSDictionary*)op info:(const spdf_paint_op_info*)info
                                     shown:(SPDFDocumentTab*)shown {
    NSString* name = op[@"op"];
    NSInteger page = op[@"page"] ? [op[@"page"] integerValue] - 1 : -1;
    NSDictionary* answer;
    if ((info->flags & SPDF_PAINT_OP_NEEDS_PAGE) && (page < 0 || page >= [self pageCount])) {
        answer = SPDFAnnotateFail(@"invalid_argument", @"There is no such page in this document.");
    } else if ([name isEqual:@"pen.add"]) {
        answer = [self annotateAddStroke:SPDF_FILL_PEN points:SPDFAnnotatePoints(op[@"points"]) page:page op:op tab:shown];
    } else if ([name isEqual:@"arrow.add"]) {
        std::vector<spdf_fill_point> ends = SPDFAnnotatePoints(@[ op[@"tail"] ?: @[], op[@"tip"] ?: @[] ]);
        answer = ends.size() == 2 ? [self annotateAddStroke:SPDF_FILL_ARROW points:ends page:page op:op tab:shown]
                                  : SPDFAnnotateFail(@"invalid_argument", @"An arrow needs a tail and a tip.");
    } else if ([name isEqual:@"erase.lines"]) {
        answer = [self annotateEraseLines:op page:page tab:shown];
    } else if ([name isEqual:@"form.state"]) {
        answer = [self annotateFormState];
    } else if ([name isEqual:@"form.field_set"]) {
        answer = [self annotateSetField:op[@"name"] value:op[@"value"]];
    } else if ([name isEqual:@"form.text_add"]) {
        answer = [self annotateTextAt:NSMakePoint([op[@"x"] doubleValue], [op[@"y"] doubleValue]) page:page op:op tab:shown];
    } else if ([name isEqual:@"form.mark_add"]) {
        answer = [self annotateMarkAt:NSMakePoint([op[@"x"] doubleValue], [op[@"y"] doubleValue]) page:page
                                cross:[op[@"kind"] isEqual:@"cross"] tab:shown];
    } else if ([name isEqual:@"form.signature_place"]) {
        NSDictionary* r = op[@"rect"];
        answer = [self annotateSignatureIn:NSMakeRect([r[@"x"] doubleValue], [r[@"y"] doubleValue], [r[@"w"] doubleValue],
                                                      [r[@"h"] doubleValue])
                                      page:page initials:[op[@"kind"] isEqual:@"initials"] tab:shown];
    } else if ([name isEqual:@"form.remove_drawings"]) {
        NSUInteger count = [self itemsOnPagesWithPrefix:SPDF_FILL_NM_PREFIX drawingsOnly:YES].count;
        if (count) [self removeAllDrawings];
        answer = SPDFAnnotateOK(@{@"removed": @(count)});
    } else if ([name isEqual:@"form.remove_everything"]) {
        [self removeEverythingAdded];
        answer = SPDFAnnotateOK(nil);
    } else if ([name isEqual:@"form.save_final_copy"]) {
        answer = [self annotateSaveFinalCopy:op[@"path"]];
    } else {
        return nil;
    }
    return answer;
}

@end
