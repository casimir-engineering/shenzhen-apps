#import "SPDFMarkdownHighlighter.h"

#import "SPDFMarkdownLexers.h"

@implementation SPDFMarkdownSyntaxToken
- (instancetype)initWithRange:(NSRange)range kind:(SPDFMarkdownSyntaxTokenKind)kind {
    self = [super init];
    if (self) {
        _range = range;
        _kind = kind;
    }
    return self;
}
@end

// The scanning primitives below are shared with the grammar-driven lexer
// families (SPDFMarkdownLexers*.mm) through SPDFMarkdownLexers.h.
BOOL SPDFCancelled(SPDFMarkdownCancellationToken* token, NSUInteger offset) {
    return (offset & 255) == 0 && token.isCancelled;
}

BOOL SPDFScanCancelled(SPDFMarkdownCancellationToken* token, NSUInteger start, NSUInteger offset) {
    NSUInteger distance = offset - start;
    return distance >= 256 && (distance & 255) < 2 && token.isCancelled;
}

BOOL SPDFIsIdentifierStart(unichar character) {
    return character == '_' || character == '$' ||
           [NSCharacterSet.letterCharacterSet characterIsMember:character];
}

BOOL SPDFIsIdentifierContinue(unichar character) {
    return SPDFIsIdentifierStart(character) ||
           [NSCharacterSet.decimalDigitCharacterSet characterIsMember:character];
}

BOOL SPDFIsDigit(unichar character) {
    return character >= '0' && character <= '9';
}

BOOL SPDFIsWhitespace(unichar character) {
    return [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:character];
}

void SPDFAddToken(NSMutableArray<SPDFMarkdownSyntaxToken*>* tokens, NSUInteger start, NSUInteger end,
                  SPDFMarkdownSyntaxTokenKind kind) {
    if (end > start) {
        [tokens addObject:[[SPDFMarkdownSyntaxToken alloc] initWithRange:NSMakeRange(start, end - start)
                                                                    kind:kind]];
    }
}

NSUInteger SPDFScanLineComment(NSString* code, NSUInteger start,
                               SPDFMarkdownCancellationToken* cancellationToken) {
    NSUInteger index = start;
    while (index < code.length && [code characterAtIndex:index] != '\n') {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        ++index;
    }
    return index;
}

static NSUInteger SPDFScanBlockComment(NSString* code, NSUInteger start,
                                       SPDFMarkdownCancellationToken* cancellationToken) {
    NSUInteger index = start + 2;
    while (index + 1 < code.length) {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        if ([code characterAtIndex:index] == '*' && [code characterAtIndex:index + 1] == '/') return index + 2;
        ++index;
    }
    return code.length;
}

NSUInteger SPDFScanQuoted(NSString* code, NSUInteger start, unichar quote, BOOL allowTriple,
                          SPDFMarkdownCancellationToken* cancellationToken) {
    BOOL triple = allowTriple && start + 2 < code.length && [code characterAtIndex:start + 1] == quote &&
                  [code characterAtIndex:start + 2] == quote;
    NSUInteger index = start + (triple ? 3 : 1);
    while (index < code.length) {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        unichar character = [code characterAtIndex:index];
        if (character == '\\') {
            index = MIN(code.length, index + 2);
            continue;
        }
        if (triple) {
            if (index + 2 < code.length && character == quote && [code characterAtIndex:index + 1] == quote &&
                [code characterAtIndex:index + 2] == quote) return index + 3;
        } else if (character == quote) {
            return index + 1;
        }
        ++index;
    }
    return code.length;
}

NSUInteger SPDFScanNumber(NSString* code, NSUInteger start,
                          SPDFMarkdownCancellationToken* cancellationToken) {
    NSUInteger index = start;
    if (start + 1 < code.length && [code characterAtIndex:start] == '0') {
        unichar prefix = [code characterAtIndex:start + 1];
        if (prefix == 'x' || prefix == 'X') {
            index += 2;
            while (index < code.length) {
                if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
                unichar character = [code characterAtIndex:index];
                if (!(SPDFIsDigit(character) || (character >= 'a' && character <= 'f') ||
                      (character >= 'A' && character <= 'F') || character == '_')) break;
                ++index;
            }
            return index;
        }
        if (prefix == 'b' || prefix == 'B') {
            index += 2;
            while (index < code.length && ([code characterAtIndex:index] == '0' ||
                                            [code characterAtIndex:index] == '1' ||
                                            [code characterAtIndex:index] == '_')) {
                if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
                ++index;
            }
            return index;
        }
    }
    while (index < code.length &&
           (SPDFIsDigit([code characterAtIndex:index]) || [code characterAtIndex:index] == '_')) {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        ++index;
    }
    if (index + 1 < code.length && [code characterAtIndex:index] == '.' &&
        SPDFIsDigit([code characterAtIndex:index + 1])) {
        ++index;
        while (index < code.length &&
               (SPDFIsDigit([code characterAtIndex:index]) || [code characterAtIndex:index] == '_')) {
            if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
            ++index;
        }
    }
    if (index < code.length && ([code characterAtIndex:index] == 'e' || [code characterAtIndex:index] == 'E')) {
        NSUInteger exponent = index++;
        if (index < code.length && ([code characterAtIndex:index] == '+' || [code characterAtIndex:index] == '-'))
            ++index;
        NSUInteger digits = index;
        while (index < code.length &&
               (SPDFIsDigit([code characterAtIndex:index]) || [code characterAtIndex:index] == '_')) {
            if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
            ++index;
        }
        if (digits == index) index = exponent;
    }
    if (index < code.length && [code characterAtIndex:index] == 'n') ++index;
    return index;
}

NSUInteger SPDFScanIdentifier(NSString* code, NSUInteger start,
                              SPDFMarkdownCancellationToken* cancellationToken) {
    NSUInteger index = start + 1;
    while (index < code.length && SPDFIsIdentifierContinue([code characterAtIndex:index])) {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        ++index;
    }
    return index;
}

static NSSet<NSString*>* SPDFKeywordSet(NSString* language) {
    static NSDictionary<NSString*, NSSet<NSString*>*>* sets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary* words = @{
            @"javascript": @"async await break case catch class const continue debugger default delete do else export extends false finally for function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield",
            @"python": @"and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield",
            @"swift": @"associatedtype break case catch class continue convenience default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let nil open operator override private protocol public repeat required rethrows return self static struct subscript super switch throw throws true try typealias var weak where while",
        };
        NSMutableDictionary* result = [NSMutableDictionary dictionary];
        for (NSString* key in words) {
            result[key] = [NSSet setWithArray:[words[key] componentsSeparatedByString:@" "]];
        }
        // TypeScript extends the JavaScript grammar with its type keywords.
        NSMutableSet* typescript = [result[@"javascript"] mutableCopy];
        [typescript addObjectsFromArray:[@"abstract any as asserts bigint boolean declare enum "
                                          "implements infer interface is keyof module namespace "
                                          "never number object override private protected public "
                                          "readonly satisfies string symbol type unique unknown"
                                            componentsSeparatedByString:@" "]];
        result[@"typescript"] = [typescript copy];
        sets = [result copy];
    });
    return sets[language] ?: [NSSet set];
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanCLike(NSString* code, NSString* language,
                                                        SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    NSSet* keywords = SPDFKeywordSet(language);
    BOOL swift = [language isEqualToString:@"swift"];
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '/' && index + 1 < code.length && [code characterAtIndex:index + 1] == '/') {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '/' && index + 1 < code.length && [code characterAtIndex:index + 1] == '*') {
            NSUInteger end = SPDFScanBlockComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '"' || (!swift && (character == '\'' || character == '`'))) {
            NSUInteger end = SPDFScanQuoted(code, index, character, swift, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if (SPDFIsDigit(character)) {
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenNumber);
            index = end;
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)];
            if ([keywords containsObject:word]) SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            index = end;
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static BOOL SPDFIsPythonPrefix(NSString* value) {
    if (value.length == 0 || value.length > 2) return NO;
    NSCharacterSet* allowed = [NSCharacterSet characterSetWithCharactersInString:@"rRuUbBfF"];
    return [[value stringByTrimmingCharactersInSet:allowed] length] == 0;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanPython(NSString* code,
                                                         SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    NSSet* keywords = SPDFKeywordSet(@"python");
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '#') {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '"' || character == '\'') {
            NSUInteger end = SPDFScanQuoted(code, index, character, YES, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if (SPDFIsDigit(character)) {
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenNumber);
            index = end;
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)];
            if (end < code.length && ([code characterAtIndex:end] == '"' || [code characterAtIndex:end] == '\'') &&
                SPDFIsPythonPrefix(word)) {
                NSUInteger stringEnd =
                    SPDFScanQuoted(code, end, [code characterAtIndex:end], YES, cancellationToken);
                if (stringEnd == NSNotFound) return @[];
                SPDFAddToken(tokens, index, stringEnd, SPDFMarkdownSyntaxTokenString);
                index = stringEnd;
            } else {
                if ([keywords containsObject:word]) SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
                index = end;
            }
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanJSON(NSString* code,
                                                       SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '/' && index + 1 < code.length && [code characterAtIndex:index + 1] == '/') {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '/' && index + 1 < code.length && [code characterAtIndex:index + 1] == '*') {
            NSUInteger end = SPDFScanBlockComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (character == '"') {
            NSUInteger end = SPDFScanQuoted(code, index, character, NO, cancellationToken);
            if (end == NSNotFound) return @[];
            NSUInteger lookahead = end;
            while (lookahead < code.length && SPDFIsWhitespace([code characterAtIndex:lookahead])) ++lookahead;
            SPDFAddToken(tokens, index, end, lookahead < code.length && [code characterAtIndex:lookahead] == ':'
                ? SPDFMarkdownSyntaxTokenKey : SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if (character == '-' || SPDFIsDigit(character)) {
            NSUInteger numberStart = index;
            if (character == '-' && index + 1 < code.length && SPDFIsDigit([code characterAtIndex:index + 1])) ++index;
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, numberStart, end, SPDFMarkdownSyntaxTokenNumber);
            index = MAX(end, numberStart + 1);
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)];
            if ([word isEqualToString:@"true"] || [word isEqualToString:@"false"] || [word isEqualToString:@"null"]) {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            }
            index = end;
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

static NSArray<SPDFMarkdownSyntaxToken*>* SPDFScanMarkdown(NSString* code,
                                                           SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    BOOL lineStart = YES;
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (character == '\n') {
            lineStart = YES;
            ++index;
            continue;
        }
        if (lineStart && character == '#') {
            NSUInteger end = index;
            while (end < code.length && [code characterAtIndex:end] == '#' && end - index < 6) ++end;
            if (end < code.length && ([code characterAtIndex:end] == ' ' || [code characterAtIndex:end] == '\t')) {
                SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenMarkup);
                index = end;
                lineStart = NO;
                continue;
            }
        }
        lineStart = NO;
        if (character == '`') {
            NSUInteger end = index + 1;
            while (end < code.length && [code characterAtIndex:end] != '`' && [code characterAtIndex:end] != '\n') {
                if (SPDFScanCancelled(cancellationToken, index, end)) return @[];
                ++end;
            }
            if (end < code.length && [code characterAtIndex:end] == '`') ++end;
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if ((character == '*' || character == '_' || character == '~') && index + 1 < code.length &&
                   [code characterAtIndex:index + 1] == character) {
            SPDFAddToken(tokens, index, index + 2, SPDFMarkdownSyntaxTokenMarkup);
            index += 2;
        } else if (character == '[' || (character == '!' && index + 1 < code.length &&
                                        [code characterAtIndex:index + 1] == '[')) {
            NSUInteger start = index;
            if (character == '!') ++index;
            SPDFAddToken(tokens, start, index + 1, SPDFMarkdownSyntaxTokenKey);
            ++index;
        } else {
            ++index;
        }
    }
    return cancellationToken.isCancelled ? @[] : tokens;
}

@implementation SPDFMarkdownHighlighter
- (NSArray<SPDFMarkdownSyntaxToken*>*)tokensForCode:(NSString*)code language:(SPDFMarkdownLanguage*)language {
    return [self tokensForCode:code language:language cancellationToken:nil];
}

- (NSArray<SPDFMarkdownSyntaxToken*>*)tokensForCode:(NSString*)code
                                           language:(SPDFMarkdownLanguage*)language
                                  cancellationToken:(SPDFMarkdownCancellationToken*)cancellationToken {
    NSString* identifier = language.identifier;
    // Plain Text is the explicit "no highlighting" choice in the picker.
    if ([identifier isEqualToString:@"plain"]) return @[];
    if ([identifier isEqualToString:@"python"]) return SPDFScanPython(code, cancellationToken);
    if ([identifier isEqualToString:@"json"]) return SPDFScanJSON(code, cancellationToken);
    if ([identifier isEqualToString:@"markdown"]) return SPDFScanMarkdown(code, cancellationToken);
    NSArray* tokens = SPDFMarkdownScanCFamily(identifier, code, cancellationToken);
    if (!tokens) tokens = SPDFMarkdownScanScripting(identifier, code, cancellationToken);
    if (!tokens) tokens = SPDFMarkdownScanMarkupFamily(identifier, code, cancellationToken);
    if (!tokens) tokens = SPDFMarkdownScanDataFamily(identifier, code, cancellationToken);
    // JavaScript, TypeScript and Swift keep the original C-like lexer.
    return tokens ?: SPDFScanCLike(code, identifier, cancellationToken);
}
@end
