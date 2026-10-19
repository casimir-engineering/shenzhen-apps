#import "SPDFMarkdownDiagramInternal.h"

// Parsers producing SPDFMarkdownDiagramGraph from mermaid flowchart syntax
// (`graph TD` / `flowchart LR` ...) and from flowchart.js syntax (`flow`
// fences). Anything outside the supported grammar fails the WHOLE diagram
// (return nil) so the fence degrades to the ordinary code box.

// --- Small scanner over one statement -----------------------------------

typedef struct {
    NSString* text;
    NSUInteger position;
} SPDFDiagramScanner;

static void SPDFScanSkipSpaces(SPDFDiagramScanner* scanner) {
    while (scanner->position < scanner->text.length &&
           [NSCharacterSet.whitespaceCharacterSet characterIsMember:[scanner->text
                                                                        characterAtIndex:scanner->position]])
        ++scanner->position;
}

static unichar SPDFScanPeek(SPDFDiagramScanner* scanner, NSUInteger offset) {
    NSUInteger index = scanner->position + offset;
    return index < scanner->text.length ? [scanner->text characterAtIndex:index] : 0;
}

static BOOL SPDFIsIdentifierCharacter(unichar character) {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') ||
           (character >= '0' && character <= '9') || character == '_' || character == '.' || character == '-';
}

static NSString* SPDFScanIdentifier(SPDFDiagramScanner* scanner) {
    NSUInteger start = scanner->position;
    while (scanner->position < scanner->text.length && SPDFIsIdentifierCharacter(SPDFScanPeek(scanner, 0))) {
        // An identifier never swallows the `-->` / `-.->` edge operator: stop
        // at a `-` or `.` that starts a connector run.
        unichar current = SPDFScanPeek(scanner, 0);
        if (current == '-' || current == '.') {
            unichar next = SPDFScanPeek(scanner, 1);
            if (next == '-' || next == '.' || next == '>') break;
        }
        ++scanner->position;
    }
    return [scanner->text substringWithRange:NSMakeRange(start, scanner->position - start)];
}

// Scans a bracketed label up to `closer` (two-character closers supported).
static NSString* SPDFScanLabelUntil(SPDFDiagramScanner* scanner, NSString* closer) {
    NSUInteger start = scanner->position;
    while (scanner->position < scanner->text.length) {
        BOOL matches = YES;
        for (NSUInteger index = 0; index < closer.length; ++index) {
            if (SPDFScanPeek(scanner, index) != [closer characterAtIndex:index]) {
                matches = NO;
                break;
            }
        }
        if (matches) {
            NSString* label = [scanner->text substringWithRange:NSMakeRange(start, scanner->position - start)];
            scanner->position += closer.length;
            return label;
        }
        ++scanner->position;
    }
    return nil;  // unterminated shape
}

// Parses `id` with an optional shape suffix. Returns nil on failure.
static SPDFMarkdownDiagramNode* SPDFScanNode(SPDFDiagramScanner* scanner, SPDFMarkdownDiagramGraph* graph) {
    SPDFScanSkipSpaces(scanner);
    NSString* identifier = SPDFScanIdentifier(scanner);
    if (!identifier.length) return nil;
    SPDFMarkdownDiagramNodeShape shape = SPDFMarkdownDiagramNodeShapeRect;
    NSString* label = nil;
    unichar opener = SPDFScanPeek(scanner, 0);
    unichar second = SPDFScanPeek(scanner, 1);
    NSString* closer = nil;
    if (opener == '(' && second == '(') {
        shape = SPDFMarkdownDiagramNodeShapeCircle;
        scanner->position += 2;
        closer = @"))";
    } else if (opener == '(' && second == '[') {
        shape = SPDFMarkdownDiagramNodeShapeStadium;
        scanner->position += 2;
        closer = @"])";
    } else if (opener == '(') {
        shape = SPDFMarkdownDiagramNodeShapeRound;
        scanner->position += 1;
        closer = @")";
    } else if (opener == '[' && second == '[') {
        shape = SPDFMarkdownDiagramNodeShapeSubroutine;
        scanner->position += 2;
        closer = @"]]";
    } else if (opener == '[' && second == '(') {
        // Database/cylinder: rendered as a stadium in v1.
        shape = SPDFMarkdownDiagramNodeShapeStadium;
        scanner->position += 2;
        closer = @")]";
    } else if (opener == '[' && second == '/') {
        shape = SPDFMarkdownDiagramNodeShapeParallelogram;
        scanner->position += 2;
        closer = @"/]";
    } else if (opener == '[') {
        shape = SPDFMarkdownDiagramNodeShapeRect;
        scanner->position += 1;
        closer = @"]";
    } else if (opener == '{' && second == '{') {
        // Hexagon: rendered as a stadium in v1.
        shape = SPDFMarkdownDiagramNodeShapeStadium;
        scanner->position += 2;
        closer = @"}}";
    } else if (opener == '{') {
        shape = SPDFMarkdownDiagramNodeShapeDiamond;
        scanner->position += 1;
        closer = @"}";
    } else if (opener == '>') {
        // Asymmetric flag shape: rendered as a rect in v1.
        shape = SPDFMarkdownDiagramNodeShapeRect;
        scanner->position += 1;
        closer = @"]";
    }
    if (closer) {
        label = SPDFScanLabelUntil(scanner, closer);
        if (label == nil) return nil;
        label = SPDFMarkdownDiagramCleanLabel(label);
    }
    // `:::name` binds a `classDef` to this node. mermaid allows a chain
    // (`A:::a:::b`); the LAST one wins, which is also what mermaid renders.
    NSString* className = nil;
    while (SPDFScanPeek(scanner, 0) == ':' && SPDFScanPeek(scanner, 1) == ':' &&
           SPDFScanPeek(scanner, 2) == ':') {
        scanner->position += 3;
        NSString* name = SPDFScanIdentifier(scanner);
        if (!name.length) return nil;  // a bare `:::` is malformed, not styling
        className = name;
    }
    SPDFMarkdownDiagramNode* node = [graph nodeForIdentifier:identifier createWithLabel:label];
    if (closer) node.shape = shape;
    if (className.length) node.className = className;
    return node;
}

// Parses one edge operator (`-->`, `---`, `-.->`, `==>`, `--text-->`,
// `-->|text|`, ...). Returns NO when the scanner does not sit on an edge.
static BOOL SPDFScanEdge(SPDFDiagramScanner* scanner, SPDFMarkdownDiagramLineStyle* outStyle, BOOL* outArrow,
                         BOOL* outTailArrow, NSString** outLabel) {
    SPDFScanSkipSpaces(scanner);
    // A leading `<` is the tail arrowhead of `<-->` / `<--` / `<-.->` / `<==>`;
    // everything after it is the ordinary connector run.
    BOOL tailArrow = NO;
    if (SPDFScanPeek(scanner, 0) == '<' &&
        (SPDFScanPeek(scanner, 1) == '-' || SPDFScanPeek(scanner, 1) == '=')) {
        tailArrow = YES;
        ++scanner->position;
    }
    unichar first = SPDFScanPeek(scanner, 0);
    unichar second = SPDFScanPeek(scanner, 1);
    BOOL startsEdge = (first == '-' && (second == '-' || second == '.')) || (first == '=' && second == '=');
    if (!startsEdge) return NO;
    *outTailArrow = tailArrow;
    NSUInteger connectorStart = scanner->position;
    while (scanner->position < scanner->text.length) {
        unichar character = SPDFScanPeek(scanner, 0);
        if (character != '-' && character != '=' && character != '.') break;
        ++scanner->position;
    }
    NSString* connector = [scanner->text
        substringWithRange:NSMakeRange(connectorStart, scanner->position - connectorStart)];
    BOOL arrow = NO;
    if (SPDFScanPeek(scanner, 0) == '>') {
        arrow = YES;
        ++scanner->position;
    }
    NSString* label = nil;
    if (!arrow && ![connector containsString:@"."]) {
        // Inline label: `--label-->` / `==label==>` — the connector run ended at
        // the label text; scan up to the closing run.
        SPDFScanSkipSpaces(scanner);
        unichar next = SPDFScanPeek(scanner, 0);
        if (next != 0 && next != '|' && !SPDFIsIdentifierCharacter(next) && next != '(') return NO;
        if (next != '|' && connector.length >= 2) {
            NSUInteger labelStart = scanner->position;
            unichar connectorCharacter = [connector characterAtIndex:0];
            NSUInteger closeStart = NSNotFound;
            while (scanner->position < scanner->text.length) {
                if (SPDFScanPeek(scanner, 0) == connectorCharacter && SPDFScanPeek(scanner, 1) == connectorCharacter) {
                    closeStart = scanner->position;
                    break;
                }
                ++scanner->position;
            }
            if (closeStart != NSNotFound) {
                label = [scanner->text substringWithRange:NSMakeRange(labelStart, closeStart - labelStart)];
                scanner->position = closeStart;
                while (scanner->position < scanner->text.length &&
                       [scanner->text characterAtIndex:scanner->position] == connectorCharacter)
                    ++scanner->position;
                if (SPDFScanPeek(scanner, 0) == '>') {
                    arrow = YES;
                    ++scanner->position;
                }
            } else {
                scanner->position = labelStart;  // plain `---` line into the next node
            }
        }
    } else if ([connector containsString:@"."] && !arrow) {
        // `-.label.->` inline dotted label.
        NSUInteger labelStart = scanner->position;
        SPDFScanSkipSpaces(scanner);
        NSUInteger closeStart = NSNotFound;
        while (scanner->position < scanner->text.length) {
            if (SPDFScanPeek(scanner, 0) == '.' && SPDFScanPeek(scanner, 1) == '-') {
                closeStart = scanner->position;
                break;
            }
            ++scanner->position;
        }
        if (closeStart != NSNotFound) {
            label = [scanner->text substringWithRange:NSMakeRange(labelStart, closeStart - labelStart)];
            scanner->position = closeStart + 2;
            if (SPDFScanPeek(scanner, 0) == '>') {
                arrow = YES;
                ++scanner->position;
            }
        } else {
            scanner->position = labelStart;
        }
    }
    SPDFScanSkipSpaces(scanner);
    if (SPDFScanPeek(scanner, 0) == '|') {
        ++scanner->position;
        NSString* piped = SPDFScanLabelUntil(scanner, @"|");
        if (piped == nil) return NO;
        label = piped;
    }
    *outStyle = [connector containsString:@"."] ? SPDFMarkdownDiagramLineStyleDashed
        : [connector hasPrefix:@"="]            ? SPDFMarkdownDiagramLineStyleThick
                                                : SPDFMarkdownDiagramLineStyleSolid;
    *outArrow = arrow;
    *outLabel = label.length ? SPDFMarkdownDiagramCleanLabel(label) : nil;
    return YES;
}

// One statement: node group (`A` / `A & B`), then any number of
// edge-then-node-group repetitions.
static BOOL SPDFParseFlowStatement(NSString* statement, SPDFMarkdownDiagramGraph* graph) {
    SPDFDiagramScanner scanner = {statement, 0};
    NSMutableArray<SPDFMarkdownDiagramNode*>* leftGroup = [NSMutableArray array];
    SPDFMarkdownDiagramNode* first = SPDFScanNode(&scanner, graph);
    if (!first) return NO;
    [leftGroup addObject:first];
    SPDFScanSkipSpaces(&scanner);
    while (SPDFScanPeek(&scanner, 0) == '&') {
        ++scanner.position;
        SPDFMarkdownDiagramNode* sibling = SPDFScanNode(&scanner, graph);
        if (!sibling) return NO;
        [leftGroup addObject:sibling];
        SPDFScanSkipSpaces(&scanner);
    }
    while (scanner.position < scanner.text.length) {
        SPDFMarkdownDiagramLineStyle style = SPDFMarkdownDiagramLineStyleSolid;
        BOOL arrow = NO;
        BOOL tailArrow = NO;
        NSString* label = nil;
        if (!SPDFScanEdge(&scanner, &style, &arrow, &tailArrow, &label)) return NO;
        NSMutableArray<SPDFMarkdownDiagramNode*>* rightGroup = [NSMutableArray array];
        SPDFMarkdownDiagramNode* target = SPDFScanNode(&scanner, graph);
        if (!target) return NO;
        [rightGroup addObject:target];
        SPDFScanSkipSpaces(&scanner);
        while (SPDFScanPeek(&scanner, 0) == '&') {
            ++scanner.position;
            SPDFMarkdownDiagramNode* sibling = SPDFScanNode(&scanner, graph);
            if (!sibling) return NO;
            [rightGroup addObject:sibling];
            SPDFScanSkipSpaces(&scanner);
        }
        for (SPDFMarkdownDiagramNode* from in leftGroup) {
            for (SPDFMarkdownDiagramNode* to in rightGroup) {
                SPDFMarkdownDiagramEdge* edge = [SPDFMarkdownDiagramEdge new];
                edge.fromIdentifier = from.identifier;
                edge.toIdentifier = to.identifier;
                edge.label = label;
                edge.lineStyle = style;
                edge.head = arrow ? SPDFMarkdownDiagramArrowHeadArrow : SPDFMarkdownDiagramArrowHeadNone;
                edge.tail = tailArrow ? SPDFMarkdownDiagramArrowHeadArrow : SPDFMarkdownDiagramArrowHeadNone;
                [graph.edges addObject:edge];
            }
        }
        leftGroup = rightGroup;
        SPDFScanSkipSpaces(&scanner);
    }
    return YES;
}

// `;` ends a statement, but ONLY at top level: an HTML entity inside a label
// (`SW["FW lockout &lt; 3.4 V"]`) carries one too, and splitting on it cut the
// label in half and failed the whole diagram.
static NSArray<NSString*>* SPDFFlowSplitStatements(NSString* line) {
    if ([line rangeOfString:@";"].location == NSNotFound) return @[ line ];
    NSMutableArray<NSString*>* statements = [NSMutableArray array];
    NSUInteger start = 0;
    NSInteger depth = 0;
    BOOL quoted = NO;
    for (NSUInteger index = 0; index < line.length; ++index) {
        unichar character = [line characterAtIndex:index];
        if (character == '"') {
            quoted = !quoted;
        } else if (quoted) {
            continue;
        } else if (character == '[' || character == '(' || character == '{') {
            ++depth;
        } else if (character == ']' || character == ')' || character == '}') {
            if (depth > 0) --depth;
        } else if (character == ';' && depth == 0) {
            [statements addObject:[line substringWithRange:NSMakeRange(start, index - start)]];
            start = index + 1;
        }
    }
    [statements addObject:[line substringFromIndex:start]];
    return statements;
}

static BOOL SPDFApplyFlowDirection(SPDFMarkdownDiagramGraph* graph, NSString* direction) {
    NSString* token = direction.uppercaseString;
    if ([token isEqualToString:@"TD"] || [token isEqualToString:@"TB"] || !token.length) {
        graph.vertical = YES;
        graph.reversed = NO;
    } else if ([token isEqualToString:@"BT"]) {
        graph.vertical = YES;
        graph.reversed = YES;
    } else if ([token isEqualToString:@"LR"]) {
        graph.vertical = NO;
        graph.reversed = NO;
    } else if ([token isEqualToString:@"RL"]) {
        graph.vertical = NO;
        graph.reversed = YES;
    } else {
        return NO;
    }
    return YES;
}

SPDFMarkdownDiagramGraph* SPDFMarkdownDiagramParseMermaidFlowchart(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count) return nil;
    NSArray* header = [lines.firstObject
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString* keyword = [header.firstObject lowercaseString];
    if (![keyword isEqualToString:@"graph"] && ![keyword isEqualToString:@"flowchart"]) return nil;
    SPDFMarkdownDiagramGraph* graph = [SPDFMarkdownDiagramGraph new];
    if (!SPDFApplyFlowDirection(graph, header.count > 1 ? header[1] : @"")) return nil;
    for (NSUInteger index = 1; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSString* lowered = line.lowercaseString;
        // v1 ignores subgraph GROUPING (members still render) and skips pure
        // styling/interaction statements; documented in markdown/README.md.
        if ([lowered hasPrefix:@"subgraph"] || [lowered isEqualToString:@"end"] ||
            [lowered hasPrefix:@"style "] || [lowered hasPrefix:@"linkstyle "] ||
            [lowered hasPrefix:@"click "] || [lowered hasPrefix:@"direction "])
            continue;
        // A `classDef` / `class` statement carries node STYLING. Either parser
        // returning NO means "nothing usable here", and the line is skipped
        // exactly as it was before styling existed -- an unreadable style
        // declaration costs a node its colors, never the whole diagram.
        if ([lowered hasPrefix:@"classdef "]) {
            SPDFMarkdownDiagramParseClassDef(line, graph);
            continue;
        }
        if ([lowered hasPrefix:@"class "]) {
            SPDFMarkdownDiagramParseClassAssignment(
                [line hasSuffix:@";"] ? [line substringToIndex:line.length - 1] : line, graph);
            continue;
        }
        for (NSString* statement in SPDFFlowSplitStatements(line)) {
            NSString* trimmed = SPDFMarkdownDiagramTrim(statement);
            if (!trimmed.length) continue;
            if (!SPDFParseFlowStatement(trimmed, graph)) return nil;
            if (graph.nodes.count > SPDFMarkdownDiagramMaximumNodes ||
                graph.edges.count > SPDFMarkdownDiagramMaximumEdges)
                return nil;
        }
    }
    [graph applyDeferredClassNames];
    return graph.nodes.count ? graph : nil;
}

// --- flowchart.js (`flow` fences) ----------------------------------------

static SPDFMarkdownDiagramNodeShape SPDFFlowShapeForType(NSString* type) {
    NSString* token = type.lowercaseString;
    if ([token isEqualToString:@"start"] || [token isEqualToString:@"end"])
        return SPDFMarkdownDiagramNodeShapeStadium;
    if ([token isEqualToString:@"condition"]) return SPDFMarkdownDiagramNodeShapeDiamond;
    if ([token isEqualToString:@"inputoutput"]) return SPDFMarkdownDiagramNodeShapeParallelogram;
    if ([token isEqualToString:@"subroutine"]) return SPDFMarkdownDiagramNodeShapeSubroutine;
    return SPDFMarkdownDiagramNodeShapeRect;  // operation and friends
}

static BOOL SPDFFlowIsKnownType(NSString* type) {
    static NSSet* known;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      known = [NSSet setWithArray:@[
          @"start", @"end", @"operation", @"condition", @"inputoutput", @"subroutine", @"parallel"
      ]];
    });
    return [known containsObject:type.lowercaseString];
}

SPDFMarkdownDiagramGraph* SPDFMarkdownDiagramParseFlowFence(NSString* source) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count) return nil;
    SPDFMarkdownDiagramGraph* graph = [SPDFMarkdownDiagramGraph new];
    graph.vertical = YES;
    BOOL sawDefinition = NO;
    for (NSString* line in lines) {
        NSRange definition = [line rangeOfString:@"=>"];
        if (definition.location != NSNotFound) {
            // `id=>type: text` (an optional `:>url` link suffix is dropped).
            NSString* identifier = SPDFMarkdownDiagramTrim([line substringToIndex:definition.location]);
            NSString* rest = [line substringFromIndex:NSMaxRange(definition)];
            NSRange colon = [rest rangeOfString:@":"];
            NSString* type = SPDFMarkdownDiagramTrim(colon.location == NSNotFound ? rest
                                                                                  : [rest substringToIndex:colon.location]);
            NSString* text = colon.location == NSNotFound ? @"" : [rest substringFromIndex:NSMaxRange(colon)];
            NSRange link = [text rangeOfString:@":>"];
            if (link.location != NSNotFound) text = [text substringToIndex:link.location];
            if (!identifier.length || !SPDFFlowIsKnownType(type)) return nil;
            SPDFMarkdownDiagramNode* node =
                [graph nodeForIdentifier:identifier createWithLabel:SPDFMarkdownDiagramCleanLabel(text)];
            node.shape = SPDFFlowShapeForType(type);
            sawDefinition = YES;
            continue;
        }
        // Link line: `a->b->c`, with optional branch/direction qualifiers
        // `cond(yes)->x` / `cond(yes, right)->x` (the direction hint is dropped).
        NSArray* hops = [line componentsSeparatedByString:@"->"];
        if (hops.count < 2) return nil;
        NSString* previousIdentifier = nil;
        NSString* previousBranch = nil;
        for (NSString* rawHop in hops) {
            NSString* hop = SPDFMarkdownDiagramTrim(rawHop);
            NSString* branch = nil;
            NSRange open = [hop rangeOfString:@"("];
            if (open.location != NSNotFound && [hop hasSuffix:@")"]) {
                branch = [hop substringWithRange:NSMakeRange(NSMaxRange(open),
                                                             hop.length - NSMaxRange(open) - 1)];
                branch = SPDFMarkdownDiagramTrim([branch componentsSeparatedByString:@","].firstObject);
                hop = SPDFMarkdownDiagramTrim([hop substringToIndex:open.location]);
            }
            if (!hop.length || ![graph existingNodeForIdentifier:hop]) return nil;
            if (previousIdentifier) {
                SPDFMarkdownDiagramEdge* edge = [SPDFMarkdownDiagramEdge new];
                edge.fromIdentifier = previousIdentifier;
                edge.toIdentifier = hop;
                edge.label = previousBranch.length ? previousBranch : nil;
                edge.head = SPDFMarkdownDiagramArrowHeadArrow;
                [graph.edges addObject:edge];
            }
            previousIdentifier = hop;
            previousBranch = branch;
        }
        if (graph.nodes.count > SPDFMarkdownDiagramMaximumNodes ||
            graph.edges.count > SPDFMarkdownDiagramMaximumEdges)
            return nil;
    }
    return sawDefinition && graph.nodes.count ? graph : nil;
}
