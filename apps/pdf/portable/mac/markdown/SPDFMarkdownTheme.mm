#import "SPDFMarkdownDecorations.h"

static NSColor* SPDFRGB(unsigned int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0
                               green:((hex >> 8) & 0xff) / 255.0
                                blue:(hex & 0xff) / 255.0
                               alpha:1];
}

// The Markdown page renders as its theme's paper in every app appearance
// (PDF parity), so screen, print and export share one concrete sRGB palette
// per variant. Light is GitHub-Primer: near-black #1F2328 text on white paper,
// #59636E muted roles, #D0D7DE/#D1D9E0 border grays. Dark is Obsidian-default:
// #DCDDDE text on #1E1E1E paper, #999999 muted roles, #333333 hairlines,
// #262626/#2A2A2A code surfaces, the #7F6DF2 Obsidian purple accent, and an
// Obsidian-flavored token set readable on #262626.
@implementation SPDFMarkdownTheme
- (instancetype)initWithVariant:(SPDFMarkdownThemeVariant)variant {
    self = [super init];
    if (!self) return nil;
    BOOL dark = variant == SPDFMarkdownThemeVariantDark;
    _variant = variant;
    _paperColor = SPDFRGB(dark ? 0x1E1E1E : 0xFFFFFF);
    _paperBorderColor = SPDFRGB(dark ? 0x3D3D3D : 0xD0D7DE);
    // nil in Light: every frontend keeps the system gutter it already used.
    _viewportBackgroundColor = dark ? SPDFRGB(0x0A0A0A) : nil;
    _drawsPaperShadow = !dark;
    _bodyTextColor = SPDFRGB(dark ? 0xDCDDDE : 0x1F2328);
    _secondaryTextColor = SPDFRGB(dark ? 0x999999 : 0x59636E);
    _linkColor = SPDFRGB(dark ? 0x7F6DF2 : 0x0969DA);
    _inlineCodeChipColor = SPDFRGB(dark ? 0x2A2A2A : 0xEFF1F2);
    // GitHub's <mark> yellow in light; in dark, the same hue sunk into the
    // paper so the body text on top keeps its contrast.
    _markHighlightColor = SPDFRGB(dark ? 0x4A3B12 : 0xFFF8C5);
    _syntaxCommentColor = SPDFRGB(dark ? 0x7F848E : 0x59636E);
    _syntaxStringColor = SPDFRGB(dark ? 0x98C379 : 0x0A3069);
    _syntaxNumberColor = SPDFRGB(dark ? 0xD19A66 : 0x0550AE);
    _syntaxKeyColor = SPDFRGB(dark ? 0xE5C07B : 0x953800);
    _syntaxMarkupColor = SPDFRGB(dark ? 0x61AFEF : 0x8250DF);
    _syntaxKeywordColor = SPDFRGB(dark ? 0xC678DD : 0xCF222E);
    _codeBoxFillColor = SPDFRGB(dark ? 0x262626 : 0xF6F8FA);
    _codeBoxStrokeColor = SPDFRGB(dark ? 0x363636 : 0xD0D7DE);
    _codeControlFillColor = SPDFRGB(dark ? 0x2A2A2A : 0xEAEEF2);
    _codeControlStrokeColor = SPDFRGB(dark ? 0x363636 : 0xD0D7DE);
    _codeControlTextColor = SPDFRGB(dark ? 0x999999 : 0x59636E);
    _headingRuleColor = SPDFRGB(dark ? 0x333333 : 0xD1D9E0);
    _thematicBreakRuleColor = SPDFRGB(dark ? 0x333333 : 0xD1D9E0);
    _tableGridColor = SPDFRGB(dark ? 0x333333 : 0xD1D9E0);
    _tableHeaderFillColor = SPDFRGB(dark ? 0x262626 : 0xEAEEF2);
    _tableStripeFillColor = SPDFRGB(dark ? 0x232323 : 0xFAFBFC);
    _imagePlaceholderFillColor = SPDFRGB(dark ? 0x262626 : 0xF6F8FA);
    _imagePlaceholderStrokeColor = SPDFRGB(dark ? 0x333333 : 0xD1D9E0);
    return self;
}
// One cached immutable palette per variant: theme lookups on the render and
// draw paths never allocate.
+ (SPDFMarkdownTheme*)themeForVariant:(SPDFMarkdownThemeVariant)variant {
    static SPDFMarkdownTheme* light;
    static SPDFMarkdownTheme* dark;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      light = [[SPDFMarkdownTheme alloc] initWithVariant:SPDFMarkdownThemeVariantLight];
      dark = [[SPDFMarkdownTheme alloc] initWithVariant:SPDFMarkdownThemeVariantDark];
    });
    return variant == SPDFMarkdownThemeVariantDark ? dark : light;
}
+ (SPDFMarkdownTheme*)lightTheme { return [self themeForVariant:SPDFMarkdownThemeVariantLight]; }
+ (NSColor*)bodyTextColor { return self.lightTheme.bodyTextColor; }
+ (NSColor*)secondaryTextColor { return self.lightTheme.secondaryTextColor; }
+ (NSColor*)linkColor { return self.lightTheme.linkColor; }
+ (NSColor*)inlineCodeChipColor { return self.lightTheme.inlineCodeChipColor; }
+ (NSColor*)syntaxCommentColor { return self.lightTheme.syntaxCommentColor; }
+ (NSColor*)syntaxStringColor { return self.lightTheme.syntaxStringColor; }
+ (NSColor*)syntaxNumberColor { return self.lightTheme.syntaxNumberColor; }
+ (NSColor*)syntaxKeyColor { return self.lightTheme.syntaxKeyColor; }
+ (NSColor*)syntaxMarkupColor { return self.lightTheme.syntaxMarkupColor; }
+ (NSColor*)syntaxKeywordColor { return self.lightTheme.syntaxKeywordColor; }
+ (NSColor*)codeBoxFillColor { return self.lightTheme.codeBoxFillColor; }
+ (NSColor*)codeBoxStrokeColor { return self.lightTheme.codeBoxStrokeColor; }
+ (NSColor*)headingRuleColor { return self.lightTheme.headingRuleColor; }
+ (NSColor*)thematicBreakRuleColor { return self.lightTheme.thematicBreakRuleColor; }
+ (NSColor*)tableGridColor { return self.lightTheme.tableGridColor; }
+ (NSColor*)tableHeaderFillColor { return self.lightTheme.tableHeaderFillColor; }
+ (NSColor*)tableStripeFillColor { return self.lightTheme.tableStripeFillColor; }
+ (NSColor*)codeControlFillColor { return self.lightTheme.codeControlFillColor; }
+ (NSColor*)codeControlStrokeColor { return self.lightTheme.codeControlStrokeColor; }
+ (NSColor*)codeControlTextColor { return self.lightTheme.codeControlTextColor; }
+ (NSColor*)printCodeBoxFillColor { return self.lightTheme.codeBoxFillColor; }
+ (NSColor*)printCodeBoxStrokeColor { return self.lightTheme.codeBoxStrokeColor; }
+ (NSColor*)printHeadingRuleColor { return self.lightTheme.headingRuleColor; }
@end
