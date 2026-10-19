#import "SPDFMarkdownDiagramInternal.h"

// mermaid stateDiagram / stateDiagram-v2 and classDiagram parsers. Both map
// onto the shared graph model and reuse the flowchart layout engine.

// --- stateDiagram ---------------------------------------------------------

static NSString* const kSPDFDiagramStateStart = @"__spdf_state_start__";
static NSString* const kSPDFDiagramStateEnd = @"__spdf_state_end__";

static SPDFMarkdownDiagramNode* SPDFStateNode(SPDFMarkdownDiagramGraph* graph, NSString* token, BOOL isSource) {
    NSString* trimmed = SPDFMarkdownDiagramTrim(token);
    if ([trimmed isEqualToString:@"[*]"]) {
        SPDFMarkdownDiagramNode* node =
            [graph nodeForIdentifier:isSource ? kSPDFDiagramStateStart : kSPDFDiagramStateEnd createWithLabel:@" "];
        node.shape = isSource ? SPDFMarkdownDiagramNodeShapeStartDot : SPDFMarkdownDiagramNodeShapeEndDot;
        node.label = @"";
        return node;
    }
    if (!trimmed.length) return nil;
    // State identifiers are single tokens; anything with spaces is malformed.
    if ([trimmed rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound) return nil;
    SPDFMarkdownDiagramNode* node = [graph nodeForIdentifier:trimmed createWithLabel:nil];
    node.shape = SPDFMarkdownDiagramNodeShapeRound;
    return node;
}

SPDFMarkdownDiagramGraph* SPDFMarkdownDiagramParseMermaidState(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count) return nil;
    NSString* header = [lines.firstObject lowercaseString];
    if (![header isEqualToString:@"statediagram"] && ![header isEqualToString:@"statediagram-v2"]) return nil;
    SPDFMarkdownDiagramGraph* graph = [SPDFMarkdownDiagramGraph new];
    BOOL insideNoteBlock = NO;
    for (NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSString* lowered = line.lowercaseString;
        if (insideNoteBlock) {
            if ([lowered isEqualToString:@"end note"]) insideNoteBlock = NO;
            continue;
        }
        // Composite states are FLATTENED in v1: the braces vanish, members
        // render as ordinary states (documented in markdown/README.md).
        if ([line hasSuffix:@"{"]) line = SPDFMarkdownDiagramTrim([line substringToIndex:line.length - 1]);
        if ([line isEqualToString:@"}"] || !line.length) continue;
        lowered = line.lowercaseString;
        if ([lowered hasPrefix:@"direction "]) {
            NSString* token = SPDFMarkdownDiagramTrim([line substringFromIndex:@"direction ".length]).uppercaseString;
            graph.vertical = !([token isEqualToString:@"LR"] || [token isEqualToString:@"RL"]);
            graph.reversed = [token isEqualToString:@"RL"] || [token isEqualToString:@"BT"];
            continue;
        }
        if ([lowered hasPrefix:@"note "]) {
            if ([line rangeOfString:@":"].location == NSNotFound) insideNoteBlock = YES;
            continue;  // state notes are skipped in v1
        }
        NSRange transition = [line rangeOfString:@"-->"];
        if (transition.location != NSNotFound) {
            NSString* left = [line substringToIndex:transition.location];
            NSString* rest = [line substringFromIndex:NSMaxRange(transition)];
            NSString* label = nil;
            NSRange colon = [rest rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                label = SPDFMarkdownDiagramCleanLabel([rest substringFromIndex:NSMaxRange(colon)]);
                rest = [rest substringToIndex:colon.location];
            }
            SPDFMarkdownDiagramNode* from = SPDFStateNode(graph, left, YES);
            SPDFMarkdownDiagramNode* to = SPDFStateNode(graph, rest, NO);
            if (!from || !to) return nil;
            SPDFMarkdownDiagramEdge* edge = [SPDFMarkdownDiagramEdge new];
            edge.fromIdentifier = from.identifier;
            edge.toIdentifier = to.identifier;
            edge.label = label.length ? label : nil;
            edge.head = SPDFMarkdownDiagramArrowHeadArrow;
            [graph.edges addObject:edge];
        } else if ([lowered hasPrefix:@"state "]) {
            // `state "Description" as s1` or `state s1`.
            NSString* rest = SPDFMarkdownDiagramTrim([line substringFromIndex:@"state ".length]);
            NSRange asRange = [rest rangeOfString:@" as " options:NSCaseInsensitiveSearch];
            if (asRange.location != NSNotFound) {
                NSString* description = SPDFMarkdownDiagramCleanLabel([rest substringToIndex:asRange.location]);
                NSString* identifier = SPDFMarkdownDiagramTrim([rest substringFromIndex:NSMaxRange(asRange)]);
                if (!identifier.length) return nil;
                SPDFMarkdownDiagramNode* node = [graph nodeForIdentifier:identifier createWithLabel:description];
                node.shape = SPDFMarkdownDiagramNodeShapeRound;
            } else if (!SPDFStateNode(graph, rest, YES)) {
                return nil;
            }
        } else {
            // `s1 : description`.
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) return nil;
            NSString* identifier = SPDFMarkdownDiagramTrim([line substringToIndex:colon.location]);
            NSString* description = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:NSMaxRange(colon)]);
            if (!identifier.length || !description.length) return nil;
            SPDFMarkdownDiagramNode* node = [graph nodeForIdentifier:identifier createWithLabel:description];
            node.shape = SPDFMarkdownDiagramNodeShapeRound;
        }
        if (graph.nodes.count > SPDFMarkdownDiagramMaximumNodes ||
            graph.edges.count > SPDFMarkdownDiagramMaximumEdges)
            return nil;
    }
    return graph.nodes.count ? graph : nil;
}

// --- classDiagram ---------------------------------------------------------

// Strips mermaid generic syntax (`List~T~` -> `List<T>`).
static NSString* SPDFClassCleanMember(NSString* member) {
    NSString* text = SPDFMarkdownDiagramCleanLabel(member);
    NSMutableString* result = [NSMutableString string];
    BOOL open = YES;
    for (NSUInteger index = 0; index < text.length; ++index) {
        unichar character = [text characterAtIndex:index];
        if (character == '~') {
            [result appendString:open ? @"<" : @">"];
            open = !open;
        } else {
            [result appendFormat:@"%C", character];
        }
    }
    return result;
}

static SPDFMarkdownDiagramNode* SPDFClassNode(SPDFMarkdownDiagramGraph* graph, NSString* token) {
    NSString* name = SPDFMarkdownDiagramTrim(token);
    NSRange tilde = [name rangeOfString:@"~"];
    if (tilde.location != NSNotFound) name = SPDFClassCleanMember(name);
    if (!name.length ||
        [name rangeOfCharacterFromSet:NSCharacterSet.whitespaceCharacterSet].location != NSNotFound)
        return nil;
    SPDFMarkdownDiagramNode* node = [graph nodeForIdentifier:name createWithLabel:name];
    node.shape = SPDFMarkdownDiagramNodeShapeClassBox;
    if (!node.memberAttributes) node.memberAttributes = @[];
    if (!node.memberMethods) node.memberMethods = @[];
    return node;
}

static void SPDFClassAddMember(SPDFMarkdownDiagramNode* node, NSString* member) {
    NSString* text = SPDFClassCleanMember(member);
    if (!text.length) return;
    if ([text containsString:@"("])
        node.memberMethods = [(node.memberMethods ?: @[]) arrayByAddingObject:text];
    else
        node.memberAttributes = [(node.memberAttributes ?: @[]) arrayByAddingObject:text];
}

// Relation operators in match precedence order: (pattern, head at the marker
// side, dashed). `<|--` places its marker on the LEFT class, `--|>` on the
// RIGHT; edges are normalized so the head always sits at `toIdentifier`.
typedef struct {
    __unsafe_unretained NSString* token;
    SPDFMarkdownDiagramArrowHead head;
    BOOL dashed;
    BOOL markerOnLeft;
} SPDFClassRelation;

static const SPDFClassRelation kSPDFClassRelations[] = {
    {@"<|..", SPDFMarkdownDiagramArrowHeadHollowTriangle, YES, YES},
    {@"..|>", SPDFMarkdownDiagramArrowHeadHollowTriangle, YES, NO},
    {@"<|--", SPDFMarkdownDiagramArrowHeadHollowTriangle, NO, YES},
    {@"--|>", SPDFMarkdownDiagramArrowHeadHollowTriangle, NO, NO},
    {@"*--", SPDFMarkdownDiagramArrowHeadFilledDiamond, NO, YES},
    {@"--*", SPDFMarkdownDiagramArrowHeadFilledDiamond, NO, NO},
    {@"o--", SPDFMarkdownDiagramArrowHeadHollowDiamond, NO, YES},
    {@"--o", SPDFMarkdownDiagramArrowHeadHollowDiamond, NO, NO},
    {@"<--", SPDFMarkdownDiagramArrowHeadArrow, NO, YES},
    {@"-->", SPDFMarkdownDiagramArrowHeadArrow, NO, NO},
    {@"<..", SPDFMarkdownDiagramArrowHeadArrow, YES, YES},
    {@"..>", SPDFMarkdownDiagramArrowHeadArrow, YES, NO},
    {@"--", SPDFMarkdownDiagramArrowHeadNone, NO, NO},
    {@"..", SPDFMarkdownDiagramArrowHeadNone, YES, NO},
};

SPDFMarkdownDiagramGraph* SPDFMarkdownDiagramParseMermaidClass(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count || ![lines.firstObject.lowercaseString isEqualToString:@"classdiagram"]) return nil;
    SPDFMarkdownDiagramGraph* graph = [SPDFMarkdownDiagramGraph new];
    SPDFMarkdownDiagramNode* openClass = nil;
    for (NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        if (openClass) {
            if ([line isEqualToString:@"}"]) {
                openClass = nil;
            } else {
                SPDFClassAddMember(openClass, line);
            }
            continue;
        }
        if ([line.lowercaseString hasPrefix:@"direction "]) continue;
        if ([line.lowercaseString hasPrefix:@"class "]) {
            NSString* rest = SPDFMarkdownDiagramTrim([line substringFromIndex:@"class ".length]);
            BOOL opensBlock = [rest hasSuffix:@"{"];
            if (opensBlock) rest = SPDFMarkdownDiagramTrim([rest substringToIndex:rest.length - 1]);
            SPDFMarkdownDiagramNode* node = SPDFClassNode(graph, rest);
            if (!node) return nil;
            if (opensBlock) openClass = node;
            if (graph.nodes.count > SPDFMarkdownDiagramMaximumNodes) return nil;
            continue;
        }
        // Relation with optional trailing `: label`; cardinality strings
        // (quoted tokens beside the operator) are dropped in v1.
        NSString* label = nil;
        NSString* body = line;
        NSRange colon = [line rangeOfString:@" : "];
        if (colon.location != NSNotFound) {
            label = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:NSMaxRange(colon)]);
            body = [line substringToIndex:colon.location];
        }
        BOOL matched = NO;
        for (NSUInteger relation = 0; relation < sizeof(kSPDFClassRelations) / sizeof(*kSPDFClassRelations);
             ++relation) {
            SPDFClassRelation spec = kSPDFClassRelations[relation];
            NSRange operatorRange = [body rangeOfString:spec.token];
            if (operatorRange.location == NSNotFound) continue;
            NSString* left = [body substringToIndex:operatorRange.location];
            NSString* right = [body substringFromIndex:NSMaxRange(operatorRange)];
            // Drop cardinalities: `A "1" --> "many" B`.
            left = [left stringByReplacingOccurrencesOfString:@"\"[^\"]*\"" withString:@""
                                                      options:NSRegularExpressionSearch
                                                        range:NSMakeRange(0, left.length)];
            right = [right stringByReplacingOccurrencesOfString:@"\"[^\"]*\"" withString:@""
                                                        options:NSRegularExpressionSearch
                                                          range:NSMakeRange(0, right.length)];
            SPDFMarkdownDiagramNode* leftNode = SPDFClassNode(graph, left);
            SPDFMarkdownDiagramNode* rightNode = SPDFClassNode(graph, right);
            if (!leftNode || !rightNode) return nil;
            SPDFMarkdownDiagramEdge* edge = [SPDFMarkdownDiagramEdge new];
            edge.fromIdentifier = spec.markerOnLeft ? rightNode.identifier : leftNode.identifier;
            edge.toIdentifier = spec.markerOnLeft ? leftNode.identifier : rightNode.identifier;
            edge.label = label.length ? label : nil;
            edge.lineStyle = spec.dashed ? SPDFMarkdownDiagramLineStyleDashed : SPDFMarkdownDiagramLineStyleSolid;
            edge.head = spec.head;
            [graph.edges addObject:edge];
            matched = YES;
            break;
        }
        if (!matched) {
            // Member shorthand: `ClassName : +member`.
            NSRange memberColon = [line rangeOfString:@":"];
            if (memberColon.location == NSNotFound) return nil;
            SPDFMarkdownDiagramNode* node = SPDFClassNode(graph, [line substringToIndex:memberColon.location]);
            if (!node) return nil;
            SPDFClassAddMember(node, [line substringFromIndex:NSMaxRange(memberColon)]);
        }
        if (graph.nodes.count > SPDFMarkdownDiagramMaximumNodes ||
            graph.edges.count > SPDFMarkdownDiagramMaximumEdges)
            return nil;
    }
    return graph.nodes.count && !openClass ? graph : nil;
}
