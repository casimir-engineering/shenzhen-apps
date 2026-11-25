#pragma once
// The buttons, split buttons and separators of the Annotate palette (SPDFMacFillPalette, SPDFMacAnnotatePaletteGroups,
// SPDFMacAnnotateColors), so every control of its two rows has one size, one spacing and one look:
//
// - an icon button is SPDFPaletteButtonSize square, its symbol centred in it; the whole square is what a click hits
//   and what the chosen look (the app's solid ink pill) fills;
// - a split button is an icon button and its menu button (SPDFPaletteChevronWidth wide, a ▾ centred in it) joined with
//   no gap: they round as one shape and hover as one, and while the tool is chosen the ▾ half is tinted so the pair
//   reads as one unit with the pill centred on the icon;
// - units sit SPDFPaletteSpacing apart; groups are parted by SPDFPaletteSeparator, whose line sits in the middle of the
//   gap between them.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT const CGFloat SPDFPaletteButtonSize;      // 28: icon buttons, and the height of every row 1 control
FOUNDATION_EXPORT const CGFloat SPDFPaletteChevronWidth;    // 14: a split button's ▾ half
FOUNDATION_EXPORT const CGFloat SPDFPaletteSpacing;         // 2: between units, groups and separators
FOUNDATION_EXPORT const CGFloat SPDFPaletteSeparatorWidth;  // 9: a separator with its line in the middle

typedef NS_ENUM(NSInteger, SPDFPaletteSegment) {
    SPDFPaletteSegmentAlone,  // rounded all round
    SPDFPaletteSegmentMain,   // the icon of a split button: rounded on the left
    SPDFPaletteSegmentMenu,   // the ▾ of a split button: rounded on the right
};

@interface SPDFPaletteButton : NSButton
@property(nonatomic) SPDFPaletteSegment segment;
@property(nonatomic, weak, nullable) SPDFPaletteButton* partner;  // the other half of a split button
@property(nonatomic) BOOL trailingChevron;                       // a ▾ after the title (More)
@property(nonatomic, readonly) BOOL hovered;
// The content's width at the button's font: icon, title and ▾ with their padding (a titled button's width).
- (CGFloat)contentWidth;
// The same with another icon before the title (nil: none).
- (CGFloat)contentWidthWithImage:(nullable NSImage*)image;
@end

// An icon-only button: SPDFPaletteButtonSize square, label as its tooltip and accessibility label unless they are set
// afterwards. Its width is a constraint (the palette narrows it in its tightest layout).
FOUNDATION_EXPORT SPDFPaletteButton* SPDFPaletteIconButton(NSString* symbol, NSString* label, id _Nullable target,
                                                           SEL _Nullable action);
// A ▾ button, SPDFPaletteChevronWidth wide.
FOUNDATION_EXPORT SPDFPaletteButton* SPDFPaletteMenuButton(NSString* label, id _Nullable target, SEL _Nullable action);
// A titled button (an icon before the title when symbol is set), as wide as its content.
FOUNDATION_EXPORT SPDFPaletteButton* SPDFPaletteTitleButton(NSString* title, NSString* _Nullable symbol,
                                                            NSString* label, id _Nullable target, SEL _Nullable action);
// Joins an icon button and its ▾ button into one split button (a stack with no gap).
FOUNDATION_EXPORT NSStackView* SPDFPaletteSplit(SPDFPaletteButton* main, SPDFPaletteButton* menu);
// The line between two groups.
FOUNDATION_EXPORT NSView* SPDFPaletteSeparator(void);
// The width constraint a palette factory gave the button (nil for a titled button).
FOUNDATION_EXPORT NSLayoutConstraint* _Nullable SPDFPaletteWidthConstraint(NSView* button);

NS_ASSUME_NONNULL_END
