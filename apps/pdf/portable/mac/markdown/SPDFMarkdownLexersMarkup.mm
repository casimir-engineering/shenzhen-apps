#import "SPDFMarkdownLexers.h"

// Dedicated scanners for the markup-shaped languages: HTML/XML tags and
// entities, CSS selectors/properties/values, and LaTeX commands and math.
// Each scanner is a single forward pass, so token ranges never overlap.

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanAngleMarkup(
    NSString* code, SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '<' && SPDFLexMatches(code, index, @"<!--")) {
            NSUInteger end = SPDFLexScanUntil(code, index + 4, @"-->", cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '<') {
            NSUInteger cursor = index + 1;
            if (cursor < code.length) {
                unichar sigil = [code characterAtIndex:cursor];
                if (sigil == '/' || sigil == '!' || sigil == '?') ++cursor;
            }
            if (cursor >= code.length || !SPDFIsIdentifierStart([code characterAtIndex:cursor])) {
                ++index;  // a bare "<" is plain text (e.g. inside script math)
                continue;
            }
            NSUInteger nameEnd = cursor + 1;
            while (nameEnd < code.length &&
                   (SPDFIsIdentifierContinue([code characterAtIndex:nameEnd]) ||
                    [code characterAtIndex:nameEnd] == '-' || [code characterAtIndex:nameEnd] == ':')) {
                ++nameEnd;
            }
            SPDFAddToken(tokens, index, nameEnd, SPDFMarkdownSyntaxTokenMarkup);
            index = nameEnd;
            // Attributes until the closing angle bracket: names are keys,
            // quoted values are strings, the bracket itself is markup.
            while (index < code.length) {
                if (SPDFCancelled(cancellationToken, index + 1)) return @[];
                unichar inner = [code characterAtIndex:index];
                if (inner == '>') {
                    SPDFAddToken(tokens, index, index + 1, SPDFMarkdownSyntaxTokenMarkup);
                    ++index;
                    break;
                }
                if (inner == '"' || inner == '\'') {
                    NSUInteger end = SPDFScanQuoted(code, index, inner, NO, cancellationToken);
                    if (end == NSNotFound) return @[];
                    SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
                    index = end;
                } else if (SPDFIsIdentifierStart(inner)) {
                    NSUInteger end = index + 1;
                    while (end < code.length &&
                           (SPDFIsIdentifierContinue([code characterAtIndex:end]) ||
                            [code characterAtIndex:end] == '-' || [code characterAtIndex:end] == ':')) {
                        ++end;
                    }
                    SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKey);
                    index = end;
                } else {
                    ++index;
                }
            }
        } else if (character == '&') {
            NSUInteger cursor = index + 1;
            if (cursor < code.length && [code characterAtIndex:cursor] == '#') ++cursor;
            NSUInteger nameStart = cursor;
            while (cursor < code.length && cursor - index < 12 &&
                   SPDFIsIdentifierContinue([code characterAtIndex:cursor])) {
                ++cursor;
            }
            if (cursor > nameStart && cursor < code.length && [code characterAtIndex:cursor] == ';') {
                SPDFAddToken(tokens, index, cursor + 1, SPDFMarkdownSyntaxTokenMarkup);
                index = cursor + 1;
            } else {
                ++index;
            }
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static NSUInteger SPDFScanCSSWord(NSString* code, NSUInteger start) {
    NSUInteger index = start + 1;
    while (index < code.length && (SPDFIsIdentifierContinue([code characterAtIndex:index]) ||
                                   [code characterAtIndex:index] == '-')) {
        ++index;
    }
    return index;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanCSS(NSString* code,
                                                      SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    NSUInteger depth = 0;  // brace depth: selectors outside, declarations inside
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (SPDFLexMatches(code, index, @"/*")) {
            NSUInteger end = SPDFLexScanUntil(code, index + 2, @"*/", cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '"' || character == '\'') {
            NSUInteger end = SPDFScanQuoted(code, index, character, NO, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if ((character == '@' || character == '!') && index + 1 < code.length &&
                   SPDFIsIdentifierStart([code characterAtIndex:index + 1])) {
            // At-rules (@media) and priority flags (!important).
            NSUInteger end = SPDFScanCSSWord(code, index);
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            index = end;
        } else if (character == '#' && index + 1 < code.length &&
                   SPDFIsIdentifierContinue([code characterAtIndex:index + 1])) {
            // Inside a declaration block this is a hex color, outside an id selector.
            NSUInteger end = SPDFScanCSSWord(code, index);
            SPDFAddToken(tokens, index, end,
                         depth > 0 ? SPDFMarkdownSyntaxTokenNumber : SPDFMarkdownSyntaxTokenMarkup);
            index = end;
        } else if (character == '.' && depth == 0 && index + 1 < code.length &&
                   SPDFIsIdentifierStart([code characterAtIndex:index + 1])) {
            NSUInteger end = SPDFScanCSSWord(code, index);
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenMarkup);
            index = end;
        } else if (SPDFIsDigit(character)) {
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenNumber);
            index = end;
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanCSSWord(code, index);
            if (depth == 0) {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenMarkup);  // selector
            } else {
                NSUInteger lookahead = end;
                while (lookahead < code.length && SPDFIsWhitespace([code characterAtIndex:lookahead]))
                    ++lookahead;
                if (lookahead < code.length && [code characterAtIndex:lookahead] == ':') {
                    SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKey);  // property name
                }
            }
            index = end;
        } else {
            if (character == '{') ++depth;
            if (character == '}' && depth > 0) --depth;
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanLaTeX(NSString* code,
                                                        SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '%') {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '\\') {
            NSUInteger end = index + 1;
            while (end < code.length &&
                   [NSCharacterSet.letterCharacterSet characterIsMember:[code characterAtIndex:end]]) {
                ++end;
            }
            if (end < code.length && [code characterAtIndex:end] == '*') ++end;
            if (end == index + 1 && end < code.length) ++end;  // escaped symbol such as \% or "\\"
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            index = end;
        } else if (character == '$') {
            BOOL display = index + 1 < code.length && [code characterAtIndex:index + 1] == '$';
            NSUInteger cursor = index + (display ? 2 : 1);
            while (cursor < code.length) {
                if (SPDFScanCancelled(cancellationToken, index, cursor)) return @[];
                unichar inner = [code characterAtIndex:cursor];
                if (inner == '\\') {
                    cursor = MIN(code.length, cursor + 2);
                    continue;
                }
                if (inner == '$') {
                    cursor += display && cursor + 1 < code.length &&
                              [code characterAtIndex:cursor + 1] == '$' ? 2 : 1;
                    break;
                }
                ++cursor;
            }
            SPDFAddToken(tokens, index, cursor, SPDFMarkdownSyntaxTokenString);
            index = cursor;
        } else if (character == '{' || character == '}' || character == '&') {
            SPDFAddToken(tokens, index, index + 1, SPDFMarkdownSyntaxTokenMarkup);
            ++index;
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanMarkupFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* cancellationToken) {
    if ([identifier isEqualToString:@"html"] || [identifier isEqualToString:@"xml"])
        return SPDFScanAngleMarkup(code, cancellationToken);
    if ([identifier isEqualToString:@"css"]) return SPDFScanCSS(code, cancellationToken);
    if ([identifier isEqualToString:@"latex"]) return SPDFScanLaTeX(code, cancellationToken);
    return nil;
}
