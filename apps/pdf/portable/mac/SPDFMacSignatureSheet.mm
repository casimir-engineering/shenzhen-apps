#import "SPDFMacSignatureSheet.h"

#import "SPDFMacCollectionStyle.h"
#import "SPDFMacFillModel.h"
#import "SPDFMacSignatureOutlines.h"
#import "SPDFMacSignatureStore.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSColor* SPDFSheetInk(NSInteger ink) {
    return ink == 1 ? [NSColor colorWithSRGBRed:0.08 green:0.22 blue:0.62 alpha:1] : NSColor.blackColor;
}

// The paper to sign on: always white, like the page the signature lands on.
@interface SPDFSignaturePadView : NSView
@property(nonatomic, readonly) NSMutableArray<SPDFSignatureStroke*>* strokes;
@property(nonatomic) NSInteger ink;
@property(nonatomic, copy) NSString* placeholder;
@property(nonatomic, copy) void (^onChange)(void);
- (void)clear;
@end

@implementation SPDFSignaturePadView {
    NSMutableArray<SPDFSignatureStroke*>* _strokes;
}
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) _strokes = [NSMutableArray array];
    return self;
}
- (NSMutableArray<SPDFSignatureStroke*>*)strokes { return _strokes; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { (void)event; return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (void)clear {
    [_strokes removeAllObjects];
    self.needsDisplay = YES;
    if (self.onChange) self.onChange();
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSBezierPath* paper = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:8 yRadius:8];
    [NSColor.whiteColor setFill];
    [paper fill];
    [[NSColor colorWithWhite:0.82 alpha:1] setStroke];
    [paper stroke];
    CGFloat baseline = floor(NSHeight(self.bounds) * 0.3) + 0.5;
    NSBezierPath* line = [NSBezierPath bezierPath];
    [line moveToPoint:NSMakePoint(24, baseline)];
    [line lineToPoint:NSMakePoint(NSWidth(self.bounds) - 24, baseline)];
    [[NSColor colorWithWhite:0.85 alpha:1] setStroke];
    [line stroke];
    if (_strokes.count == 0 && self.placeholder.length) {
        NSDictionary* attrs = @{
            NSFontAttributeName : [NSFont systemFontOfSize:13],
            NSForegroundColorAttributeName : [NSColor colorWithWhite:0.55 alpha:1]
        };
        NSSize size = [self.placeholder sizeWithAttributes:attrs];
        [self.placeholder drawAtPoint:NSMakePoint((NSWidth(self.bounds) - size.width) / 2, baseline + 14) withAttributes:attrs];
    }
    [SPDFSheetInk(self.ink) setStroke];
    for (SPDFSignatureStroke* stroke in _strokes) {
        NSBezierPath* path = SPDFSignatureSmoothedStroke(stroke);
        path.lineWidth = 2.6;
        path.lineCapStyle = NSLineCapStyleRound;
        path.lineJoinStyle = NSLineJoinStyleRound;
        [path stroke];
    }
}
- (void)mouseDown:(NSEvent*)event {
    SPDFSignatureStroke* stroke = [SPDFSignatureStroke new];
    [stroke addPoint:[self convertPoint:event.locationInWindow fromView:nil] time:event.timestamp];
    [_strokes addObject:stroke];
    self.needsDisplay = YES;
}
- (void)mouseDragged:(NSEvent*)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    p.x = MAX(2, MIN(NSWidth(self.bounds) - 2, p.x));
    p.y = MAX(2, MIN(NSHeight(self.bounds) - 2, p.y));
    [_strokes.lastObject addPoint:p time:event.timestamp];
    self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent*)event {
    (void)event;
    if (self.onChange) self.onChange();
}
@end

static NSMutableSet* SPDFOpenSheets(void) {
    static NSMutableSet* sheets;
    if (!sheets) sheets = [NSMutableSet set];
    return sheets;
}

@interface SPDFMacSignatureSheet ()
@property(nonatomic, strong) NSPanel* panel;
@property(nonatomic, weak) NSWindow* parent;
@property(nonatomic) BOOL initials;
@property(nonatomic, copy) void (^completion)(SPDFMacSignature*);
@property(nonatomic, strong) NSSegmentedControl* modes;
@property(nonatomic, strong) NSView* drawPane;
@property(nonatomic, strong) NSView* typePane;
@property(nonatomic, strong) NSView* picturePane;
@property(nonatomic, strong) SPDFSignaturePadView* pad;
@property(nonatomic, strong) NSSegmentedControl* inkControl;
@property(nonatomic, strong) NSTextField* nameField;
@property(nonatomic, strong) NSArray<NSButton*>* fontButtons;
@property(nonatomic) NSInteger chosenFont;
@property(nonatomic, strong) NSImageView* pictureView;
@property(nonatomic, strong) NSData* picturePNG;
@property(nonatomic) CGFloat pictureAspect;
@property(nonatomic, strong) NSButton* keepBox;
@property(nonatomic, strong) NSTextField* keepNote;
@property(nonatomic, strong) NSButton* useButton;
@end

@implementation SPDFMacSignatureSheet

+ (NSArray<NSString*>*)scriptFontNames {
    NSMutableArray* names = [NSMutableArray array];
    for (NSString* name in @[ @"SnellRoundhand", @"BradleyHandITCTT-Bold", @"SavoyeLetPlain", @"Apple-Chancery" ])
        if ([NSFont fontWithName:name size:12]) [names addObject:name];
    if (!names.count) [names addObject:[NSFont systemFontOfSize:12].fontName];
    return names;
}

+ (void)beginForWindow:(NSWindow*)window
              initials:(BOOL)initials
         suggestedName:(NSString*)suggestedName
            completion:(void (^)(SPDFMacSignature*))completion {
    SPDFMacSignatureSheet* sheet = [SPDFMacSignatureSheet new];
    sheet.parent = window;
    sheet.initials = initials;
    sheet.completion = completion;
    [sheet build:suggestedName ?: @""];
    [SPDFOpenSheets() addObject:sheet];
    if (window) {
        [window beginSheet:sheet.panel completionHandler:nil];
    } else {
        [sheet.panel center];
        [sheet.panel makeKeyAndOrderFront:nil];
    }
}

- (NSTextField*)label:(NSString*)text size:(CGFloat)size weight:(NSFontWeight)weight frame:(NSRect)frame {
    NSTextField* label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = SPDFCollectionColor(weight >= NSFontWeightSemibold ? @"text" : @"secondary");
    label.frame = frame;
    return label;
}

- (void)build:(NSString*)suggestedName {
    NSRect frame = NSMakeRect(0, 0, 520, 340);
    self.panel = [[NSPanel alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = self.initials ? @"New Initials" : @"New Signature";
    NSView* content = self.panel.contentView;
    [content addSubview:[self label:self.panel.title size:15 weight:NSFontWeightSemibold
                              frame:NSMakeRect(20, 300, 300, 22)]];

    self.modes = [NSSegmentedControl segmentedControlWithLabels:@[ @"Draw", @"Type", @"Picture" ]
                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                         target:self
                                                         action:@selector(modeChanged:)];
    self.modes.frame = NSMakeRect(300, 298, 200, 24);
    self.modes.selectedSegment = 0;
    [content addSubview:self.modes];

    NSRect paneFrame = NSMakeRect(20, 64, 480, 224);
    self.drawPane = [[NSView alloc] initWithFrame:paneFrame];
    self.pad = [[SPDFSignaturePadView alloc] initWithFrame:NSMakeRect(0, 36, 480, 188)];
    self.pad.placeholder = @"Sign here with your trackpad or mouse";
    __weak SPDFMacSignatureSheet* weakSelf = self;
    self.pad.onChange = ^{ [weakSelf updateUseButton]; };
    [self.drawPane addSubview:self.pad];
    NSButton* clear = [NSButton buttonWithTitle:@"Clear" target:self.pad action:@selector(clear)];
    clear.frame = NSMakeRect(400, 0, 80, 28);
    [self.drawPane addSubview:clear];
    [content addSubview:self.drawPane];

    self.typePane = [[NSView alloc] initWithFrame:paneFrame];
    self.nameField = [NSTextField textFieldWithString:suggestedName];
    self.nameField.frame = NSMakeRect(0, 196, 480, 26);
    self.nameField.font = [NSFont systemFontOfSize:14];
    self.nameField.target = self;
    self.nameField.action = @selector(nameChanged:);
    self.nameField.delegate = (id<NSTextFieldDelegate>)self;
    [self.typePane addSubview:self.nameField];
    NSMutableArray* buttons = [NSMutableArray array];
    NSArray* fonts = [SPDFMacSignatureSheet scriptFontNames];
    for (NSUInteger i = 0; i < fonts.count; ++i) {
        NSButton* button = [NSButton buttonWithTitle:@"" target:self action:@selector(fontChosen:)];
        button.bezelStyle = NSBezelStyleRegularSquare;
        button.buttonType = NSButtonTypeOnOff;
        button.tag = (NSInteger)i;
        button.frame = NSMakeRect((i % 2) * 244, 36 + (1 - (CGFloat)(i / 2)) * 78, 236, 72);
        [buttons addObject:button];
        [self.typePane addSubview:button];
    }
    self.fontButtons = buttons;
    [content addSubview:self.typePane];

    self.picturePane = [[NSView alloc] initWithFrame:paneFrame];
    [self.picturePane addSubview:[self label:@"A photo or scan of your signature on white paper. The paper is removed."
                                        size:12 weight:NSFontWeightRegular frame:NSMakeRect(0, 194, 480, 30)]];
    self.pictureView = [NSImageView imageViewWithImage:[NSImage new]];
    self.pictureView.frame = NSMakeRect(0, 36, 480, 150);
    self.pictureView.imageScaling = NSImageScaleProportionallyDown;
    self.pictureView.wantsLayer = YES;
    self.pictureView.layer.backgroundColor = NSColor.whiteColor.CGColor;
    self.pictureView.layer.cornerRadius = 8;
    [self.picturePane addSubview:self.pictureView];
    NSButton* choose = [NSButton buttonWithTitle:@"Choose Picture…" target:self action:@selector(choosePicture:)];
    choose.frame = NSMakeRect(330, 0, 150, 28);
    [self.picturePane addSubview:choose];
    [content addSubview:self.picturePane];

    self.inkControl = [NSSegmentedControl segmentedControlWithLabels:@[ @"Black", @"Blue" ]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self
                                                              action:@selector(inkChanged:)];
    self.inkControl.frame = NSMakeRect(20, 64, 140, 26);
    self.inkControl.selectedSegment = 0;
    [content addSubview:self.inkControl];

    self.keepBox = [NSButton checkboxWithTitle:@"Keep for next time" target:self action:@selector(keepChanged:)];
    self.keepBox.state = NSControlStateValueOn;
    self.keepBox.frame = NSMakeRect(20, 20, 150, 22);
    [content addSubview:self.keepBox];
    self.keepNote = [self label:@"Saved on this Mac only." size:11 weight:NSFontWeightRegular frame:NSMakeRect(172, 22, 150, 18)];
    [content addSubview:self.keepNote];
    NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    cancel.frame = NSMakeRect(310, 16, 90, 30);
    [content addSubview:cancel];
    self.useButton = [NSButton buttonWithTitle:self.initials ? @"Use Initials" : @"Use Signature" target:self
                                        action:@selector(use:)];
    self.useButton.keyEquivalent = @"\r";
    self.useButton.frame = NSMakeRect(400, 16, 110, 30);
    [content addSubview:self.useButton];

    if (suggestedName.length) self.modes.selectedSegment = 1;  // a name to show: start on Type, Draw is one click away
    [self modeChanged:nil];
}

- (void)modeChanged:(id)sender {
    (void)sender;
    NSInteger mode = self.modes.selectedSegment;
    self.drawPane.hidden = mode != 0;
    self.typePane.hidden = mode != 1;
    self.picturePane.hidden = mode != 2;
    self.inkControl.hidden = mode == 2;
    if (mode == 1) [self refreshFontButtons];
    if (mode == 1) [self.panel makeFirstResponder:self.nameField];
    [self updateUseButton];
}

- (void)inkChanged:(id)sender {
    (void)sender;
    self.pad.ink = self.inkControl.selectedSegment;
    self.pad.needsDisplay = YES;
    [self refreshFontButtons];
}

- (void)keepChanged:(id)sender {
    (void)sender;
    self.keepNote.hidden = self.keepBox.state != NSControlStateValueOn;
}

- (void)nameChanged:(id)sender {
    (void)sender;
    [self refreshFontButtons];
}

- (void)fontChosen:(NSButton*)sender {
    self.chosenFont = sender.tag;
    [self refreshFontButtons];
}

- (void)refreshFontButtons {
    NSString* text = self.nameField.stringValue.length ? self.nameField.stringValue : (self.initials ? @"AB" : @"Your Name");
    NSArray* fonts = [SPDFMacSignatureSheet scriptFontNames];
    for (NSButton* button in self.fontButtons) {
        NSFont* font = [NSFont fontWithName:fonts[(NSUInteger)button.tag] size:28] ?: [NSFont systemFontOfSize:24];
        NSMutableParagraphStyle* centred = [NSMutableParagraphStyle new];
        centred.alignment = NSTextAlignmentCenter;
        centred.lineBreakMode = NSLineBreakByTruncatingTail;
        button.attributedTitle = [[NSAttributedString alloc]
            initWithString:text
                attributes:@{NSFontAttributeName : font, NSForegroundColorAttributeName : SPDFSheetInk(self.inkControl.selectedSegment),
                             NSParagraphStyleAttributeName : centred}];
        button.state = button.tag == self.chosenFont ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self updateUseButton];
}

- (void)controlTextDidChange:(NSNotification*)note {
    (void)note;
    [self refreshFontButtons];
}

- (void)choosePicture:(id)sender {
    (void)sender;
    NSOpenPanel* open = [NSOpenPanel openPanel];
    open.allowedContentTypes = @[ UTTypeImage ];
    open.allowsMultipleSelection = NO;
    [open beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
      if (result != NSModalResponseOK) return;
      NSImage* image = [[NSImage alloc] initWithContentsOfURL:open.URL];
      CGFloat aspect = 0;
      NSData* png = image ? SPDFSignaturePictureFromImage(image, &aspect) : nil;
      self.picturePNG = png;
      self.pictureAspect = aspect;
      self.pictureView.image = png ? [[NSImage alloc] initWithData:png] : [NSImage new];
      if (!png) NSBeep();
      [self updateUseButton];
    }];
}

- (void)updateUseButton {
    NSInteger mode = self.modes.selectedSegment;
    self.useButton.enabled = mode == 0 ? self.pad.strokes.count > 0
                           : mode == 1 ? self.nameField.stringValue.length > 0
                                       : self.picturePNG.length > 0;
}

- (void)finish:(SPDFMacSignature*)signature {
    if (self.parent) [self.parent endSheet:self.panel];
    [self.panel orderOut:nil];
    void (^completion)(SPDFMacSignature*) = self.completion;
    self.completion = nil;
    [SPDFOpenSheets() removeObject:self];
    if (completion) completion(signature);
}

- (void)cancel:(id)sender {
    (void)sender;
    [self finish:nil];
}

- (void)use:(id)sender {
    (void)sender;
    SPDFMacSignature* signature = [SPDFMacSignature new];
    signature.identifier = SPDFFillNewIdentifier();
    signature.initials = self.initials;
    signature.ink = self.inkControl.selectedSegment;
    signature.created = NSDate.date;
    signature.lastUsed = NSDate.date;
    CGFloat aspect = 0;
    NSInteger mode = self.modes.selectedSegment;
    if (mode == 0) {
        signature.source = @"drawn";
        signature.paths = SPDFSignatureOutlinesFromStrokes(self.pad.strokes, 3.2, &aspect);
    } else if (mode == 1) {
        signature.source = @"typed";
        NSArray* fonts = [SPDFMacSignatureSheet scriptFontNames];
        NSFont* font = [NSFont fontWithName:fonts[(NSUInteger)MIN(self.chosenFont, (NSInteger)fonts.count - 1)] size:72];
        signature.paths = SPDFSignatureOutlinesFromText(self.nameField.stringValue, font, &aspect);
    } else {
        signature.source = @"picture";
        signature.ink = 0;
        signature.png = self.picturePNG;
        aspect = self.pictureAspect;
    }
    signature.aspect = aspect;
    if ((!signature.paths.count && !signature.png.length) || aspect <= 0.01) {
        NSBeep();
        return;
    }
    if (self.keepBox.state == NSControlStateValueOn) {
        NSError* error = nil;
        if (![[SPDFMacSignatureStore sharedStore] saveSignature:signature error:&error]) {
            NSAlert* alert = [NSAlert new];
            alert.messageText = @"Couldn't keep this signature for next time";
            alert.informativeText = error.localizedDescription ?: @"";
            [alert beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse response) {
              (void)response;
              [self finish:signature];  // still used this once
            }];
            return;
        }
    }
    [self finish:signature];
}
@end
