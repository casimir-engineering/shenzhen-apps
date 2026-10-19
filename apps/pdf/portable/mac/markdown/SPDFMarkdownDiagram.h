#pragma once

#import <AppKit/AppKit.h>

#import "SPDFMarkdownDecorations.h"

NS_ASSUME_NONNULL_BEGIN

// Native diagram rendering for Markdown code fences (Typora's set): mermaid
// (flowchart, sequenceDiagram, pie, stateDiagram/-v2, classDiagram, gantt),
// js-sequence (`sequence` fences) and flowchart.js (`flow` fences). Pure
// parsing plus geometry — no web engine, no JS, no network, NO BITMAPS. Every
// unsupported, malformed or over-budget input returns nil so the caller falls
// through to the exact existing code-box rendering.
//
// The seam is a GEOMETRY seam: it returns a resolved layout — vector shapes
// carrying color ROLES (resolved against a theme variant at draw time) plus
// positioned text labels. The block renderer puts the labels into the
// canonical attributed string (selectable, searchable, vector in PDF export)
// and the shapes travel to the page as one decoration per diagram portion.

// Hard budgets. Exceeding any of them degrades the fence to a code block.
FOUNDATION_EXPORT const NSUInteger SPDFMarkdownDiagramMaximumNodes;        // 200 nodes/actors/slices/tasks
FOUNDATION_EXPORT const NSUInteger SPDFMarkdownDiagramMaximumEdges;        // 400 edges/events
FOUNDATION_EXPORT const NSTimeInterval SPDFMarkdownDiagramLayoutDeadline;  // 50 ms of layout wall-clock
// The budget actually used for one layout: the constant above, unless
// SPDF_DIAGRAM_LAYOUT_DEADLINE overrides it (seconds). A wall-clock budget makes
// any test that lays out a real diagram timing-dependent -- the flowchart suite
// failed 3 of 5 runs on an idle machine -- so the tests raise it and assert
// geometry instead of racing a clock. Production keeps the 50 ms guard.
FOUNDATION_EXPORT NSTimeInterval SPDFMarkdownDiagramLayoutBudget(void);
FOUNDATION_EXPORT const CGFloat SPDFMarkdownDiagramMaximumDimension;       // 2048 pt per diagram axis

// Named palette roles. A resolved layout is theme-INDEPENDENT: every shape and
// label carries a role, and screen, print and export resolve it against the
// variant they draw with (SPDFMarkdownDiagramRoleColor).
typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramRole) {
    SPDFMarkdownDiagramRoleNone = 0,  // no paint at all (unfilled / unstroked)
    SPDFMarkdownDiagramRolePaper,
    SPDFMarkdownDiagramRoleNodeFill,
    SPDFMarkdownDiagramRoleNodeStroke,
    SPDFMarkdownDiagramRoleText,
    SPDFMarkdownDiagramRoleSecondary,
    SPDFMarkdownDiagramRoleAccent,
    SPDFMarkdownDiagramRoleCritical,
    // Six categorical hues for pie slices and chart bars.
    SPDFMarkdownDiagramRoleRamp0,
    SPDFMarkdownDiagramRoleRamp1,
    SPDFMarkdownDiagramRoleRamp2,
    SPDFMarkdownDiagramRoleRamp3,
    SPDFMarkdownDiagramRoleRamp4,
    SPDFMarkdownDiagramRoleRamp5,
};

// The concrete sRGB color for one role under one reading theme. Role None
// resolves to a fully transparent color (nothing is painted).
FOUNDATION_EXPORT NSColor* SPDFMarkdownDiagramRoleColor(SPDFMarkdownDiagramRole role,
                                                        SPDFMarkdownThemeVariant variant);

// One AUTHOR-specified color (a mermaid `classDef` fill/stroke/color) resolved
// for one reading theme.
//
// POLICY: mermaid `classDef` colors are written for mermaid's light default --
// this repo's fixture uses pale fills with dark strokes and near-black text --
// so painting them literally on #1E1E1E paper is unreadable. Light keeps them
// byte for byte. Dark puts them through spdf_recolor's LUMA_REMAP with the
// same paper #1E1E1E / ink #DCDDDE endpoints the reader already applies to
// every PDF page (spdf_recolor.h) and to every image a Markdown document
// embeds (SPDFMarkdownImageRecolor.h). That choice, rather than a bespoke
// contrast forcing, because (a) it is the app's existing answer to exactly
// this question for author-supplied raster color, so a diagram and a
// screenshot of the same diagram now agree; (b) the remap preserves chroma, so
// the author's four hues stay four distinguishable hues; and (c) its luma map
// is strictly DECREASING (Y=0 -> 220, Y=255 -> 30), which makes dark-on-dark
// arithmetically impossible: any fill/text pair the author made legible stays
// legible, with its contrast magnitude preserved and its polarity flipped.
FOUNDATION_EXPORT NSColor* SPDFMarkdownDiagramAuthorColor(NSColor* authored,
                                                          SPDFMarkdownThemeVariant variant);

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramShapeKind) {
    SPDFMarkdownDiagramShapeRectangle = 0,  // rect + cornerRadius (0 = square corners)
    SPDFMarkdownDiagramShapeEllipse,        // rect
    SPDFMarkdownDiagramShapePolygon,        // closed points: diamonds, arrowheads
    SPDFMarkdownDiagramShapePolyline,       // open points: edges, lifelines, rules
    SPDFMarkdownDiagramShapePieSlice,       // center + radius + start/sweep angle
};

// One vector primitive in DIAGRAM-LOCAL points. The space is y-DOWN with its
// origin at the diagram's top-left corner; angles are degrees with 0 at three
// o'clock and a positive sweep running clockwise on screen.
@interface SPDFMarkdownDiagramShape : NSObject
@property(nonatomic) SPDFMarkdownDiagramShapeKind kind;
@property(nonatomic) NSRect rect;          // rectangle / ellipse
@property(nonatomic) CGFloat cornerRadius;
@property(nonatomic, copy) NSArray<NSValue*>* points;  // polygon / polyline
@property(nonatomic) NSPoint center;       // pie slice
@property(nonatomic) CGFloat radius;
@property(nonatomic) CGFloat startAngle;
@property(nonatomic) CGFloat sweepAngle;
@property(nonatomic) SPDFMarkdownDiagramRole fillRole;
@property(nonatomic) SPDFMarkdownDiagramRole strokeRole;
@property(nonatomic) CGFloat fillAlpha;    // multiplies the resolved fill alpha
@property(nonatomic) CGFloat strokeAlpha;
@property(nonatomic) CGFloat lineWidth;
@property(nonatomic) CGFloat dashLength;   // 0 = solid; the gap is 0.75 of it
// Author `classDef` colors overriding the roles above. nil = use the role. A
// layout stays theme-INDEPENDENT: these are the author's own (light) colors,
// resolved per variant at draw time by SPDFMarkdownDiagramAuthorColor.
@property(nonatomic, copy, nullable) NSColor* authorFillColor;
@property(nonatomic, copy, nullable) NSColor* authorStrokeColor;
@end

// One inline emphasis run inside a label line: the `<b>`/`<strong>`,
// `<i>`/`<em>`, `<u>`/`<ins>` and `<s>`/`<strike>`/`<del>` markup mermaid
// labels are written with (see SPDFMarkdownDiagramCleanLabel). `range` indexes
// the label's own `text`.
@interface SPDFMarkdownDiagramLabelSpan : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic) BOOL bold;
@property(nonatomic) BOOL italic;
// Not font traits: the emitter sets these as underline/strikethrough
// attributes on the label's canonical text, which is what the band, the page
// and the PDF export all draw from.
@property(nonatomic) BOOL underline;
@property(nonatomic) BOOL strikethrough;
@end

// One single-line text label at its resolved position. `frame` is the box the
// text aligns inside (diagram-local, y-down, exactly one line tall); the
// measurement pass centers/left-aligns the real typographic width inside it.
@interface SPDFMarkdownDiagramLabel : NSObject
@property(nonatomic, copy) NSString* text;
@property(nonatomic) NSRect frame;
@property(nonatomic) NSTextAlignment alignment;
@property(nonatomic) CGFloat fontSize;
@property(nonatomic) BOOL semibold;
// The label's inline emphasis runs, already clipped to this line by the
// wrapper. Spans, not fonts, so the fit scale keeps owning the size: every
// consumer rebuilds the face from `fontSize` through -fontForSpan:.
@property(nonatomic, copy) NSArray<SPDFMarkdownDiagramLabelSpan*>* spans;
@property(nonatomic) SPDFMarkdownDiagramRole role;
@property(nonatomic, copy, nullable) NSColor* authorColor;  // classDef `color:`; nil = use the role
// The system font this label was measured with, rebuilt from fontSize/semibold.
- (NSFont*)font;
// That same font with one span's emphasis applied — the face that span was
// measured in and has to be drawn in.
- (NSFont*)fontForSpan:(SPDFMarkdownDiagramLabelSpan*)span;
@end

// The color a shape/label actually paints with: its author color resolved for
// `variant` when it has one, else its role. Every draw site goes through these
// so author styling can never be honored in one output and dropped in another.
FOUNDATION_EXPORT NSColor* SPDFMarkdownDiagramShapeFillColor(SPDFMarkdownDiagramShape* shape,
                                                             SPDFMarkdownThemeVariant variant);
FOUNDATION_EXPORT NSColor* SPDFMarkdownDiagramShapeStrokeColor(SPDFMarkdownDiagramShape* shape,
                                                               SPDFMarkdownThemeVariant variant);
FOUNDATION_EXPORT NSColor* SPDFMarkdownDiagramLabelColor(SPDFMarkdownDiagramLabel* label,
                                                         SPDFMarkdownThemeVariant variant);

// A finished diagram: its logical size in points plus the vector shapes and
// text labels that fill it. Already fitted to the caller's content BOX — one
// common factor scales geometry AND label font sizes, never a clip.
@interface SPDFMarkdownDiagramLayout : NSObject
@property(nonatomic, readonly) NSSize size;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownDiagramShape*>* shapes;
@property(nonatomic, readonly, copy) NSArray<SPDFMarkdownDiagramLabel*>* labels;
@end

// Thread-safe render cache keyed by (source, language, fontScale, content box).
// Failed parses are cached too, so a rerender never re-parses a malformed
// fence. Owned per document/session and threaded through
// SPDFMarkdownRenderOptions.diagramCache; text-size and PAPER rerenders hit it
// (turning the paper changes the box, so it is part of the key), and a THEME
// switch reuses it outright (a layout carries roles, not colors).
@interface SPDFMarkdownDiagramCache : NSObject
@property(nonatomic, readonly) NSUInteger count;
- (void)removeAllEntries;
@end

// YES when the fence identifier names a diagram fence (mermaid / sequence /
// flow, case-insensitive first token). O(1); safe to call on every code fence.
FOUNDATION_EXPORT BOOL SPDFMarkdownDiagramIsDiagramLanguage(NSString* _Nullable fenceIdentifier);

// The smallest effective label size a fitted diagram may be left at before the
// flowchart family is allowed to RE-LAY-OUT itself narrower rather than shrink
// further (SPDFMarkdownDiagramLayOutGraph). 7 pt is where the system font stops
// being readable at 100% zoom; it is a trigger, not a guarantee -- a diagram
// whose content simply cannot fit the page still ends up under it, and the
// vector artwork is then read by zooming or by turning the paper.
FOUNDATION_EXPORT const CGFloat SPDFMarkdownDiagramLegibleLabelSize;

// The single entry seam: (fence language, source, the PAGE BOX the figure has
// to fit, fontScale) -> resolved layout, or nil on ANY parse,
// unsupported-subtype, or over-budget condition. Deterministic per inputs.
//
// `contentBox` is the printable area the diagram will be drawn into, already
// net of whatever air the caller reserves around the band. A zero or negative
// WIDTH refuses the diagram; a zero HEIGHT means "no height budget known", in
// which case the fit is width-only exactly as it always was.
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramRender(
    NSString* fenceIdentifier, NSString* source, NSSize contentBox, CGFloat fontScale,
    SPDFMarkdownDiagramCache* _Nullable cache);

// Test-visible laziness/caching proof: incremented once per actual
// parse+layout attempt (cache hits and non-diagram languages do not count). A
// document with no diagram fences must leave this untouched.
FOUNDATION_EXPORT NSUInteger SPDFMarkdownDiagramWorkCount(void);
FOUNDATION_EXPORT void SPDFMarkdownDiagramResetWorkCount(void);

NS_ASSUME_NONNULL_END
