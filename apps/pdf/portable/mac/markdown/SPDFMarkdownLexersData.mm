#import "SPDFMarkdownLexers.h"

// Dedicated scanners for line-oriented configuration data: YAML mappings and
// TOML tables. Both walk the code in one forward pass, so token ranges are
// emitted in order and never overlap.

static BOOL SPDFDataFollowsWhitespace(NSString* code, NSUInteger index) {
    return index == 0 || SPDFIsWhitespace([code characterAtIndex:index - 1]);
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanYAML(NSString* code,
                                                       SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    static NSSet<NSString*>* keywords;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keywords = [NSSet setWithArray:@[ @"true", @"false", @"null", @"yes", @"no", @"on", @"off" ]];
    });
    BOOL allowKey = YES;  // until this line produced a key or a scalar
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '\n') {
            allowKey = YES;
            ++index;
        } else if (SPDFIsWhitespace(character)) {
            ++index;
        } else if (character == '#' && SPDFDataFollowsWhitespace(code, index)) {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (allowKey && (SPDFLexMatches(code, index, @"--- ") || SPDFLexMatches(code, index, @"---\n") ||
                                (SPDFLexMatches(code, index, @"---") && index + 3 == code.length))) {
            SPDFAddToken(tokens, index, index + 3, SPDFMarkdownSyntaxTokenMarkup);
            index += 3;
            allowKey = NO;
        } else if (allowKey && character == '-' && index + 1 < code.length &&
                   [code characterAtIndex:index + 1] == ' ') {
            SPDFAddToken(tokens, index, index + 1, SPDFMarkdownSyntaxTokenMarkup);
            ++index;  // list marker; the item may still be a key
        } else if (character == '"' || character == '\'') {
            NSUInteger end = SPDFScanQuoted(code, index, character, NO, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
            allowKey = NO;
        } else if (allowKey) {
            // Try "key:" — scan to the first colon on this line, which must be
            // followed by whitespace or the end of input.
            NSUInteger cursor = index;
            while (cursor < code.length) {
                if (SPDFScanCancelled(cancellationToken, index, cursor)) return @[];
                unichar scan = [code characterAtIndex:cursor];
                if (scan == ':' || scan == '\n' || scan == '#') break;
                ++cursor;
            }
            BOOL isKey = cursor < code.length && [code characterAtIndex:cursor] == ':' &&
                         (cursor + 1 == code.length || SPDFIsWhitespace([code characterAtIndex:cursor + 1]));
            if (isKey) {
                NSUInteger keyEnd = cursor;
                while (keyEnd > index && SPDFIsWhitespace([code characterAtIndex:keyEnd - 1])) --keyEnd;
                SPDFAddToken(tokens, index, keyEnd, SPDFMarkdownSyntaxTokenKey);
                index = cursor + 1;
            }
            allowKey = NO;  // when not a key, reprocess this position as a value
        } else if (SPDFIsDigit(character) ||
                   (character == '-' && index + 1 < code.length &&
                    SPDFIsDigit([code characterAtIndex:index + 1]))) {
            NSUInteger start = index;
            if (character == '-') ++index;
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, start, end, SPDFMarkdownSyntaxTokenNumber);
            index = MAX(end, start + 1);
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)].lowercaseString;
            if ([keywords containsObject:word]) {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            }
            index = end;
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanTOML(NSString* code,
                                                       SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    BOOL lineStart = YES;  // only whitespace so far on this line
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '\n') {
            lineStart = YES;
            ++index;
        } else if (SPDFIsWhitespace(character)) {
            ++index;
        } else if (character == '#') {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
            lineStart = NO;
        } else if (lineStart && character == '[') {
            NSUInteger end = index + 1;
            while (end < code.length && [code characterAtIndex:end] != '\n' &&
                   [code characterAtIndex:end] != ']') {
                if (SPDFScanCancelled(cancellationToken, index, end)) return @[];
                ++end;
            }
            while (end < code.length && [code characterAtIndex:end] == ']') ++end;
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenMarkup);  // [table] header
            index = end;
            lineStart = NO;
        } else if (character == '"' || character == '\'') {
            NSUInteger end = SPDFScanQuoted(code, index, character, YES, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
            lineStart = NO;
        } else if (lineStart && SPDFIsIdentifierStart(character)) {
            NSUInteger end = index + 1;
            while (end < code.length && (SPDFIsIdentifierContinue([code characterAtIndex:end]) ||
                                         [code characterAtIndex:end] == '-' ||
                                         [code characterAtIndex:end] == '.')) {
                ++end;
            }
            NSUInteger lookahead = end;
            while (lookahead < code.length && SPDFIsWhitespace([code characterAtIndex:lookahead]))
                ++lookahead;
            if (lookahead < code.length && [code characterAtIndex:lookahead] == '=') {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKey);
            }
            index = end;
            lineStart = NO;
        } else if (SPDFIsDigit(character) ||
                   (character == '-' && index + 1 < code.length &&
                    SPDFIsDigit([code characterAtIndex:index + 1]))) {
            NSUInteger start = index;
            if (character == '-') ++index;
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, start, end, SPDFMarkdownSyntaxTokenNumber);
            index = MAX(end, start + 1);
            lineStart = NO;
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)];
            if ([word isEqualToString:@"true"] || [word isEqualToString:@"false"]) {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            }
            index = end;
            lineStart = NO;
        } else {
            ++index;
            lineStart = NO;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanDataFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* cancellationToken) {
    if ([identifier isEqualToString:@"yaml"]) return SPDFScanYAML(code, cancellationToken);
    if ([identifier isEqualToString:@"toml"]) return SPDFScanTOML(code, cancellationToken);
    return nil;
}
