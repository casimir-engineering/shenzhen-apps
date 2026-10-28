// The Appearance page of the Settings window (SPDFMacAppearanceSettings.h). Kept apart from the Settings controller so
// that file stays within its size cap.

#import "SPDFMacAppearanceSettings.h"
#import "SPDFMacCollectionStyle.h"

// Built by SPDFMacUnifiedSettings.mm; declared here so the page is laid out like its neighbours.
@interface SPDFMacUnifiedSettingsController (SPDFMacAppearancePageBuilding)
- (NSDictionary*)state;
- (NSMutableDictionary<NSString*, NSControl*>*)controls;
- (void)text:(NSString*)text size:(CGFloat)size bold:(BOOL)bold secondary:(BOOL)secondary;
- (NSStackView*)row:(NSString*)title detail:(NSString*)detail control:(NSView*)control;
- (void)divider;
- (void)emit:(NSDictionary*)change;
@end

// A palette's colours side by side, as the popup's picture of each choice.
static NSImage* PaletteStrip(NSArray<NSNumber*>* fills) {
    const CGFloat size = 12, gap = 2;
    NSSize total = NSMakeSize(fills.count * (size + gap) + 4, size); // and a little space before the name
    return [NSImage imageWithSize:total flipped:NO drawingHandler:^BOOL(NSRect rect) {
        (void)rect;
        for (NSUInteger i = 0; i < fills.count; i++) {
            unsigned rgb = fills[i].unsignedIntValue;
            [[NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0
                                  blue:(rgb & 255) / 255.0 alpha:1] setFill];
            NSRect chip = NSMakeRect(i * (size + gap), 0, size, size);
            [[NSBezierPath bezierPathWithRoundedRect:chip xRadius:3 yRadius:3] fill];
            [[NSColor colorWithWhite:0.5 alpha:0.35] setStroke];
            [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(chip, 0.5, 0.5) xRadius:2.5 yRadius:2.5] stroke];
        }
        return YES;
    }];
}

@implementation SPDFMacUnifiedSettingsController (SPDFMacAppearance)
- (void)buildAppearance {
    [self text:@"Appearance" size:24 bold:YES secondary:NO];
    [self divider];
    NSPopUpButton* palettes = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    palettes.identifier = @"tabGroupPalette";
    palettes.accessibilityLabel = @"Tab group colors";
    palettes.font = [NSFont systemFontOfSize:13];
    [palettes.widthAnchor constraintEqualToConstant:340].active = YES;
    for (NSDictionary* palette in self.state[@"tabGroupPalettes"]) {
        [palettes addItemWithTitle:palette[@"name"]];
        palettes.lastItem.image = PaletteStrip(palette[@"fills"]);
    }
    if (self.state[@"tabGroupPalette"]) [palettes selectItemWithTitle:self.state[@"tabGroupPalette"]];
    palettes.target = self;
    palettes.action = @selector(paletteChosen:);
    self.controls[@"tabGroupPalette"] = palettes;
    [self row:@"Tab group colors" detail:@"Every window changes right away." control:palettes];
}
- (void)paletteChosen:(NSPopUpButton*)sender {
    if (sender.titleOfSelectedItem.length) [self emit:@{@"tabGroupPalette" : sender.titleOfSelectedItem}];
}
@end
