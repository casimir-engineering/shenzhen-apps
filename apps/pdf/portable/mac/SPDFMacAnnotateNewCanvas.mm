// File > New Canvas's sheet (SPDFMacAnnotateIntegration.h; docs/plans/annotate.md § File > New Canvas): a search field
// over the list of sizes (spdf_paint_canvas_presets), as the app's other searchable lists work (type to narrow, ↑/↓ to
// move, Return to choose), then width and height in px, mm, cm or in, and the resolution. Return creates; the size,
// unit and resolution chosen are offered again next time.
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacAnnotateSession.h"
#import "SPDFMacCollectionStyle.h"

static NSString* const kSettingsKey = @"new_canvas";  // kept with the tools' settings (SPDFAnnotateSettings)

@interface SPDFAnnotateNewCanvasSheet : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                                  NSComboBoxDelegate>
@property(nonatomic, strong) NSPanel* panel;
@property(nonatomic, strong) NSSearchField* search;
@property(nonatomic, strong) NSTableView* table;
@property(nonatomic, strong) NSTextField* width;
@property(nonatomic, strong) NSTextField* height;
@property(nonatomic, strong) NSPopUpButton* unit;
@property(nonatomic, strong) NSComboBox* ppi;
@property(nonatomic, strong) NSTextField* note;  // what Create makes instead, when the size is too large
@property(nonatomic, copy) NSArray<NSValue*>* shown;  // the presets the search leaves (NULL pointer value: Custom)
@property(nonatomic) const spdf_paint_canvas_preset* preset;  // the size chosen, NULL for a custom one
@property(nonatomic) int orientation;
@property(nonatomic) double pixelWidth, pixelHeight, resolution;
@property(nonatomic) double paperResolution;  // a paper size's: the resolution, or lower when it had to be made smaller
@property(nonatomic, copy) void (^create)(NSInteger, NSInteger, double);
@end

static NSMutableSet* SPDFOpenNewCanvasSheets;  // keeps each sheet alive while it shows

static NSString* Number(double value) {
    return [NSString stringWithFormat:value == round(value) ? @"%.0f" : @"%.2f", value];
}

@implementation SPDFAnnotateNewCanvasSheet

#pragma mark - Units

- (BOOL)scaledPaper {
    return self.preset && self.preset->paper && self.paperResolution < self.resolution - 0.001;
}

- (double)pixelsPerUnit {  // px, mm, cm, in; a paper size made smaller is shown at its own lower resolution
    double ppi = [self scaledPaper] ? self.paperResolution : self.resolution;
    switch (self.unit.indexOfSelectedItem) {
        case 1: return ppi / 25.4;
        case 2: return ppi / 2.54;
        case 3: return ppi;
        default: return 1;
    }
}

- (void)showSize {
    double per = [self pixelsPerUnit];
    self.width.stringValue = Number(per == 1 ? self.pixelWidth : round(self.pixelWidth / per * 100) / 100);
    self.height.stringValue = Number(per == 1 ? self.pixelHeight : round(self.pixelHeight / per * 100) / 100);
    [self showNote];
}

// What Create makes: the size within the limits, both sides smaller by one factor when it is too large, at a
// resolution lowered by that factor so the printed size stays. YES when that is smaller than what is shown.
- (BOOL)createdWidth:(long*)width height:(long*)height ppi:(double*)ppi {
    double w = MAX(1, round(self.pixelWidth)), h = MAX(1, round(self.pixelHeight));
    double factor = spdf_paint_fit_size(&w, &h);
    *width = (long)w, *height = (long)h;
    *ppi = [self scaledPaper] ? self.paperResolution : self.resolution * factor;
    return factor < 1 || [self scaledPaper];
}

- (void)showNote {
    long w = 0, h = 0;
    double ppi = 0;
    BOOL smaller = [self createdWidth:&w height:&h ppi:&ppi];
    BOOL printed = (self.preset && self.preset->paper) || self.unit.indexOfSelectedItem > 0;
    self.note.stringValue = !smaller ? @""
                            : printed ? [NSString stringWithFormat:@"Too large for one canvas: Create makes it %ld × %ld px at "
                                                                   @"%.0f ppi, the same printed size.", w, h, ppi]
                                      : [NSString stringWithFormat:@"Too large for one canvas: Create makes it %ld × %ld px, "
                                                                   @"the same shape.", w, h];
    self.note.hidden = !smaller;
}

- (void)usePreset:(const spdf_paint_canvas_preset*)preset {
    self.preset = preset;
    if (!preset) return;
    int w = 0, h = 0;
    self.paperResolution = spdf_paint_canvas_preset_pixels(preset, self.resolution, self.orientation, &w, &h);
    self.pixelWidth = w;
    self.pixelHeight = h;
    [self showSize];
}

- (NSString*)detailFor:(const spdf_paint_canvas_preset*)preset {  // turned only for the size chosen
    int w = 0, h = 0;
    double ppi = spdf_paint_canvas_preset_pixels(preset, self.resolution,
                                                 preset == self.preset ? self.orientation : SPDF_PAINT_AS_LISTED, &w, &h);
    NSString* size = [NSString stringWithFormat:@"%d × %d px", w, h];
    if (!strcmp(preset->group, preset->label)) return size;
    if (!preset->paper) return [NSString stringWithFormat:@"%s · %@", preset->group, size];
    BOOL turned = (w > h) != (preset->width > preset->height);
    double a = turned ? preset->height : preset->width, b = turned ? preset->width : preset->height;
    return [NSString stringWithFormat:@"%s · %@ × %@ mm · %@ at %.0f ppi", preset->group, Number(a), Number(b), size, ppi];
}

#pragma mark - The list

- (void)filter {
    NSArray<NSString*>* words = [self.search.stringValue.lowercaseString
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray* shown = [NSMutableArray array];
    BOOL any = NO;
    for (NSString* word in words) any |= word.length > 0;
    size_t count = 0;
    const spdf_paint_canvas_preset* presets = spdf_paint_canvas_presets(&count);
    for (size_t i = 0; i < count; i++) {
        const spdf_paint_canvas_preset* p = &presets[i];
        int w = 0, h = 0;
        spdf_paint_canvas_preset_pixels(p, self.resolution, SPDF_PAINT_AS_LISTED, &w, &h);
        NSString* text = [NSString stringWithFormat:@"%s %s %s %s %d %d %dx%d %@x%@", p->name, p->label, p->group,
                                                    p->aliases, w, h, w, h, Number(p->width), Number(p->height)]
                             .lowercaseString;
        BOOL match = YES;
        for (NSString* word in words)
            if (word.length && ![text containsString:word]) match = NO;
        if (match) [shown addObject:[NSValue valueWithPointer:p]];
    }
    if (!any) [shown addObject:[NSValue valueWithPointer:NULL]];  // Custom, last, while nothing is typed
    self.shown = shown;
    [self.table reloadData];
    NSUInteger row = 0;
    for (NSUInteger i = 0; i < shown.count; i++)
        if ([shown[i] pointerValue] == self.preset) row = i;
    if (shown.count) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
        [self.table scrollRowToVisible:(NSInteger)row];
    }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)table {
    (void)table;
    return MAX((NSInteger)1, (NSInteger)self.shown.count);
}

- (NSView*)tableView:(NSTableView*)table viewForTableColumn:(NSTableColumn*)column row:(NSInteger)row {
    (void)table, (void)column;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.maximumNumberOfLines = 2;
    if (!self.shown.count) {
        label.stringValue = @"No size matches. Type the width and height below.";
        label.textColor = SPDFCollectionColor(@"secondary");
        return label;
    }
    const spdf_paint_canvas_preset* p = (const spdf_paint_canvas_preset*)[self.shown[(NSUInteger)row] pointerValue];
    NSString* name = p ? @(p->label) : @"Custom";
    NSString* detail = p ? [self detailFor:p] : @"The width and height typed below";
    NSMutableAttributedString* text = [[NSMutableAttributedString alloc]
        initWithString:name attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightMedium]}];
    [text appendAttributedString:[[NSAttributedString alloc]
                                     initWithString:[@"\n" stringByAppendingString:detail]
                                         attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:11],
                                                      NSForegroundColorAttributeName : SPDFCollectionColor(@"secondary")}]];
    label.attributedStringValue = text;
    return label;
}

- (void)tableViewSelectionDidChange:(NSNotification*)note {
    (void)note;
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row >= (NSInteger)self.shown.count) return;
    const spdf_paint_canvas_preset* p = (const spdf_paint_canvas_preset*)[self.shown[(NSUInteger)row] pointerValue];
    if (p && p != self.preset) self.orientation = SPDF_PAINT_AS_LISTED;  // another size comes as listed; ⇄ turns it
    if (p) [self usePreset:p];
    else self.preset = NULL;
    [self.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.shown.count)]
                          columnIndexes:[NSIndexSet indexSetWithIndex:0]];  // the old size's row goes back as listed
}

#pragma mark - Typing

- (void)controlTextDidChange:(NSNotification*)note {
    if (note.object == self.search) return [self filter];
    if (note.object == self.ppi) return [self resolutionChanged];
    [self becomeCustom];  // first: a paper size made smaller goes back to its size at the resolution shown
    double per = [self pixelsPerUnit];
    if (note.object == self.width) self.pixelWidth = round(self.width.doubleValue * per);
    if (note.object == self.height) self.pixelHeight = round(self.height.doubleValue * per);
    [self showNote];
}

- (void)comboBoxSelectionDidChange:(NSNotification*)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{ [self resolutionChanged]; });  // the field shows the item only now
}

// Paper is sized at the resolution; a size typed in mm, cm or in keeps its length; pixels stay pixels.
- (void)resolutionChanged {
    double old = self.resolution, ppi = self.ppi.doubleValue;
    if (ppi < 1 || ppi > 2400 || fabs(ppi - old) < 0.001) return;
    self.resolution = ppi;
    if (self.preset && self.preset->paper) [self usePreset:self.preset];
    else if (self.unit.indexOfSelectedItem > 0) {
        self.pixelWidth = round(self.pixelWidth / old * ppi);
        self.pixelHeight = round(self.pixelHeight / old * ppi);
    }
    [self.table reloadData];
    [self showNote];
}

- (void)becomeCustom {
    if (!self.preset) return;
    if ([self scaledPaper]) {
        self.pixelWidth = round(self.pixelWidth * self.resolution / self.paperResolution);
        self.pixelHeight = round(self.pixelHeight * self.resolution / self.paperResolution);
    }
    self.preset = NULL;
    [self filter];
}

- (void)unitChosen:(id)sender {
    (void)sender;
    [self showSize];
}

- (void)swap:(id)sender {
    (void)sender;
    double w = self.pixelWidth;
    self.pixelWidth = self.pixelHeight;
    self.pixelHeight = w;
    self.orientation = self.pixelWidth > self.pixelHeight ? SPDF_PAINT_LANDSCAPE : SPDF_PAINT_PORTRAIT;
    [self showSize];
    [self.table reloadData];
    [self filter];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
    (void)textView;
    if (command == @selector(insertNewline:)) {  // Return in any field creates (each keystroke was already taken)
        [self ok:nil];
        return YES;
    }
    if (control != self.search) return NO;
    if (command == @selector(moveDown:) || command == @selector(moveUp:)) {
        NSInteger row = self.table.selectedRow + (command == @selector(moveDown:) ? 1 : -1);
        row = MAX(0, MIN((NSInteger)self.shown.count - 1, row));
        if (self.shown.count) {
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
            [self.table scrollRowToVisible:row];
        }
        return YES;
    }
    if (command != @selector(cancelOperation:) || self.search.stringValue.length) return NO;  // it clears itself first
    [self cancel:nil];
    return YES;
    return NO;
}

#pragma mark - Building and closing

- (NSTextField*)field {
    NSTextField* field = [NSTextField textFieldWithString:@""];
    field.alignment = NSTextAlignmentRight;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintEqualToConstant:76].active = YES;
    return field;
}

- (void)build {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 470) styleMask:NSWindowStyleMaskTitled
                                          backing:NSBackingStoreBuffered defer:YES];
    _panel.title = @"New Canvas";
    _panel.autorecalculatesKeyViewLoop = YES;  // Tab goes search, list, width, height, unit, resolution
    NSTextField* heading = [NSTextField labelWithString:@"New Canvas"];
    heading.font = [NSFont boldSystemFontOfSize:13];
    _search = [NSSearchField new];
    _search.placeholderString = @"Search sizes: A4, letter, 1920, story, icon…";
    _search.delegate = self;
    _search.translatesAutoresizingMaskIntoConstraints = NO;
    _table = [NSTableView new];
    NSTableColumn* column = [[NSTableColumn alloc] initWithIdentifier:@"size"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    [_table addTableColumn:column];
    _table.headerView = nil;
    _table.rowHeight = 36;
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(ok:);
    _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    NSScrollView* scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = _table;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll.heightAnchor constraintEqualToConstant:240].active = YES;
    _width = [self field];
    _height = [self field];
    _unit = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [_unit addItemsWithTitles:@[ @"px", @"mm", @"cm", @"in" ]];
    _unit.target = self;
    _unit.action = @selector(unitChosen:);
    NSButton* swap = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.left.arrow.right"
                                                       accessibilityDescription:@"Swap width and height"]
                                        target:self action:@selector(swap:)];
    swap.toolTip = @"Portrait or landscape: swaps the width and the height";
    _ppi = [NSComboBox new];
    [_ppi addItemsWithObjectValues:@[ @72, @96, @150, @300, @600 ]];
    _ppi.delegate = self;
    _ppi.translatesAutoresizingMaskIntoConstraints = NO;
    [_ppi.widthAnchor constraintEqualToConstant:76].active = YES;
    _ppi.toolTip = @"Pixels per inch: the size paper is drawn at, and the resolution saved with the picture";
    NSStackView* size = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Width:"], _width,
                                                           [NSTextField labelWithString:@"Height:"], _height, _unit, swap ]];
    size.spacing = 6;
    NSStackView* resolution = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Resolution:"], _ppi,
                                                                 [NSTextField labelWithString:@"ppi"] ]];
    resolution.spacing = 6;
    _note = [NSTextField wrappingLabelWithString:@""];
    _note.textColor = SPDFCollectionColor(@"secondary");
    _note.font = [NSFont systemFontOfSize:11];
    _note.hidden = YES;
    _note.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton* ok = [NSButton buttonWithTitle:@"Create" target:self action:@selector(ok:)];
    ok.keyEquivalent = @"\r";
    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    NSStackView* buttons = [NSStackView new];
    [buttons setViews:@[ cancel, ok ] inGravity:NSStackViewGravityTrailing];
    NSStackView* stack = [NSStackView stackViewWithViews:@[ heading, _search, scroll, size, resolution, _note, buttons ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView* content = _panel.contentView;
    [content addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:content.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [_search.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
        [_note.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
        [content.widthAnchor constraintEqualToConstant:440],
    ]];
}

- (void)restore {
    NSDictionary* last = [SPDFAnnotateSettings.shared optionsForTool:kSettingsKey];
    double ppi = [last[@"ppi"] doubleValue];
    self.resolution = ppi >= 1 && ppi <= 2400 ? ppi : SPDF_PAINT_DEFAULT_PPI;
    self.ppi.stringValue = Number(self.resolution);
    NSInteger unit = [last[@"unit"] integerValue];
    [self.unit selectItemAtIndex:unit >= 0 && unit < 4 ? unit : 0];
    self.orientation = [last[@"orientation"] intValue];
    const spdf_paint_canvas_preset* preset = [last[@"preset"] isKindOfClass:NSString.class]
                                                 ? spdf_paint_canvas_preset_named([last[@"preset"] UTF8String]) : NULL;
    if (!last.count) preset = spdf_paint_canvas_preset_named("default");  // first time: 1000 x 1000 px
    double w = [last[@"width"] doubleValue], h = [last[@"height"] doubleValue];
    self.pixelWidth = w >= 1 ? w : SPDF_PAINT_DEFAULT_SIZE;
    self.pixelHeight = h >= 1 ? h : SPDF_PAINT_DEFAULT_SIZE;
    if (preset) [self usePreset:preset];
    else [self showSize];
    [self filter];
}

- (void)ok:(id)sender {
    (void)sender;
    [self.panel makeFirstResponder:nil];  // the field being typed in keeps its value
    long w = 0, h = 0;
    double ppi = self.resolution;
    [self createdWidth:&w height:&h ppi:&ppi];  // too large: smaller by one factor, at fewer ppi (the note said so)
    [SPDFAnnotateSettings.shared setOptions:@{@"width" : @(w), @"height" : @(h), @"ppi" : @(self.preset ? self.resolution : ppi),
                                              @"unit" : @(self.unit.indexOfSelectedItem), @"orientation" : @(self.orientation),
                                              @"preset" : self.preset ? @(self.preset->name) : @""}
                                    forTool:kSettingsKey];
    void (^create)(NSInteger, NSInteger, double) = self.create;
    [self close];
    if (create) create(w, h, ppi);
}

- (void)cancel:(id)sender {
    (void)sender;
    [self close];
}

- (void)close {
    if (self.panel.sheetParent) [self.panel.sheetParent endSheet:self.panel];
    else {
        [NSApp stopModal];
        [self.panel orderOut:nil];
    }
    [SPDFOpenNewCanvasSheets removeObject:self];
}

@end

// The resolution a canvas is made with, kept in the files saved from it.
NSDictionary* SPDFAnnotateResolutionProperties(NSDictionary* properties, double ppi) {
    NSMutableDictionary* out = [properties mutableCopy] ?: [NSMutableDictionary dictionary];
    if (ppi <= 0) return out;
    out[(NSString*)kCGImagePropertyDPIWidth] = out[(NSString*)kCGImagePropertyDPIHeight] = @(ppi);
    NSMutableDictionary* tiff = [out[(NSString*)kCGImagePropertyTIFFDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    tiff[(NSString*)kCGImagePropertyTIFFXResolution] = tiff[(NSString*)kCGImagePropertyTIFFYResolution] = @(ppi);
    tiff[(NSString*)kCGImagePropertyTIFFResolutionUnit] = @2;  // inches
    out[(NSString*)kCGImagePropertyTIFFDictionary] = tiff;
    NSMutableDictionary* jfif = [out[(NSString*)kCGImagePropertyJFIFDictionary] mutableCopy];
    if (jfif) {
        jfif[(NSString*)kCGImagePropertyJFIFXDensity] = jfif[(NSString*)kCGImagePropertyJFIFYDensity] = @(lround(ppi));
        jfif[(NSString*)kCGImagePropertyJFIFDensityUnit] = @1;
        out[(NSString*)kCGImagePropertyJFIFDictionary] = jfif;
    }
    return out;
}

void SPDFAnnotateShowNewCanvasSheet(NSWindow* window, void (^create)(NSInteger width, NSInteger height, double ppi)) {
    SPDFAnnotateNewCanvasSheet* sheet = [SPDFAnnotateNewCanvasSheet new];
    sheet.create = create;
    [sheet build];
    [sheet restore];
    if (!SPDFOpenNewCanvasSheets) SPDFOpenNewCanvasSheets = [NSMutableSet set];
    [SPDFOpenNewCanvasSheets addObject:sheet];
    sheet.panel.initialFirstResponder = sheet.search;
    [sheet.panel.contentView layoutSubtreeIfNeeded];
    [sheet.panel setContentSize:sheet.panel.contentView.fittingSize];
    if (window && !window.attachedSheet) [window beginSheet:sheet.panel completionHandler:nil];
    else [NSApp runModalForWindow:sheet.panel];
}
