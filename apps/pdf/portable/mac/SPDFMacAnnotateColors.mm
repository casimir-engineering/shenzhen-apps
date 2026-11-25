// The palette's Colors group and the colour files (SPDFMacAnnotateColors.h).
#import "SPDFMacAnnotateColors.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

#import "SPDFMacAnnotatePaletteGroups.h"
#import "SPDFMacAnnotatePaletteSupport.h"
#import "SPDFMacFillController.h"

static const CGFloat kSPDFSwatch = 12, kSPDFSwatchGap = 2;

// One square: a palette colour, a custom slot (empty slots are drawn as an outline), or Color 1 / Color 2.
@interface SPDFAnnotateSwatch : NSButton
@property(nonatomic) spdf_paint_color color;
@property(nonatomic) BOOL empty;
@property(nonatomic) BOOL chosen;  // Color 1 / Color 2: the one the palette sets
@property(nonatomic) BOOL big;
@property(nonatomic) BOOL rightClicked;
@end

@implementation SPDFAnnotateSwatch

- (BOOL)acceptsFirstResponder { return NO; }
- (NSSize)intrinsicContentSize { return self.big ? NSMakeSize(20, 20) : NSMakeSize(kSPDFSwatch, kSPDFSwatch); }

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect box = NSInsetRect(self.bounds, 0.5, 0.5);
    NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:box xRadius:self.big ? 4 : 2 yRadius:self.big ? 4 : 2];
    if (!self.empty) {
        // Transparency shows over a small checkerboard, as on the canvas.
        if ((self.color & 0xFF) < 0xFF) {
            [NSGraphicsContext saveGraphicsState];
            [shape addClip];
            [[NSColor colorWithWhite:1 alpha:1] setFill];
            NSRectFill(box);
            [[NSColor colorWithWhite:0.85 alpha:1] setFill];
            for (CGFloat y = 0; y < NSHeight(box); y += 4)
                for (CGFloat x = ((NSInteger)(y / 4) % 2) * 4; x < NSWidth(box); x += 8)
                    NSRectFill(NSMakeRect(NSMinX(box) + x, NSMinY(box) + y, 4, 4));
            [NSGraphicsContext restoreGraphicsState];
        }
        [SPDFAnnotateNSColor(self.color) setFill];
        [shape fill];
    }
    [[NSColor.labelColor colorWithAlphaComponent:self.empty ? 0.25 : 0.3] setStroke];
    shape.lineWidth = 1;
    [shape stroke];
    if (self.chosen) {
        NSBezierPath* ring = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, -2, -2) xRadius:6 yRadius:6];
        ring.lineWidth = 2;
        [NSColor.controlAccentColor setStroke];
        [ring stroke];
    }
}

- (void)rightMouseDown:(NSEvent*)event {
    (void)event;
    self.rightClicked = YES;
    [self sendAction:self.action to:self.target];
    self.rightClicked = NO;
}

@end

@interface SPDFMacAnnotateColorsView ()
- (void)colorPanelChanged:(NSColorPanel*)panel;
- (void)colorPanelClosed:(NSNotification*)note;
@end

static char kSPDFAnnotateColorsViewKey;

@implementation SPDFMacAnnotateColorsView {
    __weak SPDFMacFillController* _controller;
    SPDFAnnotateSwatch* _color1;
    SPDFAnnotateSwatch* _color2;
    NSArray<SPDFAnnotateSwatch*>* _palette;
    NSArray<SPDFAnnotateSwatch*>* _custom;
    NSButton* _edit;
    NSView* _grid;
    NSLayoutConstraint* _fullTrailing;
    NSLayoutConstraint* _compactTrailing;
    BOOL _settingColor2;  // the swatch the palette sets
    BOOL _panelOpen;
    spdf_paint_color _panelColor;
}

- (instancetype)initWithController:(SPDFMacFillController*)controller {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _controller = controller;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        objc_setAssociatedObject(controller, &kSPDFAnnotateColorsViewKey, self, OBJC_ASSOCIATION_ASSIGN);
        [self build];
    }
    return self;
}

- (BOOL)isFlipped { return YES; }

- (SPDFAnnotateSwatch*)swatch:(NSString*)label big:(BOOL)big {
    SPDFAnnotateSwatch* swatch = [[SPDFAnnotateSwatch alloc] initWithFrame:NSZeroRect];
    swatch.big = big;
    swatch.bordered = NO;
    swatch.title = @"";
    swatch.toolTip = label;
    swatch.accessibilityLabel = label;
    swatch.refusesFirstResponder = YES;
    swatch.target = self;
    swatch.action = @selector(swatchClicked:);
    swatch.translatesAutoresizingMaskIntoConstraints = NO;
    [swatch.widthAnchor constraintEqualToConstant:big ? 20 : kSPDFSwatch].active = YES;
    [swatch.heightAnchor constraintEqualToConstant:big ? 20 : kSPDFSwatch].active = YES;
    return swatch;
}

- (void)build {
    _color1 = [self swatch:@"Color 1" big:YES];
    _color2 = [self swatch:@"Color 2" big:YES];
    _color1.toolTip = @"Color 1 (X swaps, D resets)";
    _color2.toolTip = @"Color 2 (X swaps, D resets)";
    NSMutableArray* palette = [NSMutableArray array];
    for (NSInteger i = 0; i < 20; ++i) {
        SPDFAnnotateSwatch* swatch = [self swatch:SPDFAnnotatePaletteColorName(i) big:NO];
        swatch.color = SPDFAnnotatePaletteColors[i];
        swatch.tag = i;
        [palette addObject:swatch];
    }
    _palette = palette;
    NSMutableArray* custom = [NSMutableArray array];
    for (NSInteger i = 0; i < 10; ++i) {
        SPDFAnnotateSwatch* swatch = [self swatch:@"Custom color" big:NO];
        swatch.tag = 100 + i;
        swatch.empty = YES;
        [custom addObject:swatch];
    }
    _custom = custom;
    _edit = [NSButton buttonWithImage:SPDFAnnotateSymbol(@"paintpalette", @"Edit colors") ?: [NSImage new]
                               target:self action:@selector(editColors:)];
    if (!_edit.image.isValid) _edit.title = @"Edit colors";
    _edit.bordered = NO;
    _edit.toolTip = @"Edit colors";
    _edit.accessibilityLabel = @"Edit colors";
    _edit.refusesFirstResponder = YES;
    _edit.translatesAutoresizingMaskIntoConstraints = NO;
    [_edit.widthAnchor constraintEqualToConstant:26].active = YES;
    // Two rows: the 20 colours (10 a row), a gap, then the custom slots (5 a row).
    _grid = [[NSView alloc] initWithFrame:NSZeroRect];
    _grid.translatesAutoresizingMaskIntoConstraints = NO;
    CGFloat step = kSPDFSwatch + kSPDFSwatchGap;
    for (NSInteger i = 0; i < 30; ++i) {
        SPDFAnnotateSwatch* s = i < 20 ? _palette[i] : _custom[i - 20];
        NSInteger col = i < 20 ? i % 10 : 10 + (i - 20) % 5, row = i < 20 ? i / 10 : (i - 20) / 5;
        [_grid addSubview:s];
        [s.leadingAnchor constraintEqualToAnchor:_grid.leadingAnchor constant:col * step + (col >= 10 ? 6 : 0)].active = YES;
        [s.topAnchor constraintEqualToAnchor:_grid.topAnchor constant:row * step].active = YES;
    }
    [_grid.widthAnchor constraintEqualToConstant:15 * step - kSPDFSwatchGap + 6].active = YES;
    [_grid.heightAnchor constraintEqualToConstant:2 * step - kSPDFSwatchGap].active = YES;
    for (NSView* v in @[ _color1, _color2, _grid, _edit ]) [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [_color1.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [_color1.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_color2.leadingAnchor constraintEqualToAnchor:_color1.trailingAnchor constant:6],
        [_color2.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_grid.leadingAnchor constraintEqualToAnchor:_color2.trailingAnchor constant:10],
        [_grid.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_edit.leadingAnchor constraintEqualToAnchor:_grid.trailingAnchor constant:4],
        [_edit.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:28],
    ]];
    _fullTrailing = [self.trailingAnchor constraintEqualToAnchor:_edit.trailingAnchor];
    _compactTrailing = [self.trailingAnchor constraintEqualToAnchor:_color2.trailingAnchor constant:2];
    _fullTrailing.active = YES;
}

- (void)setCompact:(BOOL)compact {
    _compact = compact;
    _grid.hidden = compact;
    _edit.hidden = compact;
    _fullTrailing.active = !compact;
    _compactTrailing.active = compact;
    self.needsLayout = YES;
    [self invalidateIntrinsicContentSize];
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(_compact ? 2 + 20 + 6 + 20 + 2 : NSViewNoIntrinsicMetric, 28);
}

- (void)updateFromSession:(SPDFMacAnnotateSession*)session {
    _color1.color = session ? session.color1 : 0x000000FFu;
    _color2.color = session ? session.color2 : 0xFFFFFFFFu;
    _color1.chosen = !_settingColor2;
    _color2.chosen = _settingColor2;
    NSArray<NSString*>* saved = [SPDFAnnotateSettings shared].customColors;
    for (NSInteger i = 0; i < 10; ++i) {
        spdf_paint_color c = 0;
        BOOL filled = i < (NSInteger)saved.count && SPDFAnnotateParseHex(saved[i], &c);
        _custom[i].empty = !filled;
        _custom[i].color = c;
        _custom[i].toolTip = filled ? SPDFAnnotateHex(c) : @"Empty: click to make a color for it";
        _custom[i].needsDisplay = YES;
    }
    for (NSView* v in @[ _color1, _color2 ]) v.needsDisplay = YES;
    BOOL enabled = session != nil;
    NSMutableArray<NSButton*>* buttons = [NSMutableArray arrayWithArray:_palette];
    [buttons addObjectsFromArray:_custom];
    [buttons addObjectsFromArray:@[ _color1, _color2, _edit ]];
    for (NSButton* b in buttons) b.enabled = enabled;
}

#pragma mark - Choosing

- (void)setColor:(spdf_paint_color)color second:(BOOL)second {
    SPDFMacFillController* controller = _controller;
    SPDFAnnotateSend(controller, @{@"op" : @"colors.set", second ? @"color2" : @"color1" : SPDFAnnotateHex(color)}, nil);
    // Pen and Arrow draw in Color 1 once it is chosen, as well as in Fill & Sign's four colours.
    NSString* tool = SPDFAnnotateChosenToolName(SPDFAnnotateCurrentSession(controller, NO));
    if (!second && ([tool isEqual:@"pen"] || [tool isEqual:@"arrow"]))
        SPDFAnnotateChooseTool(controller, tool, @{@"color" : SPDFAnnotateHex(color)});
}

- (void)swatchClicked:(SPDFAnnotateSwatch*)swatch {
    if (swatch == _color1 || swatch == _color2) {
        _settingColor2 = swatch == _color2;
        [self updateFromSession:SPDFAnnotateCurrentSession(_controller, NO)];
        if (_panelOpen) {
            NSColorPanel* panel = [NSColorPanel sharedColorPanel];
            panel.target = nil;
            panel.color = SPDFAnnotateNSColor(swatch.color);
            panel.target = self;
        }
        return;
    }
    if (swatch.empty) {  // an empty custom slot: make the colour that goes into it
        [self editColors:nil];
        return;
    }
    [self setColor:swatch.color second:swatch.rightClicked || _settingColor2];
}

- (void)editColors:(id)sender {
    (void)sender;
    NSColorPanel* panel = [NSColorPanel sharedColorPanel];
    panel.showsAlpha = YES;  // every colour has alpha
    SPDFMacAnnotateSession* session = SPDFAnnotateCurrentSession(_controller, NO);
    spdf_paint_color start = session ? (_settingColor2 ? session.color2 : session.color1) : 0x000000FFu;
    panel.target = nil;  // setting its colour must not count as a choice
    panel.color = SPDFAnnotateNSColor(start);
    panel.target = self;
    panel.action = @selector(colorPanelChanged:);
    _panelColor = start;
    if (!_panelOpen)
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(colorPanelClosed:)
                                                   name:NSWindowWillCloseNotification object:panel];
    _panelOpen = YES;
    [panel orderFront:nil];
}

- (void)colorPanelChanged:(NSColorPanel*)panel {
    _panelColor = SPDFAnnotateColorFromNSColor(panel.color);
    [self setColor:_panelColor second:_settingColor2];
}

// The colour made in the panel is kept in the next empty custom slot (or the oldest one when all are full).
- (void)colorPanelClosed:(NSNotification*)note {
    [NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:note.object];
    _panelOpen = NO;
    NSColorPanel* panel = note.object;
    panel.target = nil;
    NSArray<NSString*>* saved = [SPDFAnnotateSettings shared].customColors;
    for (NSString* hex in saved)
        if ([hex isEqual:SPDFAnnotateHex(_panelColor)]) return;  // already kept
    NSInteger slot = -1;
    for (NSInteger i = 0; i < 10 && slot < 0; ++i)
        if (i >= (NSInteger)saved.count || ![saved[i] length]) slot = i;
    static NSInteger next;
    if (slot < 0) slot = (next++) % 10;
    SPDFAnnotateSend(_controller, @{@"op" : @"palette.set_custom", @"index" : @(slot), @"color" : SPDFAnnotateHex(_panelColor)},
                     nil);
}

@end

void SPDFAnnotateOpenColorPanel(SPDFMacFillController* controller) {
    SPDFMacAnnotateColorsView* view = objc_getAssociatedObject(controller, &kSPDFAnnotateColorsViewKey);
    if (view) [view editColors:nil];
}

NSMenu* SPDFAnnotateColorsMenu(SPDFMacFillController* controller) {
    NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Colors"];
    NSMutableArray* colors = [NSMutableArray array];
    for (NSInteger i = 0; i < 20; ++i) [colors addObject:@[ SPDFAnnotatePaletteColorName(i), @(SPDFAnnotatePaletteColors[i]) ]];
    for (NSString* hex in [SPDFAnnotateSettings shared].customColors) {
        spdf_paint_color c;
        if (SPDFAnnotateParseHex(hex, &c)) [colors addObject:@[ hex, @(c) ]];
    }
    for (NSArray* entry in colors) {
        spdf_paint_color c = (spdf_paint_color)[entry[1] unsignedIntValue];
        NSMenuItem* item = SPDFAnnotateItem(entry[0], @"", 0, (@{@"op" : @"colors.set", @"color1" : SPDFAnnotateHex(c)}),
                                            controller, nil);
        NSImage* dot = [NSImage imageWithSize:NSMakeSize(14, 14) flipped:NO drawingHandler:^BOOL(NSRect r) {
          [SPDFAnnotateNSColor(c) setFill];
          [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:3 yRadius:3] fill];
          [[NSColor.labelColor colorWithAlphaComponent:0.3] setStroke];
          [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:3 yRadius:3] stroke];
          return YES;
        }];
        item.image = dot;
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:SPDFAnnotateItem(@"Edit colors…", @"", 0, SPDFAnnotateCommandEditColors, controller, nil)];
    [menu addItem:SPDFAnnotateItem(@"Swap Color 1 and Color 2", @"", 0, SPDFAnnotateCommandSwapColors, controller, nil)];
    return menu;
}

#pragma mark - Colour files (.json and Paint's RIFF .pal)

static NSData* SPDFAnnotatePalData(NSArray<NSNumber*>* colors) {
    NSMutableData* data = [NSMutableData data];
    uint32_t count = (uint32_t)colors.count, chunk = 4 + 4 * count, riff = 4 + 8 + chunk;
    uint16_t version = 0x0300, entries = (uint16_t)count;
    [data appendBytes:"RIFF" length:4];
    [data appendBytes:&riff length:4];  // little-endian on every Mac this runs on
    [data appendBytes:"PAL data" length:8];
    [data appendBytes:&chunk length:4];
    [data appendBytes:&version length:2];
    [data appendBytes:&entries length:2];
    for (NSNumber* n in colors) {
        spdf_paint_color c = n.unsignedIntValue;
        uint8_t entry[4] = {(uint8_t)(c >> 24), (uint8_t)(c >> 16), (uint8_t)(c >> 8), 0};
        [data appendBytes:entry length:4];
    }
    return data;
}

static NSArray<NSNumber*>* SPDFAnnotatePalColors(NSData* data) {
    const uint8_t* b = (const uint8_t*)data.bytes;
    if (data.length < 24 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "PAL data", 8)) return nil;
    uint16_t count;
    memcpy(&count, b + 22, 2);
    NSMutableArray* colors = [NSMutableArray array];
    for (NSUInteger i = 0; i < count && 24 + 4 * i + 3 < data.length; ++i) {
        const uint8_t* e = b + 24 + 4 * i;
        [colors addObject:@(((spdf_paint_color)e[0] << 24) | ((spdf_paint_color)e[1] << 16) | ((spdf_paint_color)e[2] << 8) | 0xFFu)];
    }
    return colors;
}

static NSArray<UTType*>* SPDFAnnotateColorFileTypes(void) {
    UTType* pal = [UTType typeWithFilenameExtension:@"pal"] ?: UTTypeData;
    return @[ UTTypeJSON, pal ];
}

void SPDFAnnotateSaveColorsFile(SPDFMacFillController* controller) {
    NSSavePanel* panel = [NSSavePanel savePanel];
    panel.title = @"Save Colors";
    panel.allowedContentTypes = SPDFAnnotateColorFileTypes();
    panel.allowsOtherFileTypes = NO;
    panel.nameFieldStringValue = @"Colors.json";
    NSArray<NSString*>* custom = [SPDFAnnotateSettings shared].customColors ?: @[];
    [panel beginSheetModalForWindow:[controller.host fillWindow] completionHandler:^(NSModalResponse response) {
      if (response != NSModalResponseOK) return;
      NSMutableArray* palette = [NSMutableArray array];
      NSMutableArray* numbers = [NSMutableArray array];
      for (NSInteger i = 0; i < 20; ++i) {
          [palette addObject:SPDFAnnotateHex(SPDFAnnotatePaletteColors[i])];
          [numbers addObject:@(SPDFAnnotatePaletteColors[i])];
      }
      for (NSString* hex in custom) {
          spdf_paint_color c;
          if (SPDFAnnotateParseHex(hex, &c)) [numbers addObject:@(c)];
      }
      NSData* data = [panel.URL.pathExtension.lowercaseString isEqual:@"pal"]
                         ? SPDFAnnotatePalData(numbers)
                         : [NSJSONSerialization dataWithJSONObject:@{@"version" : @1, @"palette" : palette, @"custom" : custom}
                                                           options:NSJSONWritingPrettyPrinted error:NULL];
      NSError* error = nil;
      if (![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [NSApp presentError:error];
    }];
}

void SPDFAnnotateGetColorsFile(SPDFMacFillController* controller) {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.title = @"Get Colors";
    panel.allowedContentTypes = SPDFAnnotateColorFileTypes();
    [panel beginSheetModalForWindow:[controller.host fillWindow] completionHandler:^(NSModalResponse response) {
      if (response != NSModalResponseOK) return;
      NSData* data = [NSData dataWithContentsOfURL:panel.URL];
      NSMutableArray<NSNumber*>* colors = [NSMutableArray array];
      NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
      if ([json isKindOfClass:[NSDictionary class]]) {
          for (NSString* key in @[ @"custom", @"palette", @"colors" ])
              for (id hex in [json[key] isKindOfClass:[NSArray class]] ? json[key] : @[]) {
                  spdf_paint_color c;
                  if (SPDFAnnotateParseHex(hex, &c)) [colors addObject:@(c)];
              }
      } else if (data) {
          [colors addObjectsFromArray:SPDFAnnotatePalColors(data) ?: @[]];
      }
      // Paint's own 20 are always there: the others become the custom colours, in the file's order.
      NSMutableOrderedSet* custom = [NSMutableOrderedSet orderedSet];
      for (NSNumber* c in colors) {
          BOOL fixed = NO;
          for (NSInteger i = 0; i < 20; ++i) fixed = fixed || SPDFAnnotatePaletteColors[i] == c.unsignedIntValue;
          if (!fixed) [custom addObject:c];
      }
      if (!custom.count) {
          NSAlert* alert = [NSAlert new];
          alert.messageText = @"No new colors in this file";
          alert.informativeText = @"Its colors are all in the palette already.";
          [alert beginSheetModalForWindow:[controller.host fillWindow] completionHandler:nil];
          return;
      }
      for (NSUInteger i = 0; i < MIN(custom.count, 10u); ++i)
          SPDFAnnotateSend(controller, @{@"op" : @"palette.set_custom", @"index" : @(i),
                                         @"color" : SPDFAnnotateHex([custom[i] unsignedIntValue])}, nil);
    }];
}
