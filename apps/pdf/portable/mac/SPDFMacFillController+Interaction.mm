// What a click, a key or the text box does in Fill & Sign: fields take their own clicks, the Text tool snaps to lines,
// boxes and small squares, the Mark tool places checks and crosses, a picked-up signature lands where it is clicked,
// and Tab walks fields (or a flat form's lines and boxes) in reading order.
#import "SPDFMacFillControllerPrivate.h"

#import "SPDFMacFillEditor.h"
#import "SPDFMacFillOverlayView.h"
#import "SPDFMacFillPalette.h"
#import "SPDFMacSignatureSheet.h"
#import "SPDFMacSignatureStore.h"

#include <vector>

@implementation SPDFMacFillController (Interaction)

#pragma mark - Clicks

- (SPDFFillField*)fieldAt:(NSPoint)p page:(NSInteger)page {
    for (SPDFFillField* field in [[self fieldsOnPage:page] reverseObjectEnumerator])
        if (!field.hidden && NSPointInRect(p, field.rect)) return field;
    return nil;
}

- (void)activateField:(SPDFFillField*)field {
    self.overlay.focusedField = field;
    self.overlay.focusedTargetRect = NSZeroRect;
    [self.overlay revealPageRect:field.rect page:field.page];
    switch (field.type) {
        case SPDF_FIELD_TEXT: [self openEditorForField:field]; break;
        case SPDF_FIELD_CHECKBOX: [self setOn:!field.isOn forField:field]; break;
        case SPDF_FIELD_RADIO: [self setOn:YES forField:field]; break;
        case SPDF_FIELD_COMBO:
        case SPDF_FIELD_LIST: [self showChoiceMenuForField:field]; break;
        case SPDF_FIELD_SIGNATURE: [self placeSignatureInField:field]; break;
    }
    self.overlay.needsDisplay = YES;
}

- (void)clickOnPage:(NSInteger)page at:(NSPoint)p modifiers:(NSEventModifierFlags)modifiers {
    SPDFFillSession* session = [self session];
    SPDFFillField* field = [self fieldAt:p page:page];
    if (field) {
        if (!field.readOnly) [self activateField:field];
        return;
    }
    self.overlay.focusedField = nil;
    BOOL snapping = !(modifiers & NSEventModifierFlagCommand);
    BOOL otherMark = (modifiers & NSEventModifierFlagOption) != 0;
    spdf_snap_result snap;
    if (session.tool == SPDFFillToolSignature && session.pickedSignature) {
        [self.overlay resolveAt:p page:page purpose:SPDF_SNAP_FOR_SIGNATURE aspect:session.pickedSignature.aspect
                       snapping:snapping result:&snap];
        SPDFMacSignature* signature = session.pickedSignature;
        [self endInteraction];  // one click places it; the tool goes back to Text
        [self addSignature:signature page:page rect:SPDFFillRectFromCore(snap.place)];
        [self refreshChrome];
        return;
    }
    if (session.tool == SPDFFillToolMark) {
        [self.overlay resolveAt:p page:page purpose:SPDF_SNAP_FOR_MARK aspect:1 snapping:snapping result:&snap];
        [self addMarkOnPage:page box:SPDFFillRectFromCore(snap.place) cross:session.markCross != otherMark];
        return;
    }
    [self.overlay resolveAt:p page:page purpose:SPDF_SNAP_FOR_TEXT aspect:1 snapping:snapping result:&snap];
    if (snap.place_mark) {
        [self addMarkOnPage:page box:SPDFFillRectFromCore(snap.place) cross:session.markCross != otherMark];
        return;
    }
    [self openEditorForNewTextOnPage:page snap:&snap];
}

- (void)openEditorForNewTextOnPage:(NSInteger)page snap:(const spdf_snap_result*)snap {
    SPDFFillSession* session = [self session];
    if (session.hasSummary && !session.summary.can_add_items) {
        [self.host fillPrepareForChangeOfFieldsOnly:NO];  // says why nothing can be added
        return;
    }
    SPDFMacFillEditor* editor = [self newEditor];
    editor.page = page;
    editor.fontSize = snap->font_size > 0 ? snap->font_size : 11;
    if (snap->kind == SPDF_SNAP_COMB && snap->cells && snap->cell_count > 0) {
        NSMutableArray* cells = [NSMutableArray array];
        NSRect all = SPDFFillRectFromCore(snap->cells[0]);
        for (int i = 0; i < snap->cell_count; ++i) {
            [cells addObject:[NSValue valueWithRect:SPDFFillRectFromCore(snap->cells[i])]];
            all = NSUnionRect(all, SPDFFillRectFromCore(snap->cells[i]));
        }
        editor.combCells = cells;
        editor.box = SPDFFillRectFromCore(spdf_fill_text_rect((float)NSMinX(all),
                                                              (float)(NSMidY(all) + 0.35 * editor.fontSize),
                                                              (float)NSWidth(all), (float)editor.fontSize, 1));
    } else {
        editor.box = SPDFFillRectFromCore(snap->place);
    }
    [self beginEditor:editor text:@"" label:@(snap->label)];
}

#pragma mark - The text box

- (SPDFMacFillEditor*)newEditor {
    [self.editor commitAndClose];
    [self.editor close];
    SPDFMacFillEditor* editor = [[SPDFMacFillEditor alloc] initWithFrame:NSZeroRect];
    editor.delegate = (id<SPDFMacFillEditorDelegate>)self;  // the editor callbacks below
    editor.darkPage = [self.host fillDarkPages];
    return editor;
}

- (void)beginEditor:(SPDFMacFillEditor*)editor text:(NSString*)text label:(NSString*)label {
    self.editor = editor;
    NSInteger highlighted = -1;
    NSArray* suggestions = text.length ? @[] : [self suggestionsForLabel:label highlighted:&highlighted];
    [editor beginInOverlay:self.overlay text:text suggestions:suggestions highlighted:highlighted];
    [self.overlay revealPageRect:editor.box page:editor.page];
    self.overlay.needsDisplay = YES;
}

- (void)openEditorForField:(SPDFFillField*)field {
    if (field.readOnly || ![self.host fillPrepareForChangeOfFieldsOnly:YES]) return;
    SPDFFillField* current = nil;
    for (SPDFFillField* f in [self fieldsOnPage:field.page])
        if (f.objectNumber == field.objectNumber) current = f;
    field = current ?: field;
    SPDFMacFillEditor* editor = [self newEditor];
    editor.field = field;
    editor.page = field.page;
    editor.box = field.rect;
    editor.multiline = (field.flags & SPDF_FIELD_MULTILINE) != 0;
    CGFloat height = NSHeight(field.rect);
    editor.fontSize = field.fontSize > 0 ? field.fontSize : editor.multiline ? 10 : MAX(6.0, MIN(12.0, height * 0.65));
    editor.maxLength = field.maxLen;
    if ((field.flags & SPDF_FIELD_COMB) && field.maxLen > 0) {
        NSMutableArray* cells = [NSMutableArray array];
        CGFloat width = NSWidth(field.rect) / field.maxLen;
        for (int i = 0; i < field.maxLen; ++i)
            [cells addObject:[NSValue valueWithRect:NSMakeRect(NSMinX(field.rect) + i * width, NSMinY(field.rect), width,
                                                                NSHeight(field.rect))]];
        editor.combCells = cells;
    }
    self.overlay.focusedField = field;
    [self beginEditor:editor text:field.value ?: @"" label:field.label.length ? field.label : field.name];
}

- (void)openEditorForItem:(SPDFFillItem*)item {
    if (!item.text) return;
    SPDFMacFillEditor* editor = [self newEditor];
    editor.page = item.page;
    editor.fontSize = item.fontSize > 0 ? item.fontSize : 11;
    NSString* text = item.text;
    if (item.cell >= 0) {
        NSMutableArray<SPDFFillItem*>* cells = [NSMutableArray array];
        for (SPDFFillItem* other in [self itemsOnPage:item.page])
            if (other.cell >= 0 && [other.group isEqual:item.group]) [cells addObject:other];
        [cells sortUsingComparator:^NSComparisonResult(SPDFFillItem* a, SPDFFillItem* b) {
          return a.cell < b.cell ? NSOrderedAscending : a.cell > b.cell ? NSOrderedDescending : NSOrderedSame;
        }];
        NSMutableArray* rects = [NSMutableArray array];
        NSMutableString* joined = [NSMutableString string];
        NSRect all = cells.firstObject.rect;
        for (SPDFFillItem* cell in cells) {
            [rects addObject:[NSValue valueWithRect:cell.rect]];
            [joined appendString:cell.text.length ? cell.text : @" "];
            all = NSUnionRect(all, cell.rect);
        }
        editor.combItems = cells;
        editor.combCells = rects;
        editor.box = SPDFFillRectFromCore(spdf_fill_text_rect((float)NSMinX(all),
                                                              (float)(NSMidY(all) + 0.35 * editor.fontSize),
                                                              (float)NSWidth(all), (float)editor.fontSize, 1));
        text = [joined stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    } else {
        editor.item = item;
        editor.box = item.rect;
    }
    [self beginEditor:editor text:text label:@""];
}

- (void)fillEditor:(SPDFMacFillEditor*)editor commitMoving:(NSInteger)move {
    if (editor != self.editor || self.busy) return;
    NSString* text = editor.text;
    self.editor = nil;
    [editor close];
    SPDFFillField* field = editor.field;
    if (field) {
        SPDFFillField* current = nil;
        for (SPDFFillField* f in [self fieldsOnPage:field.page])
            if (f.objectNumber == field.objectNumber) current = f;
        current = current ?: field;
        if (field.type == SPDF_FIELD_COMBO) [self setChoice:text forField:current];
        else [self setText:text forField:current];
    } else if (editor.combCells.count) {
        NSString* trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSUndoManager* undo = [self session].undoManager;
        [undo beginUndoGrouping];
        if (editor.combItems.count) [self deleteItem:editor.combItems.firstObject];
        if (trimmed.length) [self addCombText:text page:editor.page cells:editor.combCells size:editor.fontSize];
        [undo endUndoGrouping];
    } else if (editor.item) {
        [self updateItem:editor.item text:text size:editor.fontSize];
    } else if ([text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) {
        [self addTextItem:text page:editor.page rect:[editor placedTextBox] size:editor.fontSize];
    }
    self.overlay.needsDisplay = YES;
    if (move) [self moveFocusForward:move > 0];
}

- (void)fillEditorDidCancel:(SPDFMacFillEditor*)editor {
    if (editor != self.editor) return;
    self.editor = nil;
    [editor close];
    self.overlay.needsDisplay = YES;
}

- (void)fillEditorFlush:(SPDFMacFillEditor*)editor {
    if (editor != self.editor || self.busy || editor.combCells.count) return;
    NSString* text = editor.text;
    if (editor.field) {
        if ([self setText:text forField:editor.field])
            for (SPDFFillField* f in [self fieldsOnPage:editor.field.page])
                if (f.objectNumber == editor.field.objectNumber) editor.field = f;
    } else if (editor.item) {
        [self updateItem:editor.item text:text size:editor.fontSize];
        for (SPDFFillItem* item in [self itemsOnPage:editor.page])
            if ([item.nm isEqual:editor.item.nm]) editor.item = item;
    } else if (text.length) {
        SPDFFillItem* added = [self addTextItem:text page:editor.page rect:[editor placedTextBox] size:editor.fontSize];
        if (added) {
            editor.item = added;
            editor.box = added.rect;
        }
    }
}

- (void)fillEditorEditDetails:(SPDFMacFillEditor*)editor {
    [self editMyDetails];
    if (editor == self.editor) {
        NSInteger highlighted = -1;
        [editor setSuggestions:[self suggestionsForLabel:@"" highlighted:&highlighted]];
    }
}

#pragma mark - Suggestions

- (NSArray<SPDFMacFillSuggestion*>*)suggestionsForLabel:(NSString*)label highlighted:(NSInteger*)highlighted {
    NSDictionary* details = [[SPDFMacSignatureStore sharedStore] details];
    NSString* name = [details[@"name"] length] ? details[@"name"] : [self.host fillAuthor];
    NSString* initials = details[@"initials"];
    if (!initials.length) {
        NSMutableString* derived = [NSMutableString string];
        for (NSString* word in [name componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (word.length) [derived appendString:[[word substringToIndex:1] uppercaseString]];
        initials = derived.length >= 2 ? derived : nil;
    }
    NSDateFormatter* formatter = [NSDateFormatter new];
    formatter.dateFormat = [NSDateFormatter dateFormatFromTemplate:@"yyyyMMMd" options:0 locale:NSLocale.currentLocale];
    NSString* today = [formatter stringFromDate:NSDate.date];
    NSString* email = details[@"email"];
    NSMutableArray<NSString*>* texts = [NSMutableArray array];
    for (NSString* text in @[ name ?: @"", initials ?: @"", today ?: @"", email ?: @"" ])
        if (text.length && ![texts containsObject:text]) [texts addObject:text];
    for (NSString* text in [[SPDFMacSignatureStore sharedStore] savedTexts])
        if (text.length && ![texts containsObject:text]) [texts addObject:text];
    // The label beside the box decides which one is likely: it is offered first and Return takes it.
    NSString* hint = label.lowercaseString ?: @"";
    NSString* likely = nil;
    if ([hint containsString:@"initial"]) likely = initials;
    else if ([hint containsString:@"date"] || [hint containsString:@"日期"]) likely = today;
    else if ([hint containsString:@"mail"] || [hint containsString:@"邮箱"]) likely = email;
    else if ([hint containsString:@"name"] || [hint containsString:@"姓名"] || [hint containsString:@"名字"]) likely = name;
    *highlighted = -1;
    if (likely.length && [texts containsObject:likely]) {
        [texts removeObject:likely];
        [texts insertObject:likely atIndex:0];
        *highlighted = 0;
    }
    NSMutableArray* suggestions = [NSMutableArray array];
    for (NSString* text in texts) [suggestions addObject:[SPDFMacFillSuggestion suggestionWithText:text]];
    return suggestions;
}

- (void)editMyDetails {
    SPDFMacSignatureStore* store = [SPDFMacSignatureStore sharedStore];
    NSDictionary* details = [store details];
    NSAlert* alert = [NSAlert new];
    alert.messageText = @"My Details";
    alert.informativeText = @"Offered when you fill in a name, initials, a date or an email.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 96)];
    NSArray* keys = @[ @"name", @"initials", @"email" ];
    NSArray* titles = @[ @"Full name", @"Initials", @"Email" ];
    NSMutableArray<NSTextField*>* fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSTextField* label = [NSTextField labelWithString:titles[i]];
        label.frame = NSMakeRect(0, 70 - i * 32, 80, 20);
        [box addSubview:label];
        NSTextField* field = [NSTextField textFieldWithString:details[keys[i]] ?: @""];
        if (i == 0 && !field.stringValue.length) field.placeholderString = [self.host fillAuthor];
        field.frame = NSMakeRect(84, 68 - i * 32, 216, 24);
        [box addSubview:field];
        [fields addObject:field];
    }
    alert.accessoryView = box;
    alert.window.initialFirstResponder = fields.firstObject;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSMutableDictionary* saved = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < keys.count; ++i) {
        NSString* value = [fields[i].stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (value.length) saved[keys[i]] = value;
    }
    [store setDetails:saved];
}

#pragma mark - Choices

- (void)showChoiceMenuForField:(SPDFFillField*)field {
    if (![self.host fillPrepareForChangeOfFieldsOnly:YES]) return;
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@""];
    for (NSString* option in field.options) {
        NSMenuItem* item = [menu addItemWithTitle:option.length ? option : @" " action:@selector(choiceChosen:)
                                    keyEquivalent:@""];
        item.target = self;
        item.representedObject = @{@"field" : field, @"value" : option};
        item.state = [option isEqual:field.value] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    if (field.flags & SPDF_FIELD_EDITABLE_COMBO) {
        if (menu.numberOfItems) [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem* other = [menu addItemWithTitle:@"Other…" action:@selector(choiceTyped:) keyEquivalent:@""];
        other.target = self;
        other.representedObject = field;
    }
    NSRect r = [self.overlay viewRectForPageRect:field.rect page:field.page];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(r), NSMaxY(r) + 2) inView:self.overlay];
}

- (void)choiceChosen:(NSMenuItem*)sender {
    NSDictionary* choice = sender.representedObject;
    [self setChoice:choice[@"value"] forField:choice[@"field"]];
}

- (void)choiceTyped:(NSMenuItem*)sender {
    SPDFFillField* field = sender.representedObject;
    SPDFMacFillEditor* editor = [self newEditor];
    editor.field = field;
    editor.page = field.page;
    editor.box = field.rect;
    editor.fontSize = field.fontSize > 0 ? field.fontSize : MAX(6.0, MIN(12.0, NSHeight(field.rect) * 0.65));
    [self beginEditor:editor text:field.value ?: @"" label:field.label];
}

#pragma mark - Signatures

- (NSRect)rectForSignature:(SPDFMacSignature*)signature inField:(NSRect)box {
    NSRect inner = NSInsetRect(box, 2, 2);
    CGFloat height = MIN(NSHeight(inner), NSWidth(inner) / MAX(0.1, signature.aspect));
    CGFloat width = height * signature.aspect;
    return NSMakeRect(NSMidX(inner) - width / 2, NSMidY(inner) - height / 2, width, height);
}

- (void)placeSignatureInField:(SPDFFillField*)field {
    SPDFMacSignature* last = [[SPDFMacSignatureStore sharedStore] lastUsedForInitials:NO];
    if (last) {
        [self addSignature:last page:field.page rect:[self rectForSignature:last inField:field.rect]];
        return;
    }
    __weak SPDFMacFillController* weakSelf = self;
    [SPDFMacSignatureSheet beginForWindow:[self.host fillWindow] initials:NO suggestedName:[self suggestedNameForInitials:NO]
                               completion:^(SPDFMacSignature* signature) {
                                 SPDFMacFillController* me = weakSelf;
                                 if (!signature || !me) return;
                                 [me addSignature:signature page:field.page
                                             rect:[me rectForSignature:signature inField:field.rect]];
                               }];
}

- (NSString*)suggestedNameForInitials:(BOOL)initials {
    NSInteger ignored;
    NSArray* suggestions = [self suggestionsForLabel:initials ? @"initials" : @"name" highlighted:&ignored];
    return ignored == 0 ? [suggestions.firstObject text] : @"";
}

- (void)pickUpSignature:(SPDFMacSignature*)signature {
    if (!signature) return;
    [self endInteraction];
    SPDFFillSession* session = [self session];
    session.tool = SPDFFillToolSignature;
    session.pickedSignature = signature;
    [self refreshChrome];
    [[self.host fillWindow] makeFirstResponder:self.overlay];
}

- (void)addSignatureWithInitials:(BOOL)initials {
    __weak SPDFMacFillController* weakSelf = self;
    [SPDFMacSignatureSheet beginForWindow:[self.host fillWindow] initials:initials
                            suggestedName:[self suggestedNameForInitials:initials]
                               completion:^(SPDFMacSignature* signature) {
                                 if (signature) [weakSelf pickUpSignature:signature];
                               }];
}

#pragma mark - Keyboard focus

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
    int next = index + (forward ? 1 : -1);
    if (next < 0 || next >= count) return;
    const spdf_snap_target& target = targets[(size_t)next];
    self.overlay.focusedField = nil;
    self.overlay.focusedTargetRect = SPDFFillRectFromCore(target.rect);
    self.overlay.focusedTargetPage = page;
    [self.overlay revealPageRect:self.overlay.focusedTargetRect page:page];
    if (target.kind != SPDF_SNAP_CHECKBOX) {
        spdf_snap_result snap;
        [self.overlay resolveAt:NSMakePoint(target.probe_x, target.probe_y) page:page purpose:SPDF_SNAP_FOR_TEXT aspect:1
                       snapping:YES result:&snap];
        [self openEditorForNewTextOnPage:page snap:&snap];
    }
    self.overlay.needsDisplay = YES;
}

@end
