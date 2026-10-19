#pragma once

#import "SPDFMarkdownDiagram.h"

NS_ASSUME_NONNULL_BEGIN

// Internal model, parser, layout and shape-emitter seams of the diagram engine.
// Everything here is deterministic and side-effect free; the only public
// surface is SPDFMarkdownDiagram.h. Tests import this header directly.

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramNodeShape) {
    SPDFMarkdownDiagramNodeShapeRect = 0,      // id[text]
    SPDFMarkdownDiagramNodeShapeRound,         // id(text)
    SPDFMarkdownDiagramNodeShapeStadium,       // id([text])
    SPDFMarkdownDiagramNodeShapeDiamond,       // id{text}
    SPDFMarkdownDiagramNodeShapeCircle,        // id((text))
    SPDFMarkdownDiagramNodeShapeSubroutine,    // id[[text]] / flow subroutine
    SPDFMarkdownDiagramNodeShapeParallelogram, // flow inputoutput
    SPDFMarkdownDiagramNodeShapeStartDot,      // state [*] source
    SPDFMarkdownDiagramNodeShapeEndDot,        // state [*] target
    SPDFMarkdownDiagramNodeShapeClassBox,      // classDiagram compartments
};

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramLineStyle) {
    SPDFMarkdownDiagramLineStyleSolid = 0,
    SPDFMarkdownDiagramLineStyleDashed,
    SPDFMarkdownDiagramLineStyleThick,
};

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramArrowHead) {
    SPDFMarkdownDiagramArrowHeadNone = 0,
    SPDFMarkdownDiagramArrowHeadArrow,           // filled triangle
    SPDFMarkdownDiagramArrowHeadHollowTriangle,  // class inheritance/realization
    SPDFMarkdownDiagramArrowHeadFilledDiamond,   // class composition
    SPDFMarkdownDiagramArrowHeadHollowDiamond,   // class aggregation
};

// Author-specified per-node colors from a mermaid `classDef`. Every field is
// optional: a nil field means "keep the theme role for this channel", so a
// `classDef` that only sets `fill:` leaves stroke and text on the theme.
@interface SPDFMarkdownDiagramNodeStyle : NSObject
@property(nonatomic, copy, nullable) NSColor* fillColor;
@property(nonatomic, copy, nullable) NSColor* strokeColor;
@property(nonatomic, copy, nullable) NSColor* textColor;
@end

@interface SPDFMarkdownDiagramNode : NSObject
@property(nonatomic, copy) NSString* identifier;
@property(nonatomic, copy) NSString* label;
@property(nonatomic) SPDFMarkdownDiagramNodeShape shape;
// The `:::name` / `class a,b name` class this node carries (nil when none).
@property(nonatomic, copy, nullable) NSString* className;
// classDiagram compartments (nil elsewhere).
@property(nonatomic, copy, nullable) NSArray<NSString*>* memberAttributes;
@property(nonatomic, copy, nullable) NSArray<NSString*>* memberMethods;
// Layout state/results.
@property(nonatomic) NSInteger rank;
@property(nonatomic) NSInteger order;
@property(nonatomic) NSRect frame;
// The measured text block the shape was sized around, centered in `frame`:
// the widest wrapped line by the stack of line heights. This -- not the frame
// -- is what has to sit inside a curved outline, so it is what the sizing
// solves for, and it is how far off center the emitter has to ask the outline
// about before it re-wraps (see SPDFDiagramBoxForBlock).
@property(nonatomic) NSSize labelBlock;
@end

@interface SPDFMarkdownDiagramEdge : NSObject
@property(nonatomic, copy) NSString* fromIdentifier;
@property(nonatomic, copy) NSString* toIdentifier;
@property(nonatomic, copy, nullable) NSString* label;
@property(nonatomic) SPDFMarkdownDiagramLineStyle lineStyle;
@property(nonatomic) SPDFMarkdownDiagramArrowHead head;  // drawn at the `to` end
@property(nonatomic) SPDFMarkdownDiagramArrowHead tail;  // drawn at the `from` end (`<-->`)
// Layout result: the bend points a RANK-SKIPPING edge must pass through, one
// per rank it crosses, in layout coordinates. nil for an edge between adjacent
// ranks (which needs no detour). The emitter curves through them, which is
// what keeps a long edge out of the boxes of the ranks it skips.
@property(nonatomic, copy, nullable) NSArray<NSValue*>* routePoints;
@end

// A directed graph plus flow direction. `vertical` maps TD/TB (and BT via
// `reversed`); horizontal maps LR (RL via `reversed`).
@interface SPDFMarkdownDiagramGraph : NSObject
@property(nonatomic) BOOL vertical;
@property(nonatomic) BOOL reversed;
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramNode*>* nodes;
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramEdge*>* edges;
// `classDef` styles by class name, and the `class a,b name` assignments that
// were stated before their nodes existed (applied once parsing finishes).
@property(nonatomic, readonly) NSMutableDictionary<NSString*, SPDFMarkdownDiagramNodeStyle*>* classStyles;
@property(nonatomic, readonly) NSMutableDictionary<NSString*, NSString*>* classNamesByIdentifier;
- (SPDFMarkdownDiagramNode*)nodeForIdentifier:(NSString*)identifier createWithLabel:(nullable NSString*)label;
- (nullable SPDFMarkdownDiagramNode*)existingNodeForIdentifier:(NSString*)identifier;
// The style a node draws with: its own class, else the `default` class, else nil.
- (nullable SPDFMarkdownDiagramNodeStyle*)styleForNode:(SPDFMarkdownDiagramNode*)node;
// Folds the deferred `class a,b name` assignments onto the nodes.
- (void)applyDeferredClassNames;
@end

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramSequenceEventKind) {
    SPDFMarkdownDiagramSequenceEventMessage = 0,
    SPDFMarkdownDiagramSequenceEventNote,
    SPDFMarkdownDiagramSequenceEventFrameBegin,  // alt/opt/loop/par/rect
    SPDFMarkdownDiagramSequenceEventFrameElse,   // else / and
    SPDFMarkdownDiagramSequenceEventFrameEnd,    // end
    SPDFMarkdownDiagramSequenceEventActivate,
    SPDFMarkdownDiagramSequenceEventDeactivate,
};

typedef NS_ENUM(NSInteger, SPDFMarkdownDiagramNotePosition) {
    SPDFMarkdownDiagramNoteLeftOf = 0,
    SPDFMarkdownDiagramNoteRightOf,
    SPDFMarkdownDiagramNoteOver,
};

@interface SPDFMarkdownDiagramSequenceEvent : NSObject
@property(nonatomic) SPDFMarkdownDiagramSequenceEventKind kind;
@property(nonatomic, copy, nullable) NSString* fromIdentifier;
@property(nonatomic, copy, nullable) NSString* toIdentifier;  // == from for self-messages
@property(nonatomic, copy, nullable) NSString* text;
@property(nonatomic) BOOL dashed;
@property(nonatomic) BOOL arrowhead;
@property(nonatomic) SPDFMarkdownDiagramNotePosition notePosition;
@property(nonatomic, copy, nullable) NSString* frameKeyword;  // alt/opt/loop/...
@end

@interface SPDFMarkdownDiagramSequence : NSObject
@property(nonatomic, copy, nullable) NSString* title;
@property(nonatomic, readonly) NSMutableArray<NSString*>* actorIdentifiers;  // in column order
@property(nonatomic, readonly) NSMutableDictionary<NSString*, NSString*>* actorLabels;
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramSequenceEvent*>* events;
- (NSString*)actorForToken:(NSString*)token;  // registers on first sight
@end

@interface SPDFMarkdownDiagramPieSlice : NSObject
@property(nonatomic, copy) NSString* label;
@property(nonatomic) double value;
@end

@interface SPDFMarkdownDiagramPie : NSObject
@property(nonatomic, copy, nullable) NSString* title;
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramPieSlice*>* slices;
@end

@interface SPDFMarkdownDiagramGanttTask : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy, nullable) NSString* taskIdentifier;
@property(nonatomic) NSInteger startDay;  // days since the chart's epoch
@property(nonatomic) NSInteger endDay;    // exclusive
@property(nonatomic) BOOL done;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL critical;
@end

@interface SPDFMarkdownDiagramGanttSection : NSObject
@property(nonatomic, copy) NSString* name;
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramGanttTask*>* tasks;
@end

@interface SPDFMarkdownDiagramGantt : NSObject
@property(nonatomic, copy, nullable) NSString* title;
@property(nonatomic, copy, nullable) NSDate* epoch;  // day 0
@property(nonatomic, readonly) NSMutableArray<SPDFMarkdownDiagramGanttSection*>* sections;
- (NSUInteger)taskCount;
@end

// Concrete per-variant palette derived from SPDFMarkdownTheme roles: node
// fill/stroke are the code-box roles, text is body text, edges are secondary,
// and the accent ramp starts from the link color with a fixed 6-hue rotation.
@interface SPDFMarkdownDiagramPalette : NSObject
@property(nonatomic, readonly) NSColor* paperColor;
@property(nonatomic, readonly) NSColor* nodeFillColor;
@property(nonatomic, readonly) NSColor* nodeStrokeColor;
@property(nonatomic, readonly) NSColor* textColor;
@property(nonatomic, readonly) NSColor* secondaryColor;
@property(nonatomic, readonly) NSColor* accentColor;
@property(nonatomic, readonly) NSColor* criticalColor;
@property(nonatomic, readonly, copy) NSArray<NSColor*>* accentRamp;  // 6 categorical colors
+ (instancetype)paletteForVariant:(SPDFMarkdownThemeVariant)variant;
@end

// Shared line utilities (SPDFMarkdownDiagramModel.mm).
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMarkdownDiagramSignificantLines(NSString* source);
FOUNDATION_EXPORT NSString* SPDFMarkdownDiagramTrim(NSString* string);
FOUNDATION_EXPORT NSString* SPDFMarkdownDiagramCleanLabel(NSString* label);

// Text helpers shared by every shape emitter (SPDFMarkdownDiagramModel.mm).
// Wrapping is explicit — a diagram label is always ONE line, so the emitters
// break a long string themselves and place each line at its own position.
FOUNDATION_EXPORT NSArray<NSString*>* SPDFMarkdownDiagramWrapText(NSString* text, NSFont* font,
                                                                  CGFloat maximumWidth);
// The same label as an attributed string: `font` everywhere, with the label's
// `<b>`/`<i>` markup turned into real font runs and removed from the text.
// This is what makes measurement honest — the tags contribute no width and a
// bold run is measured in the face it will be drawn in.
FOUNDATION_EXPORT NSAttributedString* SPDFMarkdownDiagramAttributedLabel(NSString* text, NSFont* font);
FOUNDATION_EXPORT NSArray<NSAttributedString*>* SPDFMarkdownDiagramWrapAttributedText(
    NSAttributedString* text, CGFloat maximumWidth);
// The emphasis runs of one wrapped line, in the line's own coordinates.
FOUNDATION_EXPORT NSArray<SPDFMarkdownDiagramLabelSpan*>* SPDFMarkdownDiagramLabelSpans(
    NSAttributedString* line);
// One face's emphasized variant. `<b>` resolves to the SAME semibold the
// diagram already sets its own emphasis in (titles, class names, sequence
// keywords), so one diagram never carries two ideas of bold and a label
// already set in semibold is unchanged. The single mapping measurement and
// drawing share, so a run can never be measured in a face it is not drawn in.
FOUNDATION_EXPORT NSFont* SPDFMarkdownDiagramEmphasizedFont(NSFont* font, BOOL bold, BOOL italic);
FOUNDATION_EXPORT CGFloat SPDFMarkdownDiagramLineHeight(NSFont* font);
FOUNDATION_EXPORT NSSize SPDFMarkdownDiagramMeasureText(NSString* text, NSFont* font, CGFloat maximumWidth);

// The geometry recorder every emitter draws into: it appends vector primitives
// and single-line text labels in DIAGRAM-LOCAL, y-down points (see
// SPDFMarkdownDiagram.h). Every add returns the shape it appended so the
// caller can tune alpha; painting order is emission order.
@interface SPDFMarkdownDiagramCanvas : NSObject
@property(nonatomic, readonly) NSArray<SPDFMarkdownDiagramShape*>* shapes;
@property(nonatomic, readonly) NSArray<SPDFMarkdownDiagramLabel*>* labels;
- (SPDFMarkdownDiagramShape*)addRect:(NSRect)rect
                              radius:(CGFloat)cornerRadius
                                fill:(SPDFMarkdownDiagramRole)fill
                              stroke:(SPDFMarkdownDiagramRole)stroke
                               width:(CGFloat)lineWidth;
- (SPDFMarkdownDiagramShape*)addEllipse:(NSRect)rect
                                   fill:(SPDFMarkdownDiagramRole)fill
                                 stroke:(SPDFMarkdownDiagramRole)stroke
                                  width:(CGFloat)lineWidth;
- (SPDFMarkdownDiagramShape*)addPolygon:(NSArray<NSValue*>*)points
                                   fill:(SPDFMarkdownDiagramRole)fill
                                 stroke:(SPDFMarkdownDiagramRole)stroke
                                  width:(CGFloat)lineWidth;
- (SPDFMarkdownDiagramShape*)addPolyline:(NSArray<NSValue*>*)points
                                  stroke:(SPDFMarkdownDiagramRole)stroke
                                   width:(CGFloat)lineWidth
                                    dash:(CGFloat)dashLength;
- (SPDFMarkdownDiagramShape*)addLineFrom:(NSPoint)start
                                      to:(NSPoint)end
                                  stroke:(SPDFMarkdownDiagramRole)stroke
                                   width:(CGFloat)lineWidth
                                    dash:(CGFloat)dashLength;
- (SPDFMarkdownDiagramShape*)addPieSliceAt:(NSPoint)center
                                    radius:(CGFloat)radius
                                startAngle:(CGFloat)startAngle
                                     sweep:(CGFloat)sweepAngle
                                      fill:(SPDFMarkdownDiagramRole)fill
                                    stroke:(SPDFMarkdownDiagramRole)stroke
                                     width:(CGFloat)lineWidth;
// Wraps `text` to the rect's width and stacks one label per line from the
// rect's top, aligned inside the rect's horizontal box. Returns the labels it
// appended so a caller can tint them with author colors.
- (NSArray<SPDFMarkdownDiagramLabel*>*)addText:(nullable NSString*)text
                                        inRect:(NSRect)rect
                                          font:(NSFont*)font
                                          role:(SPDFMarkdownDiagramRole)role
                                     alignment:(NSTextAlignment)alignment;
@end

// Closes a canvas into a resolved layout at its natural size: refuses (nil)
// any diagram past the dimension budget, then fits an over-sized diagram to
// `contentBox` by scaling geometry AND label font sizes by ONE factor. A zero
// box height means "no height budget", i.e. a width-only fit.
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramFinishLayout(
    SPDFMarkdownDiagramCanvas* canvas, NSSize naturalSize, NSSize contentBox);

// The single common factor `contentBox` imposes on a diagram of `naturalSize`:
// the smaller of the two axis ratios, never above 1. A zero/negative box axis
// does not constrain. Shared so the graph emitter's reflow search and the fit
// itself can never disagree about what "fits" means.
FOUNDATION_EXPORT CGFloat SPDFMarkdownDiagramBoxFit(NSSize naturalSize, NSSize contentBox);

// The categorical ramp role for the nth slice/bar (wraps at six).
FOUNDATION_EXPORT SPDFMarkdownDiagramRole SPDFMarkdownDiagramRampRole(NSUInteger index);

// mermaid node styling (SPDFMarkdownDiagramStyle.mm). Both return NO when the
// statement is not the form they handle OR carries nothing usable, and the
// flowchart parser then SKIPS the line exactly as it did before styling
// existed -- an unreadable `classDef` costs a node its colors, never the whole
// diagram.
FOUNDATION_EXPORT BOOL SPDFMarkdownDiagramParseClassDef(NSString* statement, SPDFMarkdownDiagramGraph* graph);
FOUNDATION_EXPORT BOOL SPDFMarkdownDiagramParseClassAssignment(NSString* statement,
                                                               SPDFMarkdownDiagramGraph* graph);

// Parsers. Every parser returns nil on malformed or over-budget input.
FOUNDATION_EXPORT SPDFMarkdownDiagramGraph* _Nullable SPDFMarkdownDiagramParseMermaidFlowchart(NSString* source);
FOUNDATION_EXPORT SPDFMarkdownDiagramGraph* _Nullable SPDFMarkdownDiagramParseFlowFence(NSString* source);
FOUNDATION_EXPORT SPDFMarkdownDiagramGraph* _Nullable SPDFMarkdownDiagramParseMermaidState(NSString* source);
FOUNDATION_EXPORT SPDFMarkdownDiagramGraph* _Nullable SPDFMarkdownDiagramParseMermaidClass(NSString* source);
FOUNDATION_EXPORT SPDFMarkdownDiagramSequence* _Nullable SPDFMarkdownDiagramParseSequence(NSString* source,
                                                                                          BOOL mermaidSyntax);
FOUNDATION_EXPORT SPDFMarkdownDiagramPie* _Nullable SPDFMarkdownDiagramParsePie(NSString* source);
FOUNDATION_EXPORT SPDFMarkdownDiagramGantt* _Nullable SPDFMarkdownDiagramParseGantt(NSString* source);

// Sugiyama layered layout: ranks via longest path in the flow direction (back
// edges from a DFS sweep are ignored for ranking), routing dummies for every
// rank-skipping edge, median ordering sweeps for crossing reduction, then
// coordinate assignment by weighted isotonic regression -- which straightens
// chains and centers fan-outs on their source while keeping `nodeGap` of clear
// air between boxes as a HARD constraint, so no two node rects can intersect.
// Node frames must carry their measured sizes on entry; on success every frame
// origin is set, every rank-skipping edge carries its `routePoints`, and
// *outSize holds the content bounds. Returns NO when `deadline` passes.
FOUNDATION_EXPORT BOOL SPDFMarkdownDiagramLayoutGraph(SPDFMarkdownDiagramGraph* graph, CGFloat nodeGap,
                                                      CGFloat rankGap, CFAbsoluteTime deadline, NSSize* outSize);

// Draws every edge of an already-positioned graph into `canvas`, in
// `graph.edges` order and BEFORE the node boxes go down (see
// SPDFMarkdownDiagramGraphEdges.mm). Edges are routed as a family, not one at a
// time: the anchors of all the edges sharing one border are spread along it in
// the cross-axis order of their far ends, so a fan-out cannot cross itself
// where it leaves the box. `labelFont` types the chips on labeled edges.
FOUNDATION_EXPORT void SPDFMarkdownDiagramEmitGraphEdges(SPDFMarkdownDiagramCanvas* canvas,
                                                         SPDFMarkdownDiagramGraph* graph, NSFont* labelFont,
                                                         CGFloat scale);

// Shape emitters: measured+laid-out models -> resolved vector layout, or nil
// when a budget is exceeded. fontScale scales every font and gap; `contentBox`
// is the page box the figure has to fit (see SPDFMarkdownDiagramRender).
//
// The graph emitter is the one that can RE-LAY-OUT rather than only rescale: a
// flowchart the box would shrink below SPDFMarkdownDiagramLegibleLabelSize is
// retried with tighter label wrapping, trading width for height until it either
// clears the floor or stops improving.
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramLayOutGraph(
    SPDFMarkdownDiagramGraph* graph, NSSize contentBox, CGFloat fontScale, CFAbsoluteTime deadline);
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramLayOutSequence(
    SPDFMarkdownDiagramSequence* sequence, NSSize contentBox, CGFloat fontScale);
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramLayOutPie(SPDFMarkdownDiagramPie* pie,
                                                                                    NSSize contentBox,
                                                                                    CGFloat fontScale);
FOUNDATION_EXPORT SPDFMarkdownDiagramLayout* _Nullable SPDFMarkdownDiagramLayOutGantt(
    SPDFMarkdownDiagramGantt* gantt, NSSize contentBox, CGFloat fontScale);

NS_ASSUME_NONNULL_END
