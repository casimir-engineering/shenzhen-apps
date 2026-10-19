#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class SPDFMarkdownDiagramLayout;
@class SPDFMarkdownPage;
@class SPDFMarkdownPaginationItem;

typedef NS_ENUM(NSInteger, SPDFMarkdownPageDecorationType) {
    SPDFMarkdownPageDecorationTypeCodeBox,
    SPDFMarkdownPageDecorationTypeHeadingRule,
    SPDFMarkdownPageDecorationTypeThematicBreakRule,
    // GitHub-style table chrome: a header-row fill band, a subtle fill on
    // alternating body rows, and the 1px hairline grid (horizontal row
    // boundaries plus vertical column boundaries).
    SPDFMarkdownPageDecorationTypeTableHeaderBand,
    SPDFMarkdownPageDecorationTypeTableStripe,
    SPDFMarkdownPageDecorationTypeTableGridLine,
    // One native diagram's vector artwork: the decoration carries the whole
    // resolved shape list (see diagramLayout below), never a bitmap.
    SPDFMarkdownPageDecorationTypeDiagram,
};

// The user-switchable reading theme. Light is the GitHub-Primer palette the
// reader has always used (and stays the default); Dark is an Obsidian-default
// flavored dark palette. A variant is a set of constants, not a subsystem:
// it is threaded explicitly through SPDFMarkdownRenderOptions.themeVariant
// (render-time colors) and SPDFMarkdownPageConfiguration.themeVariant
// (draw-time chrome), never through global or appearance-dynamic state.
typedef NS_ENUM(NSInteger, SPDFMarkdownThemeVariant) {
    SPDFMarkdownThemeVariantLight = 0,
    SPDFMarkdownThemeVariantDark = 1,
};

// The PAPER a document is laid out on, the theme variant's sibling: another set
// of constants threaded explicitly onto SPDFMarkdownPageConfiguration (which
// owns the paper size and printable rect the two orientations differ in).
//
// Landscape swaps the two paper edges and the document RE-FLOWS onto the wider,
// shorter pages; it is never a rotation of a finished rendition, so every glyph
// stays upright. That is the whole difference between rotating a Markdown
// document and rotating a PDF page, whose rendered pixels really do turn.
typedef NS_ENUM(NSInteger, SPDFMarkdownPageOrientation) {
    SPDFMarkdownPageOrientationPortrait = 0,
    SPDFMarkdownPageOrientationLandscape = 1,
};

// Unpainted page margin kept between a code box edge and its neighbors. The
// paginator reserves it inside the code item's spacer bands; the decoration
// geometry insets the drawn box by the same amount, so two consecutive code
// boxes end up two margins apart. The screen code-language control centers in
// the leading band below this margin.
FOUNDATION_EXPORT const CGFloat SPDFMarkdownCodeBoxOuterMargin;

// The reading palettes. Every color is a concrete sRGB constant — no dynamic
// colors anywhere — so screen, print and export always draw exactly the same
// page for the active variant (appearance flips can never corrupt output).
// +themeForVariant: returns one cached immutable palette per variant; every
// element takes a named role from it instead of an ad-hoc NSColor. The
// zero-argument class accessors are aliases for the LIGHT palette, kept so
// light-only call sites and existing expectations stay byte-identical; the
// print-prefixed names are further light aliases for legacy export call sites.
@interface SPDFMarkdownTheme : NSObject
@property(nonatomic, readonly) SPDFMarkdownThemeVariant variant;
+ (SPDFMarkdownTheme*)themeForVariant:(SPDFMarkdownThemeVariant)variant;
// Paper roles. Light paper is pure white with the canvas drop shadow; dark
// paper is Obsidian's #1E1E1E and the canvas draws paperBorderColor instead
// of a shadow.
@property(nonatomic, readonly) NSColor* paperColor;        // #FFFFFF / #1E1E1E
@property(nonatomic, readonly) NSColor* paperBorderColor;  // #D0D7DE / #333333
// The viewport gutter behind the sheets (Markdown canvas AND the PDF/document
// scroll view read this one role). Dark is #121212, deliberately well below the
// #1E1E1E paper so a page edge always reads. LIGHT IS nil, meaning "keep the
// system gutter this surface already used" — the Markdown canvas's
// windowBackgroundColor and the document view's slightly darkened derivative
// are unchanged, byte for byte, by the theme work.
@property(nonatomic, readonly, nullable) NSColor* viewportBackgroundColor;  // nil / #121212
// Paper presentation, shared by both frontends: light draws the classic drop
// shadow, dark draws a crisp 1px paperBorderColor frame instead (a black
// shadow is invisible on a dark gutter, so only one page edge would read).
@property(nonatomic, readonly) BOOL drawsPaperShadow;  // YES / NO
// Text roles.
@property(nonatomic, readonly) NSColor* bodyTextColor;       // #1F2328 / #DCDDDE body and headings
@property(nonatomic, readonly) NSColor* secondaryTextColor;  // #59636E / #999999 muted: markers, captions, quotes, H6
@property(nonatomic, readonly) NSColor* linkColor;           // #0969DA / #7F6DF2 links and accents
@property(nonatomic, readonly) NSColor* inlineCodeChipColor; // #EFF1F2 / #2A2A2A inline-code and kbd chips
@property(nonatomic, readonly) NSColor* markHighlightColor;  // #FFF8C5 / #4A3B12 <mark> background
// Syntax token roles (Primer light / Obsidian-flavored dark).
@property(nonatomic, readonly) NSColor* syntaxCommentColor;  // #59636E / #7F848E
@property(nonatomic, readonly) NSColor* syntaxStringColor;   // #0A3069 / #98C379
@property(nonatomic, readonly) NSColor* syntaxNumberColor;   // #0550AE / #D19A66
@property(nonatomic, readonly) NSColor* syntaxKeyColor;      // #953800 / #E5C07B
@property(nonatomic, readonly) NSColor* syntaxMarkupColor;   // #8250DF / #61AFEF
@property(nonatomic, readonly) NSColor* syntaxKeywordColor;  // #CF222E / #C678DD
// Page chrome roles.
@property(nonatomic, readonly) NSColor* codeBoxFillColor;    // #F6F8FA / #262626
@property(nonatomic, readonly) NSColor* codeBoxStrokeColor;  // #D0D7DE / #363636
// Quiet chrome for the interactive language pill drawn inside a code box.
@property(nonatomic, readonly) NSColor* codeControlFillColor;    // #EAEEF2 / #2A2A2A
@property(nonatomic, readonly) NSColor* codeControlStrokeColor;  // #D0D7DE / #363636
@property(nonatomic, readonly) NSColor* codeControlTextColor;    // #59636E / #999999
@property(nonatomic, readonly) NSColor* headingRuleColor;        // #D1D9E0 / #333333
@property(nonatomic, readonly) NSColor* thematicBreakRuleColor;  // #D1D9E0 / #333333
// Table chrome roles, Primer-flavored like the code box.
@property(nonatomic, readonly) NSColor* tableGridColor;        // #D1D9E0 / #333333 1px hairline grid
@property(nonatomic, readonly) NSColor* tableHeaderFillColor;  // #EAEEF2 / #262626 header band
@property(nonatomic, readonly) NSColor* tableStripeFillColor;  // #FAFBFC / #232323 alternating rows
// Remote-image pending placeholder box (future diagram placeholders too).
@property(nonatomic, readonly) NSColor* imagePlaceholderFillColor;    // #F6F8FA / #262626
@property(nonatomic, readonly) NSColor* imagePlaceholderStrokeColor;  // #D1D9E0 / #333333
// LIGHT-palette aliases (see the class comment).
+ (NSColor*)bodyTextColor;
+ (NSColor*)secondaryTextColor;
+ (NSColor*)linkColor;
+ (NSColor*)inlineCodeChipColor;
+ (NSColor*)syntaxCommentColor;
+ (NSColor*)syntaxStringColor;
+ (NSColor*)syntaxNumberColor;
+ (NSColor*)syntaxKeyColor;
+ (NSColor*)syntaxMarkupColor;
+ (NSColor*)syntaxKeywordColor;
+ (NSColor*)codeBoxFillColor;
+ (NSColor*)codeBoxStrokeColor;
+ (NSColor*)codeControlFillColor;
+ (NSColor*)codeControlStrokeColor;
+ (NSColor*)codeControlTextColor;
+ (NSColor*)headingRuleColor;
+ (NSColor*)thematicBreakRuleColor;
+ (NSColor*)tableGridColor;
+ (NSColor*)tableHeaderFillColor;
+ (NSColor*)tableStripeFillColor;
+ (NSColor*)printCodeBoxFillColor;
+ (NSColor*)printCodeBoxStrokeColor;
+ (NSColor*)printHeadingRuleColor;
@end

// One drawable decoration on one page. The rect is in page-content coordinates:
// x is relative to the printable rect's left edge and y is the offset from the
// printable top, the same space as SPDFMarkdownPageFragment.pageYOffset.
@interface SPDFMarkdownPageDecoration : NSObject
@property(nonatomic, readonly) SPDFMarkdownPageDecorationType type;
@property(nonatomic, readonly) NSRect rect;
@property(nonatomic, readonly) NSUInteger blockIndex;
// Non-nil only for SPDFMarkdownPageDecorationTypeDiagram: the resolved vector
// layout whose shapes fill `rect`. The layout's own size gives the drawing
// scale (rect width over layout width), so an over-tall scaled band and a
// natural one share one painting path.
@property(nonatomic, readonly, nullable) SPDFMarkdownDiagramLayout* diagramLayout;
- (instancetype)initWithType:(SPDFMarkdownPageDecorationType)type
                        rect:(NSRect)rect
                  blockIndex:(NSUInteger)blockIndex
               diagramLayout:(nullable SPDFMarkdownDiagramLayout*)diagramLayout NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithType:(SPDFMarkdownPageDecorationType)type
                        rect:(NSRect)rect
                  blockIndex:(NSUInteger)blockIndex;
- (instancetype)init NS_UNAVAILABLE;
@end

// Computes the decorations for one planned page. A code item contributes one
// full-printable-width box per page portion covering its reserved spacer bands
// (inset by SPDFMarkdownCodeBoxOuterMargin at the item's true top and bottom);
// level 1 and 2 headings contribute a 1px underline rule; a thematic break
// contributes a 2px full-width rule centered in its reserved line.
FOUNDATION_EXPORT NSArray<SPDFMarkdownPageDecoration*>* SPDFMarkdownDecorationsForPage(
    SPDFMarkdownPage* page, NSArray<SPDFMarkdownPaginationItem*>* items, CGFloat printableWidth);

NS_ASSUME_NONNULL_END
