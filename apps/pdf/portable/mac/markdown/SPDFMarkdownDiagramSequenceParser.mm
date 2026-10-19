#import "SPDFMarkdownDiagramInternal.h"

// Sequence-diagram parser shared by mermaid `sequenceDiagram` fences and
// js-sequence (`sequence` fences). The grammars are near-identical line
// languages; `mermaidSyntax` selects the small semantic differences:
// - mermaid `->` draws a plain line and `->>` an arrowhead; js-sequence `->`
//   already has an arrowhead (`->>` becomes an open arrow, same drawing here).
// - only mermaid supports alt/opt/loop/par frames and activate/deactivate.
// - only js-sequence supports a leading `Title: ...` line (mermaid's header
//   line is the `sequenceDiagram` keyword itself).

// Message arrow operators, longest first so `-->>` wins over `-->`.
static NSArray<NSString*>* SPDFSequenceOperators(void) {
    static NSArray* operators;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      operators = @[ @"-->>", @"->>", @"--)", @"-)", @"--x", @"-x", @"-->", @"->" ];
    });
    return operators;
}

static BOOL SPDFSequenceOperatorDashed(NSString* op) {
    return [op hasPrefix:@"--"];
}

static BOOL SPDFSequenceOperatorArrowhead(NSString* op, BOOL mermaidSyntax) {
    if ([op hasSuffix:@">>"] || [op hasSuffix:@")"] || [op hasSuffix:@"x"]) return YES;
    return !mermaidSyntax;  // js-sequence `->` / `-->` carry arrowheads
}

// Parses `A->>+B: text` into a message event; returns nil when the line is
// not a message. `activations` collects implicit +/- activation events.
static SPDFMarkdownDiagramSequenceEvent* SPDFSequenceParseMessage(
    NSString* line, SPDFMarkdownDiagramSequence* sequence, BOOL mermaidSyntax,
    NSMutableArray<SPDFMarkdownDiagramSequenceEvent*>* activations) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString* head = [line substringToIndex:colon.location];
    NSString* text = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:NSMaxRange(colon)]);
    for (NSString* op in SPDFSequenceOperators()) {
        NSRange operatorRange = [head rangeOfString:op];
        if (operatorRange.location == NSNotFound) continue;
        NSString* fromToken = [head substringToIndex:operatorRange.location];
        NSString* toToken = SPDFMarkdownDiagramTrim([head substringFromIndex:NSMaxRange(operatorRange)]);
        BOOL activateTarget = NO;
        BOOL deactivateSource = NO;
        if (mermaidSyntax && [toToken hasPrefix:@"+"]) {
            activateTarget = YES;
            toToken = SPDFMarkdownDiagramTrim([toToken substringFromIndex:1]);
        } else if (mermaidSyntax && [toToken hasPrefix:@"-"]) {
            deactivateSource = YES;
            toToken = SPDFMarkdownDiagramTrim([toToken substringFromIndex:1]);
        }
        NSString* from = [sequence actorForToken:fromToken];
        NSString* to = [sequence actorForToken:toToken];
        if (!from.length || !to.length) return nil;
        SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
        event.kind = SPDFMarkdownDiagramSequenceEventMessage;
        event.fromIdentifier = from;
        event.toIdentifier = to;
        event.text = text;
        event.dashed = SPDFSequenceOperatorDashed(op);
        event.arrowhead = SPDFSequenceOperatorArrowhead(op, mermaidSyntax);
        if (activateTarget) {
            SPDFMarkdownDiagramSequenceEvent* activate = [SPDFMarkdownDiagramSequenceEvent new];
            activate.kind = SPDFMarkdownDiagramSequenceEventActivate;
            activate.fromIdentifier = to;
            [activations addObject:activate];
        }
        if (deactivateSource) {
            // Mermaid's `B-->>-A` shortcut deactivates the SENDER (B).
            SPDFMarkdownDiagramSequenceEvent* deactivate = [SPDFMarkdownDiagramSequenceEvent new];
            deactivate.kind = SPDFMarkdownDiagramSequenceEventDeactivate;
            deactivate.fromIdentifier = from;
            [activations addObject:deactivate];
        }
        return event;
    }
    return nil;
}

// `Note left of A: t` / `Note right of A: t` / `Note over A,B: t`.
static SPDFMarkdownDiagramSequenceEvent* SPDFSequenceParseNote(NSString* line,
                                                               SPDFMarkdownDiagramSequence* sequence) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) return nil;
    NSString* head = SPDFMarkdownDiagramTrim([line substringToIndex:colon.location]);
    NSString* text = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:NSMaxRange(colon)]);
    SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
    event.kind = SPDFMarkdownDiagramSequenceEventNote;
    event.text = text;
    NSString* actors = nil;
    NSString* lowered = head.lowercaseString;
    if ([lowered hasPrefix:@"note left of "]) {
        event.notePosition = SPDFMarkdownDiagramNoteLeftOf;
        actors = [head substringFromIndex:@"note left of ".length];
    } else if ([lowered hasPrefix:@"note right of "]) {
        event.notePosition = SPDFMarkdownDiagramNoteRightOf;
        actors = [head substringFromIndex:@"note right of ".length];
    } else if ([lowered hasPrefix:@"note over "]) {
        event.notePosition = SPDFMarkdownDiagramNoteOver;
        actors = [head substringFromIndex:@"note over ".length];
    } else {
        return nil;
    }
    NSArray* tokens = [actors componentsSeparatedByString:@","];
    if (!tokens.count || tokens.count > 2) return nil;
    event.fromIdentifier = [sequence actorForToken:tokens.firstObject];
    event.toIdentifier = tokens.count > 1 ? [sequence actorForToken:tokens.lastObject] : event.fromIdentifier;
    if (!event.fromIdentifier.length || !event.toIdentifier.length) return nil;
    return event;
}

SPDFMarkdownDiagramSequence* SPDFMarkdownDiagramParseSequence(NSString* source, BOOL mermaidSyntax) {
    NSArray<NSString*>* lines = SPDFMarkdownDiagramSignificantLines(source);
    if (!lines.count) return nil;
    NSUInteger start = 0;
    if (mermaidSyntax) {
        if (![lines.firstObject.lowercaseString isEqualToString:@"sequencediagram"]) return nil;
        start = 1;
    }
    SPDFMarkdownDiagramSequence* sequence = [SPDFMarkdownDiagramSequence new];
    NSUInteger openFrames = 0;
    for (NSUInteger index = start; index < lines.count; ++index) {
        NSString* line = lines[index];
        NSString* lowered = line.lowercaseString;
        if (!mermaidSyntax && [lowered hasPrefix:@"title:"]) {
            sequence.title = SPDFMarkdownDiagramCleanLabel([line substringFromIndex:@"title:".length]);
            continue;
        }
        if (mermaidSyntax && ([lowered isEqualToString:@"autonumber"] || [lowered hasPrefix:@"autonumber "]))
            continue;  // numbering is skipped in v1 (documented)
        if ([lowered hasPrefix:@"participant "] || [lowered hasPrefix:@"actor "]) {
            NSUInteger prefixLength = [lowered hasPrefix:@"actor "] ? @"actor ".length : @"participant ".length;
            NSString* rest = SPDFMarkdownDiagramTrim([line substringFromIndex:prefixLength]);
            NSString* label = nil;
            NSRange asRange = [rest rangeOfString:@" as " options:NSCaseInsensitiveSearch];
            if (asRange.location != NSNotFound) {
                label = SPDFMarkdownDiagramCleanLabel([rest substringFromIndex:NSMaxRange(asRange)]);
                rest = SPDFMarkdownDiagramTrim([rest substringToIndex:asRange.location]);
            }
            if (!rest.length) return nil;
            NSString* identifier = [sequence actorForToken:rest];
            if (label.length) sequence.actorLabels[identifier] = label;
            continue;
        }
        if ([lowered hasPrefix:@"note "]) {
            SPDFMarkdownDiagramSequenceEvent* note = SPDFSequenceParseNote(line, sequence);
            if (!note) return nil;
            [sequence.events addObject:note];
            continue;
        }
        if (mermaidSyntax) {
            if ([lowered hasPrefix:@"activate "] || [lowered hasPrefix:@"deactivate "]) {
                BOOL activate = [lowered hasPrefix:@"activate "];
                NSString* token = [line substringFromIndex:(activate ? @"activate " : @"deactivate ").length];
                SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
                event.kind = activate ? SPDFMarkdownDiagramSequenceEventActivate
                                      : SPDFMarkdownDiagramSequenceEventDeactivate;
                event.fromIdentifier = [sequence actorForToken:token];
                if (!event.fromIdentifier.length) return nil;
                [sequence.events addObject:event];
                continue;
            }
            BOOL frameBegin = NO;
            for (NSString* keyword in @[ @"alt", @"opt", @"loop", @"par", @"critical", @"rect", @"break" ]) {
                if (![lowered isEqualToString:keyword] &&
                    ![lowered hasPrefix:[keyword stringByAppendingString:@" "]])
                    continue;
                SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
                event.kind = SPDFMarkdownDiagramSequenceEventFrameBegin;
                event.frameKeyword = [keyword isEqualToString:@"rect"] ? @"" : keyword;
                event.text = line.length > keyword.length
                    ? SPDFMarkdownDiagramCleanLabel([line substringFromIndex:keyword.length])
                    : @"";
                if ([keyword isEqualToString:@"rect"]) event.text = @"";
                [sequence.events addObject:event];
                ++openFrames;
                frameBegin = YES;
                break;
            }
            if (frameBegin) continue;
            if ([lowered isEqualToString:@"else"] || [lowered hasPrefix:@"else "] ||
                [lowered isEqualToString:@"and"] || [lowered hasPrefix:@"and "] ||
                [lowered isEqualToString:@"option"] || [lowered hasPrefix:@"option "]) {
                if (!openFrames) return nil;
                SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
                event.kind = SPDFMarkdownDiagramSequenceEventFrameElse;
                NSRange space = [line rangeOfString:@" "];
                event.text = space.location == NSNotFound
                    ? @""
                    : SPDFMarkdownDiagramCleanLabel([line substringFromIndex:NSMaxRange(space)]);
                [sequence.events addObject:event];
                continue;
            }
            if ([lowered isEqualToString:@"end"]) {
                if (!openFrames) return nil;
                --openFrames;
                SPDFMarkdownDiagramSequenceEvent* event = [SPDFMarkdownDiagramSequenceEvent new];
                event.kind = SPDFMarkdownDiagramSequenceEventFrameEnd;
                [sequence.events addObject:event];
                continue;
            }
        }
        NSMutableArray<SPDFMarkdownDiagramSequenceEvent*>* activations = [NSMutableArray array];
        SPDFMarkdownDiagramSequenceEvent* message =
            SPDFSequenceParseMessage(line, sequence, mermaidSyntax, activations);
        if (!message) return nil;
        [sequence.events addObject:message];
        [sequence.events addObjectsFromArray:activations];
        if (sequence.actorIdentifiers.count > SPDFMarkdownDiagramMaximumNodes ||
            sequence.events.count > SPDFMarkdownDiagramMaximumEdges)
            return nil;
    }
    return sequence.actorIdentifiers.count && sequence.events.count && !openFrames ? sequence : nil;
}
