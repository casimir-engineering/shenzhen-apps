// The Layers sidebar (SPDFMacAnnotateLayersPanel.h).
#import "SPDFMacAnnotateLayersPanel.h"

#import <objc/runtime.h>

#import "SPDFMacAnnotateIntegration.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillController.h"
#import "SPDFMacFillPalette.h"

static NSPasteboardType const kSPDFLayerRowType = @"com.intuition.shenzhenpdf.annotate.layer-row";

// One row: thumbnail over a checkerboard, name, brush badge or lock, eye, and the opacity slider while selected.
@interface SPDFAnnotateLayerRow : NSTableCellView
@property(nonatomic, strong) NSImageView* thumb;
@property(nonatomic, strong) NSTextField* name;
@property(nonatomic, strong) NSImageView* badge;
@property(nonatomic, strong) NSButton* eye;
@property(nonatomic, strong) NSSlider* opacity;
@property(nonatomic, strong) NSTextField* percent;
@end

@implementation SPDFAnnotateLayerRow
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect box = self.thumb.frame;  // the checkerboard shows where the thumbnail is transparent
    for (CGFloat y = 0; y < NSHeight(box); y += 6)
        for (CGFloat x = 0; x < NSWidth(box); x += 6) {
            BOOL dark = ((NSInteger)(x / 6) + (NSInteger)(y / 6)) % 2;
            [[NSColor colorWithWhite:dark ? 0.91 : 1 alpha:1] setFill];
            NSRectFill(NSIntersectionRect(box, NSMakeRect(NSMinX(box) + x, NSMinY(box) + y, 6, 6)));
        }
    [[NSColor.labelColor colorWithAlphaComponent:0.2] setStroke];
    NSFrameRect(box);
}
@end

@interface SPDFMacAnnotateLayersPanel () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SPDFMacAnnotateLayersPanel {
    __weak SPDFMacFillController* _controller;
    __weak SPDFMacAnnotateSession* _session;
    NSTableView* _table;
    NSScrollView* _scroll;
    NSArray<NSDictionary*>* _rows;  // front first
    NSMutableDictionary<NSNumber*, NSImage*>* _thumbs;
    uint64_t _thumbGeneration;
    NSNumber* _activeId;
    NSButton* _add;
    NSButton* _duplicate;
    NSButton* _merge;
    NSButton* _delete;
    NSLayoutConstraint* _height;
    NSLayoutConstraint* _top;
    BOOL _inSlot;  // in the minimap's place (the palette is not above it)
    BOOL _syncing;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _controller = controller;
        _thumbs = [NSMutableDictionary dictionary];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.wantsLayer = YES;
        self.shadow = [NSShadow new];
        self.layer.shadowOpacity = 0.18;
        self.layer.shadowRadius = 8;
        [self build];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)mouseDown:(NSEvent*)event { (void)event; }  // clicks between rows and buttons stay on the panel
- (CGFloat)preferredWidth { return 236; }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
    [SPDFCollectionColor(@"popover") setFill];
    [shape fill];
    [SPDFCollectionColor(@"lineStrong") setStroke];
    [shape stroke];
}

- (NSButton*)button:(NSString*)symbol label:(NSString*)label action:(SEL)action {
    NSButton* button = SPDFCollectionButton(@"", self, action, @"quiet");
    button.image = SPDFAnnotateSymbol(symbol, label);
    if (!button.image) button.title = label;
    button.toolTip = label;
    button.accessibilityLabel = label;
    button.refusesFirstResponder = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintEqualToConstant:26].active = YES;
    [button.widthAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    return button;
}

- (void)build {
    NSTextField* title = SPDFCollectionText(@"Layers", 12, NSFontWeightSemibold, NO);
    _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"layer"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.dataSource = self;
    _table.delegate = self;
    _table.backgroundColor = NSColor.clearColor;
    _table.intercellSpacing = NSMakeSize(0, 2);
    _table.refusesFirstResponder = YES;  // the canvas keeps the keys
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    [_table registerForDraggedTypes:@[ kSPDFLayerRowType ]];
    [_table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scroll.documentView = _table;
    _scroll.drawsBackground = NO;
    _scroll.hasVerticalScroller = YES;
    _scroll.autohidesScrollers = YES;
    _add = [self button:@"plus.square" label:@"New Layer" action:@selector(addLayer:)];
    _duplicate = [self button:@"square.on.square" label:@"Duplicate" action:@selector(duplicateLayer:)];
    _merge = [self button:@"arrow.down.to.line" label:@"Merge Down" action:@selector(mergeDown:)];
    _delete = [self button:@"trash" label:@"Delete" action:@selector(deleteLayer:)];
    NSStackView* buttons = [NSStackView stackViewWithViews:@[ _add, _duplicate, _merge, _delete ]];
    buttons.distribution = NSStackViewDistributionFillEqually;
    for (NSView* v in @[ title, _scroll, buttons ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
    }
    _height = [_scroll.heightAnchor constraintEqualToConstant:60];
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:6],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-6], _height,
        [buttons.topAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:6],
        [buttons.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [buttons.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        [self.bottomAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:8],
        [self.widthAnchor constraintEqualToConstant:self.preferredWidth],
    ]];
}

- (void)attachToContainer:(NSView*)container {
    if (self.superview && self.superview == (_inSlot ? container.window.contentView : container)) return;
    [self removeFromSuperview];
    if (!container) return;
    [container addSubview:self positioned:NSWindowAbove relativeTo:nil];
    NSView* area = [_controller.host fillScrollView] ?: container;
    NSView* palette = _controller.palette.superview == container ? _controller.palette : nil;
    // In the minimap's place beside the pages (the reader gives it the slot), else floating over their right side.
    id host = _controller.host;
    NSView* slot = [host respondsToSelector:@selector(annotateLayersSlot)] ? [host annotateLayersSlot] : nil;
    if (slot.window == container.window && slot) {
        [container.window.contentView addSubview:self positioned:NSWindowAbove relativeTo:nil];
        [NSLayoutConstraint activateConstraints:@[
            [self.trailingAnchor constraintEqualToAnchor:slot.trailingAnchor constant:-8],
            _top = [self.topAnchor constraintEqualToAnchor:slot.topAnchor constant:8],
            [self.bottomAnchor constraintLessThanOrEqualToAnchor:slot.bottomAnchor constant:-8],
        ]];
        _inSlot = YES;
        _height.priority = NSLayoutPriorityDefaultHigh;
        return;
    }
    _inSlot = NO;
    NSLayoutConstraint* fits = [self.bottomAnchor constraintLessThanOrEqualToAnchor:area.bottomAnchor constant:-10];
    [NSLayoutConstraint activateConstraints:@[
        [self.trailingAnchor constraintEqualToAnchor:area.trailingAnchor constant:-10],
        // Below the palette's reserved room, so it stays put when the palette's second row comes and goes.
        _top = [self.topAnchor constraintEqualToAnchor:area.topAnchor constant:10 + (palette ? [_controller.palette reservedHeight] + 8 : 0)],
        fits,
    ]];
    _height.priority = NSLayoutPriorityDefaultHigh;  // a long list scrolls inside the panel
}

- (void)detach {
    [self removeFromSuperview];
}

#pragma mark - Reading doc.state

static NSDictionary* SPDFLayerRowFrom(NSDictionary* layer) {
    if (![layer isKindOfClass:[NSDictionary class]] || ![layer[@"id"] isKindOfClass:[NSNumber class]]) return nil;
    NSString* kind = [layer[@"kind"] isKindOfClass:[NSString class]] ? layer[@"kind"] : @"raster";
    double opacity = [layer[@"opacity"] respondsToSelector:@selector(doubleValue)] ? [layer[@"opacity"] doubleValue] : 100;
    return @{
        @"id" : layer[@"id"], @"kind" : kind,
        @"name" : [layer[@"name"] isKindOfClass:[NSString class]] ? layer[@"name"] : @"",
        @"visible" : @(layer[@"visible"] ? [layer[@"visible"] boolValue] : YES),
        @"opacity" : @(opacity),
        @"locked" : @([layer[@"locked"] boolValue]),
        @"object" : @(![kind isEqual:@"background"] && ![kind isEqual:@"raster"]),
    };
}

- (void)reloadFromSession:(SPDFMacAnnotateSession*)session {
    _session = session;
    if (_controller.palette.superview && !_inSlot) _top.constant = 10 + [_controller.palette reservedHeight] + 8;
    NSDictionary* state = session ? SPDFAnnotateDocState(_controller) : nil;
    NSMutableArray* rows = [NSMutableArray array];
    for (id layer in [[state[@"layers"] isKindOfClass:[NSArray class]] ? state[@"layers"] : @[] reverseObjectEnumerator]) {
        NSDictionary* row = SPDFLayerRowFrom(layer);
        if (row) [rows addObject:row];
    }
    id active = state[@"active"] ?: state[@"activeLayer"];
    _activeId = [active isKindOfClass:[NSNumber class]] ? active : nil;
    if (![rows isEqual:_rows]) {
        _rows = rows;
        _syncing = YES;
        [_table reloadData];
        _syncing = NO;
    }
    [self selectRowsFor:state];
    [self scheduleThumbnails];
}

- (void)selectRowsFor:(NSDictionary*)state {
    NSArray* selected = SPDFAnnotateSelectedObjectIds(state);
    NSMutableIndexSet* rows = [NSMutableIndexSet indexSet];
    [_rows enumerateObjectsUsingBlock:^(NSDictionary* row, NSUInteger i, BOOL* stop) {
      (void)stop;
      if ([selected containsObject:row[@"id"]] || (!selected.count && [row[@"id"] isEqual:self->_activeId])) [rows addIndex:i];
    }];
    _syncing = YES;
    [_table selectRowIndexes:rows byExtendingSelection:NO];
    _syncing = NO;
    [self updateButtons];
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) [self configure:[_table viewAtColumn:0 row:i makeIfNecessary:NO] row:i];
    [_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _rows.count)]];
    [self fitHeight];
}

// As tall as its rows (a selected row is taller: its opacity slider), up to 360 pt; more rows scroll.
- (void)fitHeight {
    CGFloat height = 4;
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) height += [self tableView:_table heightOfRow:i] + 2;
    _height.constant = MIN(360, MAX(48, height));
}

- (void)selectionDidChange {
    [self selectRowsFor:SPDFAnnotateDocState(_controller)];
}

#pragma mark - Thumbnails

- (spdf_paint_doc*)canvas {
    SPDFMacAnnotateSession* session = _session;
    if (!session) return NULL;
    if (session.kind != SPDFAnnotateDocumentPDF) return session.canvas;
    // The page the rows were read from (SPDFAnnotateOnCurrentPage): the page last touched, else the first.
    return [session canvasForPage:MAX(0, session.currentPage) document:[_controller.host fillDocument] create:YES];
}

- (void)scheduleThumbnails {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(drawThumbnails) object:nil];
    [self performSelector:@selector(drawThumbnails) withObject:nil afterDelay:0.3];
}

static NSImage* SPDFImageFromBitmap(const spdf_bitmap* b) {
    if (!b->rgba || b->width <= 0 || b->height <= 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(b->rgba, (size_t)b->width, (size_t)b->height, 8, (size_t)b->stride, space,
                                            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef image = cg ? CGBitmapContextCreateImage(cg) : NULL;
    NSImage* result = image ? [[NSImage alloc] initWithCGImage:image size:NSMakeSize(b->width / 2.0, b->height / 2.0)] : nil;
    if (image) CGImageRelease(image);
    if (cg) CGContextRelease(cg);
    CGColorSpaceRelease(space);
    return result;
}

- (void)drawThumbnails {
    spdf_paint_doc* doc = [self canvas];
    if (!doc || !self.superview) return;
    uint64_t generation = spdf_paint_generation(doc);
    if (generation == _thumbGeneration && _thumbs.count) return;
    _thumbGeneration = generation;
    [_thumbs removeAllObjects];
    for (NSDictionary* row in _rows) {
        spdf_bitmap bitmap = {0};
        char err[128];
        if (spdf_paint_layer_thumbnail(doc, (spdf_paint_id)[row[@"id"] unsignedIntValue], 72, &bitmap, err, sizeof(err)) ==
            SPDF_PAINT_OK) {
            NSImage* image = SPDFImageFromBitmap(&bitmap);
            if (image) _thumbs[row[@"id"]] = image;
        }
        spdf_free_bitmap(&bitmap);
    }
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) [self configure:[_table viewAtColumn:0 row:i makeIfNecessary:NO] row:i];
}

#pragma mark - Rows

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tableView {
    (void)tableView;
    return (NSInteger)_rows.count;
}

- (CGFloat)tableView:(NSTableView*)tableView heightOfRow:(NSInteger)row {
    NSDictionary* r = row < (NSInteger)_rows.count ? _rows[row] : nil;
    BOOL slider = [tableView.selectedRowIndexes containsIndex:(NSUInteger)row] && ![r[@"locked"] boolValue];
    return slider ? 66 : 44;
}

- (SPDFAnnotateLayerRow*)makeRow {
    SPDFAnnotateLayerRow* cell = [[SPDFAnnotateLayerRow alloc] initWithFrame:NSZeroRect];
    cell.identifier = @"layer";
    cell.thumb = [NSImageView imageViewWithImage:[NSImage new]];
    cell.thumb.imageScaling = NSImageScaleProportionallyDown;
    cell.name = SPDFCollectionText(@"", 12, NSFontWeightRegular, NO);
    cell.name.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.badge = [NSImageView imageViewWithImage:[NSImage new]];
    cell.badge.contentTintColor = NSColor.secondaryLabelColor;
    cell.eye = [NSButton buttonWithImage:SPDFAnnotateSymbol(@"eye", @"Hide") ?: [NSImage new] target:self
                                  action:@selector(toggleVisible:)];
    cell.eye.bordered = NO;
    cell.eye.refusesFirstResponder = YES;
    cell.opacity = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(opacityChanged:)];
    cell.opacity.continuous = NO;  // one change, written when the slider is let go
    cell.opacity.controlSize = NSControlSizeSmall;
    cell.opacity.toolTip = @"Opacity";
    cell.percent = SPDFCollectionText(@"", 10, NSFontWeightRegular, YES);
    for (NSView* v in @[ cell.thumb, cell.name, cell.badge, cell.eye, cell.opacity, cell.percent ]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [cell.thumb.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [cell.thumb.topAnchor constraintEqualToAnchor:cell.topAnchor constant:4],
        [cell.thumb.widthAnchor constraintEqualToConstant:36], [cell.thumb.heightAnchor constraintEqualToConstant:36],
        [cell.name.leadingAnchor constraintEqualToAnchor:cell.thumb.trailingAnchor constant:8],
        [cell.name.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.badge.leadingAnchor constraintEqualToAnchor:cell.name.trailingAnchor constant:4],
        [cell.badge.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.badge.widthAnchor constraintEqualToConstant:14],
        [cell.eye.leadingAnchor constraintGreaterThanOrEqualToAnchor:cell.badge.trailingAnchor constant:4],
        [cell.eye.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
        [cell.eye.centerYAnchor constraintEqualToAnchor:cell.thumb.centerYAnchor],
        [cell.eye.widthAnchor constraintEqualToConstant:24],
        [cell.opacity.leadingAnchor constraintEqualToAnchor:cell.name.leadingAnchor],
        [cell.opacity.topAnchor constraintEqualToAnchor:cell.thumb.bottomAnchor constant:2],
        [cell.percent.leadingAnchor constraintEqualToAnchor:cell.opacity.trailingAnchor constant:6],
        [cell.percent.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [cell.percent.centerYAnchor constraintEqualToAnchor:cell.opacity.centerYAnchor],
        [cell.percent.widthAnchor constraintEqualToConstant:34],
    ]];
    [cell.name setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    return cell;
}

- (void)configure:(SPDFAnnotateLayerRow*)cell row:(NSInteger)row {
    if (![cell isKindOfClass:[SPDFAnnotateLayerRow class]] || row >= (NSInteger)_rows.count) return;
    NSDictionary* r = _rows[row];
    BOOL locked = [r[@"locked"] boolValue], visible = [r[@"visible"] boolValue];
    BOOL selected = [_table.selectedRowIndexes containsIndex:(NSUInteger)row];
    cell.name.stringValue = r[@"name"];
    cell.name.textColor = visible ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    cell.thumb.image = _thumbs[r[@"id"]];
    BOOL active = [r[@"id"] isEqual:_activeId] && ![r[@"object"] boolValue];
    cell.badge.image = locked ? SPDFAnnotateSymbol(@"lock.fill", @"Locked")
                              : active ? SPDFAnnotateSymbol(@"paintbrush.pointed.fill", @"Pixel tools paint here") : nil;
    cell.badge.toolTip = locked ? SPDFAnnotatePageLockedText : active ? @"Pixel tools paint here" : nil;
    cell.eye.hidden = locked;
    cell.eye.image = SPDFAnnotateSymbol(visible ? @"eye" : @"eye.slash", visible ? @"Hide" : @"Show");
    cell.eye.toolTip = visible ? @"Hide" : @"Show";
    cell.eye.tag = row;
    cell.opacity.hidden = cell.percent.hidden = locked || !selected;
    cell.opacity.doubleValue = [r[@"opacity"] doubleValue];
    cell.opacity.tag = row;
    cell.percent.stringValue = [NSString stringWithFormat:@"%.0f %%", [r[@"opacity"] doubleValue]];
    cell.needsDisplay = YES;
}

- (NSView*)tableView:(NSTableView*)tableView viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)column;
    SPDFAnnotateLayerRow* cell = [tableView makeViewWithIdentifier:@"layer" owner:self] ?: [self makeRow];
    [self configure:cell row:row];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification*)note {
    (void)note;
    [_table noteHeightOfRowsWithIndexesChanged:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _rows.count)]];
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i) [self configure:[_table viewAtColumn:0 row:i makeIfNecessary:NO] row:i];
    [self updateButtons];
    [self fitHeight];
    if (_syncing || _table.selectedRow < 0) return;
    NSDictionary* row = _rows[(NSUInteger)_table.selectedRow];
    if (![row[@"locked"] boolValue]) SPDFAnnotateSend(_controller, SPDFAnnotateOnCurrentPage(_controller, @{@"op" : @"layer.activate", @"id" : row[@"id"]}), nil);
}

- (NSDictionary*)selectedRow {
    NSInteger i = _table.selectedRow;
    return i >= 0 && i < (NSInteger)_rows.count ? _rows[i] : nil;
}

- (void)updateButtons {
    NSDictionary* row = [self selectedRow];
    BOOL editable = row && ![row[@"locked"] boolValue] && ![row[@"kind"] isEqual:@"background"];
    BOOL bottom = row && _table.selectedRow >= (NSInteger)_rows.count - 1;
    _add.enabled = _session != nil;
    _duplicate.enabled = editable || (row && ![row[@"locked"] boolValue]);
    _merge.enabled = editable && !bottom && ![_rows[MIN(_rows.count - 1, (NSUInteger)_table.selectedRow + 1)][@"locked"] boolValue];
    _delete.enabled = editable;
    _merge.toolTip = _merge.enabled || !row ? @"Merge Down" : @"Merge Down: there is no layer below it that can change";
}

#pragma mark - Actions

- (void)send:(NSDictionary*)op {
    SPDFAnnotateSend(_controller, SPDFAnnotateOnCurrentPage(_controller, op), nil);
}

- (void)toggleVisible:(NSButton*)sender {
    if (sender.tag >= (NSInteger)_rows.count) return;
    NSDictionary* row = _rows[sender.tag];
    [self send:@{@"op" : @"layer.set", @"id" : row[@"id"], @"visible" : @(![row[@"visible"] boolValue])}];
}

- (void)opacityChanged:(NSSlider*)sender {
    if (sender.tag >= (NSInteger)_rows.count) return;
    [self send:@{@"op" : @"layer.set", @"id" : _rows[sender.tag][@"id"], @"opacity" : @(lround(sender.doubleValue))}];
}

- (void)addLayer:(id)sender {
    (void)sender;
    NSDictionary* row = [self selectedRow];
    [self send:row && ![row[@"object"] boolValue] ? @{@"op" : @"layer.add", @"above" : row[@"id"]} : @{@"op" : @"layer.add"}];
}

- (void)duplicateLayer:(id)sender {
    (void)sender;
    NSDictionary* row = [self selectedRow];
    if (row) [self send:@{@"op" : [row[@"object"] boolValue] ? @"object.duplicate" : @"layer.duplicate", @"id" : row[@"id"]}];
}

- (void)mergeDown:(id)sender {
    (void)sender;
    NSDictionary* row = [self selectedRow];
    if (row) [self send:@{@"op" : [row[@"object"] boolValue] ? @"object.merge_down" : @"layer.merge_down", @"id" : row[@"id"]}];
}

- (void)deleteLayer:(id)sender {
    (void)sender;
    NSDictionary* row = [self selectedRow];
    if (row) [self send:@{@"op" : [row[@"object"] boolValue] ? @"object.delete" : @"layer.delete", @"id" : row[@"id"]}];
}

#pragma mark - Dragging rows (depth)

- (id<NSPasteboardWriting>)tableView:(NSTableView*)tableView pasteboardWriterForRow:(NSInteger)row {
    (void)tableView;
    if (row >= (NSInteger)_rows.count || [_rows[row][@"locked"] boolValue] || [_rows[row][@"kind"] isEqual:@"background"])
        return nil;
    NSPasteboardItem* item = [NSPasteboardItem new];
    [item setString:[NSString stringWithFormat:@"%ld", (long)row] forType:kSPDFLayerRowType];
    return item;
}

- (NSDragOperation)tableView:(NSTableView*)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)operation {
    (void)info;
    if (operation == NSTableViewDropOn) [tableView setDropRow:row dropOperation:NSTableViewDropAbove];
    BOOL background = _rows.count && [_rows.lastObject[@"kind"] isEqual:@"background"];
    return row > (NSInteger)_rows.count - (background ? 1 : 0) ? NSDragOperationNone : NSDragOperationMove;  // never under it
}

- (BOOL)tableView:(NSTableView*)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)operation {
    (void)tableView; (void)operation;
    NSInteger from = [[info.draggingPasteboard stringForType:kSPDFLayerRowType] integerValue];
    if (from < 0 || from >= (NSInteger)_rows.count) return NO;
    NSInteger to = from < row ? row - 1 : row;  // front-first index once the row is taken out
    if (to == from) return NO;
    BOOL background = [_rows.lastObject[@"kind"] isEqual:@"background"];
    // depth counts from the bottom, 0 = just above the Background
    NSInteger depth = MAX(0, (NSInteger)_rows.count - 1 - to - (background ? 1 : 0));
    NSDictionary* moved = _rows[from];
    [self send:@{@"op" : [moved[@"object"] boolValue] ? @"object.order" : @"layer.order", @"id" : moved[@"id"], @"to" : @(depth)}];
    return YES;
}

@end
