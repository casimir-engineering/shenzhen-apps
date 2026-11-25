// Annotate's sheets and questions (SPDFMacAnnotateIntegration.h, "Sheets and questions"; docs/plans/annotate.md § 2
// Image group, § Decisions Text documents and Saving a canvas). Each sheet sends its operations on OK, through
// -[SPDFMacFillController applyOperation:tab:completion:]; Cancel sends nothing.
#import "SPDFMacAnnotateIntegration.h"

#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController.h"

// A small sheet: a title, a grid of rows, OK and Cancel. OK runs `done` before the sheet closes.
@interface SPDFAnnotateSheet : NSObject <NSTextFieldDelegate>
@property(nonatomic, strong) NSPanel* panel;
@property(nonatomic, strong) NSGridView* grid;
@property(nonatomic, copy) void (^done)(void);
@property(nonatomic, copy) void (^changed)(NSControl* control);
@end

static NSMutableSet* SPDFOpenSheets;  // keeps each sheet alive while it shows

@implementation SPDFAnnotateSheet

- (instancetype)initWithTitle:(NSString*)title {
    if ((self = [super init])) {
        _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 200) styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered defer:YES];
        _panel.title = title;
        _grid = [NSGridView gridViewWithViews:@[]];
        _grid.rowSpacing = 8;
        _grid.columnSpacing = 8;
        _grid.translatesAutoresizingMaskIntoConstraints = NO;
        NSTextField* heading = [NSTextField labelWithString:title];
        heading.font = [NSFont boldSystemFontOfSize:13];
        NSButton* ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)];
        ok.keyEquivalent = @"\r";
        NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
        cancel.keyEquivalent = @"\033";
        NSStackView* buttons = [NSStackView new];
        [buttons setViews:@[ cancel, ok ] inGravity:NSStackViewGravityTrailing];
        NSStackView* column = [NSStackView stackViewWithViews:@[ heading, _grid, buttons ]];
        column.orientation = NSUserInterfaceLayoutOrientationVertical;
        column.alignment = NSLayoutAttributeLeading;
        column.spacing = 14;
        column.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20);
        column.translatesAutoresizingMaskIntoConstraints = NO;
        [column setCustomSpacing:18 afterView:_grid];
        NSView* content = _panel.contentView;
        [content addSubview:column];
        [NSLayoutConstraint activateConstraints:@[
            [column.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
            [column.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
            [column.topAnchor constraintEqualToAnchor:content.topAnchor],
            [column.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
            [buttons.widthAnchor constraintEqualToAnchor:column.widthAnchor constant:-40],
            [content.widthAnchor constraintGreaterThanOrEqualToConstant:360],
        ]];
    }
    return self;
}

- (NSTextField*)number:(double)value {
    NSTextField* field = [NSTextField textFieldWithString:[NSString stringWithFormat:@"%g", value]];
    NSNumberFormatter* format = [NSNumberFormatter new];
    format.numberStyle = NSNumberFormatterDecimalStyle;
    format.maximumFractionDigits = 2;
    format.usesGroupingSeparator = NO;  // 1000, as typed, in every field alike
    field.formatter = format;
    field.alignment = NSTextAlignmentRight;
    field.delegate = self;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field.widthAnchor constraintEqualToConstant:80].active = YES;
    return field;
}

- (void)row:(NSString*)label views:(NSArray<NSView*>*)views {
    NSMutableArray* cells = [NSMutableArray arrayWithObject:label ? [NSTextField labelWithString:label] : [NSGridCell emptyContentView]];
    NSStackView* stack = [NSStackView stackViewWithViews:views];
    stack.spacing = 6;
    [cells addObject:stack];
    NSGridRow* row = [_grid addRowWithViews:cells];
    [row cellAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    row.rowAlignment = NSGridRowAlignmentFirstBaseline;
}

- (void)controlTextDidChange:(NSNotification*)note {
    if (self.changed) self.changed(note.object);
}

- (void)control:(id)sender {
    if (self.changed) self.changed(sender);
}

- (void)showOn:(NSWindow*)window {
    if (!SPDFOpenSheets) SPDFOpenSheets = [NSMutableSet set];
    [SPDFOpenSheets addObject:self];
    if (window) [window beginSheet:_panel completionHandler:^(NSModalResponse r) { (void)r; [SPDFOpenSheets removeObject:self]; }];
    else [NSApp runModalForWindow:_panel];
}

- (void)close {
    if (_panel.sheetParent) [_panel.sheetParent endSheet:_panel];
    else {
        [NSApp stopModal];
        [_panel orderOut:nil];
        [SPDFOpenSheets removeObject:self];
    }
}

- (void)ok:(id)sender {
    (void)sender;
    [_panel makeFirstResponder:nil];  // the field being typed in keeps its value
    if (self.done) self.done();
    [self close];
}

- (void)cancel:(id)sender {
    (void)sender;
    [self close];
}

@end

#pragma mark - Resize and skew

// The size the Image commands act on: the selection's or selected object's box, else the canvas.
static NSSize SPDFAnnotateScopeSize(NSDictionary* state) {
    NSDictionary* selection = [state[@"selection"] isKindOfClass:[NSDictionary class]] ? state[@"selection"] : nil;
    NSDictionary* box = [selection[@"bounds"] isKindOfClass:[NSDictionary class]] ? selection[@"bounds"] : nil;
    if (box && [box[@"w"] doubleValue] > 0) return NSMakeSize([box[@"w"] doubleValue], [box[@"h"] doubleValue]);
    return NSMakeSize(MAX(1, [state[@"width"] doubleValue]), MAX(1, [state[@"height"] doubleValue]));
}

void SPDFAnnotateShowResizeSheet(NSWindow* window, SPDFMacFillController* controller) {
    NSDictionary* state = SPDFAnnotateDocState(controller) ?: @{};
    NSSize size = SPDFAnnotateScopeSize(state);
    BOOL pdf = SPDFAnnotateCurrentKind(controller) == SPDFAnnotateDocumentPDF;
    SPDFAnnotateSheet* sheet = [[SPDFAnnotateSheet alloc] initWithTitle:@"Resize and skew"];
    NSSegmentedControl* by = [NSSegmentedControl segmentedControlWithLabels:@[ @"Percentage", pdf ? @"Points" : @"Pixels" ]
                                                               trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                     target:sheet action:@selector(control:)];
    by.selectedSegment = 0;
    NSTextField* horizontal = [sheet number:100];
    NSTextField* vertical = [sheet number:100];
    NSButton* keep = [NSButton checkboxWithTitle:@"Maintain aspect ratio" target:sheet action:@selector(control:)];
    keep.state = NSControlStateValueOn;
    NSTextField* skewH = [sheet number:0];
    NSTextField* skewV = [sheet number:0];
    [sheet row:@"Resize by:" views:@[ by ]];
    [sheet row:@"Horizontal:" views:@[ horizontal ]];
    [sheet row:@"Vertical:" views:@[ vertical ]];
    [sheet row:nil views:@[ keep ]];
    [sheet row:@"Skew horizontal:" views:@[ skewH, [NSTextField labelWithString:@"degrees"] ]];
    [sheet row:@"Skew vertical:" views:@[ skewV, [NSTextField labelWithString:@"degrees"] ]];
    __block NSInteger mode = 0;
    sheet.changed = ^(NSControl* control) {
      BOOL ratio = keep.state == NSControlStateValueOn;
      if (control == by && by.selectedSegment != mode) {  // the same size, in the other unit
          mode = by.selectedSegment;
          double h = horizontal.doubleValue, v = vertical.doubleValue;
          horizontal.doubleValue = mode ? round(size.width * h / 100) : round(h / size.width * 1000) / 10;
          vertical.doubleValue = mode ? round(size.height * v / 100) : round(v / size.height * 1000) / 10;
      } else if (ratio && (control == horizontal || control == keep)) {
          vertical.doubleValue = mode ? round(horizontal.doubleValue * size.height / size.width) : horizontal.doubleValue;
      } else if (ratio && control == vertical) {
          horizontal.doubleValue = mode ? round(vertical.doubleValue * size.width / size.height) : vertical.doubleValue;
      }
    };
    sheet.done = ^{
      NSMutableArray* ops = [NSMutableArray array];
      double h = horizontal.doubleValue, v = vertical.doubleValue;
      BOOL ratio = keep.state == NSControlStateValueOn;
      if (by.selectedSegment == 0 && (h != 100 || v != 100)) {
          if (ratio || h == v) [ops addObject:@{@"op" : @"image.resize", @"percent" : @(MIN(1000, MAX(1, h))), @"scope" : @"auto"}];
          else [ops addObject:@{@"op" : @"image.resize", @"width" : @(MAX(1, lround(size.width * h / 100))),
                                @"height" : @(MAX(1, lround(size.height * v / 100))), @"keepRatio" : @NO, @"scope" : @"auto"}];
      } else if (by.selectedSegment == 1 && (lround(h) != lround(size.width) || lround(v) != lround(size.height))) {
          [ops addObject:@{@"op" : @"image.resize", @"width" : @(MAX(1, lround(h))), @"height" : @(MAX(1, lround(v))),
                           @"keepRatio" : @(ratio), @"scope" : @"auto"}];
      }
      double sh = MIN(89, MAX(-89, skewH.doubleValue)), sv = MIN(89, MAX(-89, skewV.doubleValue));
      if (sh != 0 || sv != 0) [ops addObject:@{@"op" : @"image.skew", @"horizontal" : @(sh), @"vertical" : @(sv), @"scope" : @"auto"}];
      if (ops.count) SPDFAnnotatePerform(controller, ops);
    };
    [sheet showOn:window];
}

#pragma mark - Canvas size and properties

void SPDFAnnotateShowCanvasPropertiesSheet(NSWindow* window, SPDFMacFillController* controller) {
    if (SPDFAnnotateCurrentKind(controller) == SPDFAnnotateDocumentPDF) return;  // the page size can't change
    NSDictionary* state = SPDFAnnotateDocState(controller) ?: @{};
    double width0 = MAX(1, [state[@"width"] doubleValue]), height0 = MAX(1, [state[@"height"] doubleValue]);
    double dpi0 = [state[@"dpi"] doubleValue] > 0 ? [state[@"dpi"] doubleValue] : 72;
    SPDFAnnotateSheet* sheet = [[SPDFAnnotateSheet alloc] initWithTitle:@"Canvas size and properties"];
    NSTextField* width = [sheet number:width0];
    NSTextField* height = [sheet number:height0];
    NSPopUpButton* units = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [units addItemsWithTitles:@[ @"pixels", @"inches", @"cm" ]];
    units.target = sheet;
    units.action = @selector(control:);
    NSTextField* dpi = [sheet number:dpi0];
    NSButton* transparent = [NSButton checkboxWithTitle:@"Transparent" target:sheet action:@selector(control:)];
    transparent.state = NSControlStateValueOn;
    transparent.toolTip = @"Off: new area is filled with Color 2";
    NSButton* mono = [NSButton checkboxWithTitle:@"Black and white" target:sheet action:@selector(control:)];
    mono.toolTip = @"Turns the picture black and white when you click OK";
    // Anchor: where the picture stays when the canvas grows or shrinks.
    NSArray* anchors = @[ @"top-left", @"top", @"top-right", @"left", @"center", @"right", @"bottom-left", @"bottom", @"bottom-right" ];
    NSMutableArray<NSButton*>* anchorButtons = [NSMutableArray array];
    NSGridView* anchorGrid = [NSGridView gridViewWithNumberOfColumns:3 rows:3];
    anchorGrid.rowSpacing = anchorGrid.columnSpacing = 2;
    for (NSInteger i = 0; i < 9; ++i) {
        NSButton* b = [NSButton radioButtonWithTitle:@"" target:sheet action:@selector(control:)];
        b.toolTip = [anchors[i] stringByReplacingOccurrencesOfString:@"-" withString:@" "];
        b.tag = i;
        b.state = i == 0 ? NSControlStateValueOn : NSControlStateValueOff;
        [anchorGrid cellAtColumnIndex:i % 3 rowIndex:i / 3].contentView = b;
        [anchorButtons addObject:b];
    }
    [sheet row:@"Width:" views:@[ width, units ]];
    [sheet row:@"Height:" views:@[ height ]];
    [sheet row:@"Resolution:" views:@[ dpi, [NSTextField labelWithString:@"dpi"] ]];
    [sheet row:@"Anchor:" views:@[ anchorGrid ]];
    [sheet row:nil views:@[ transparent ]];
    [sheet row:nil views:@[ mono ]];
    __block NSInteger unit = 0;
    __block NSInteger anchor = 0;
    double (^perUnit)(NSInteger) = ^double(NSInteger u) { return u == 0 ? 1 : u == 1 ? dpi.doubleValue : dpi.doubleValue / 2.54; };
    sheet.changed = ^(NSControl* control) {
      if (control == units && units.indexOfSelectedItem != unit) {
          double from = perUnit(unit), to = perUnit(units.indexOfSelectedItem);
          width.doubleValue = round(width.doubleValue / from * to * 100) / 100;
          height.doubleValue = round(height.doubleValue / from * to * 100) / 100;
          unit = units.indexOfSelectedItem;
      }
      if ([anchorButtons containsObject:(NSButton*)control]) {
          anchor = control.tag;
          for (NSButton* b in anchorButtons) b.state = b.tag == anchor ? NSControlStateValueOn : NSControlStateValueOff;
      }
    };
    sheet.done = ^{
      double scale = perUnit(unit);
      long w = lround(width.doubleValue / scale), h = lround(height.doubleValue / scale);
      NSMutableArray* ops = [NSMutableArray array];
      if (w != lround(width0) || h != lround(height0)) {
          SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(controller, NO);
          NSString* fill = transparent.state == NSControlStateValueOn ? @"transparent" : SPDFAnnotateHex(session ? session.color2 : 0xFFFFFFFFu);
          [ops addObject:@{@"op" : @"canvas.resize", @"width" : @(MIN(16384, MAX(1, w))), @"height" : @(MIN(16384, MAX(1, h))),
                           @"anchor" : anchors[anchor], @"fill" : fill}];
      }
      NSMutableDictionary* properties = [@{@"op" : @"canvas.properties"} mutableCopy];
      if (dpi.doubleValue > 0 && fabs(dpi.doubleValue - dpi0) > 0.001) properties[@"dpi"] = @(dpi.doubleValue);
      if (mono.state == NSControlStateValueOn) properties[@"blackAndWhite"] = @YES;
      if (properties.count > 1) [ops addObject:properties];
      if (ops.count) SPDFAnnotatePerform(controller, ops);
    };
    [sheet showOn:window];
}

#pragma mark - Rotate by

void SPDFAnnotateShowRotateBySheet(NSWindow* window, SPDFMacFillController* controller) {
    SPDFAnnotateSheet* sheet = [[SPDFAnnotateSheet alloc] initWithTitle:@"Rotate by"];
    NSTextField* degrees = [sheet number:90];
    [sheet row:@"Angle:" views:@[ degrees, [NSTextField labelWithString:@"degrees, clockwise"] ]];
    sheet.done = ^{
      double angle = fmod(degrees.doubleValue, 360);
      if (angle != 0) SPDFAnnotatePerform(controller, @{@"op" : @"image.rotate", @"degrees" : @(angle), @"scope" : @"auto"});
    };
    [sheet showOn:window];
}

#pragma mark - Questions

static void SPDFAnnotateAsk(NSAlert* alert, NSWindow* window, void (^answer)(NSModalResponse)) {
    if (window) [alert beginSheetModalForWindow:window completionHandler:answer];
    else answer([alert runModal]);
}

void SPDFAnnotateAskToSaveAsPDF(NSWindow* window, void (^answer)(BOOL save)) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = SPDFAnnotateSaveAsPDFQuestion;
    alert.informativeText = @"The PDF opens in a new tab, ready to annotate. This document stays as it is.";
    [alert addButtonWithTitle:SPDFAnnotateSaveAsPDFButton];
    [alert addButtonWithTitle:@"Cancel"];
    SPDFAnnotateAsk(alert, window, ^(NSModalResponse r) { if (answer) answer(r == NSAlertFirstButtonReturn); });
}

void SPDFAnnotateAskToSaveCanvas(NSWindow* window, NSString* name, void (^answer)(NSModalResponse choice)) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Do you want to save “%@”?", name.length ? name : SPDFAnnotateUntitledCanvasTitle];
    alert.informativeText = @"It has never been saved. If you don't save it, what you drew is lost.";
    [alert addButtonWithTitle:@"Save"];
    NSButton* discard = [alert addButtonWithTitle:@"Don't Save"];
    discard.hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];
    SPDFAnnotateAsk(alert, window, ^(NSModalResponse r) { if (answer) answer(r); });
}

void SPDFAnnotateAskToGrowCanvas(NSWindow* window, void (^answer)(BOOL grow)) {
    NSAlert* alert = [NSAlert new];
    alert.messageText = SPDFAnnotateGrowCanvasQuestion;
    alert.informativeText = @"The picture you're pasting is larger than the canvas.";
    [alert addButtonWithTitle:@"Yes"];
    [alert addButtonWithTitle:@"No"];
    SPDFAnnotateAsk(alert, window, ^(NSModalResponse r) { if (answer) answer(r == NSAlertFirstButtonReturn); });
}
