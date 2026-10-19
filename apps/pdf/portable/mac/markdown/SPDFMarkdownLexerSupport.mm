#import "SPDFMarkdownLexers.h"

// Generic single-pass scanner shared by every grammar-driven language. Like
// the dedicated lexers, it walks the code once, consuming each accepted token
// completely before continuing, so token ranges are emitted in order and can
// never overlap.

BOOL SPDFLexMatches(NSString* code, NSUInteger index, NSString* needle) {
    NSUInteger length = needle.length;
    if (length == 0 || index + length > code.length) return NO;
    for (NSUInteger offset = 0; offset < length; ++offset) {
        if ([code characterAtIndex:index + offset] != [needle characterAtIndex:offset]) return NO;
    }
    return YES;
}

BOOL SPDFLexContainsCharacter(NSString* set, unichar character) {
    for (NSUInteger index = 0; index < set.length; ++index) {
        if ([set characterAtIndex:index] == character) return YES;
    }
    return NO;
}

NSUInteger SPDFLexScanUntil(NSString* code, NSUInteger start, NSString* close,
                            SPDFMarkdownCancellationToken* cancellationToken) {
    NSUInteger index = start;
    while (index < code.length) {
        if (SPDFScanCancelled(cancellationToken, start, index)) return NSNotFound;
        if (SPDFLexMatches(code, index, close)) return index + close.length;
        ++index;
    }
    return code.length;
}

@implementation SPDFMarkdownLexerGrammar

+ (instancetype)grammarWithKeywords:(NSString*)spaceSeparatedKeywords {
    SPDFMarkdownLexerGrammar* grammar = [self new];
    grammar.quoteCharacters = @"\"'";
    grammar.keywords =
        [NSSet setWithArray:[spaceSeparatedKeywords componentsSeparatedByString:@" "]];
    return grammar;
}

+ (instancetype)cFamilyGrammarWithKeywords:(NSString*)spaceSeparatedKeywords {
    SPDFMarkdownLexerGrammar* grammar = [self grammarWithKeywords:spaceSeparatedKeywords];
    grammar.lineComment = @"//";
    grammar.blockCommentOpen = @"/*";
    grammar.blockCommentClose = @"*/";
    return grammar;
}

@end

// Scans a `$name` or `${expansion}` style variable. Returns the end index.
static NSUInteger SPDFLexScanSigilVariable(NSString* code, NSUInteger index) {
    NSUInteger cursor = index + 1;
    if ([code characterAtIndex:cursor] == '{') {
        ++cursor;
        while (cursor < code.length && [code characterAtIndex:cursor] != '}' &&
               [code characterAtIndex:cursor] != '\n') {
            ++cursor;
        }
        if (cursor < code.length && [code characterAtIndex:cursor] == '}') ++cursor;
        return cursor;
    }
    while (cursor < code.length && SPDFIsIdentifierContinue([code characterAtIndex:cursor])) ++cursor;
    return cursor;
}

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanWithGrammar(
    SPDFMarkdownLexerGrammar* grammar, NSString* code,
    SPDFMarkdownCancellationToken* cancellationToken) {
    NSMutableArray* tokens = [NSMutableArray array];
    NSSet* keywords = grammar.keywords;
    for (NSUInteger index = 0; index < code.length;) {
        if (SPDFCancelled(cancellationToken, index)) return @[];
        unichar character = [code characterAtIndex:index];
        if (SPDFLexMatches(code, index, grammar.blockCommentOpen)) {
            NSUInteger end = SPDFLexScanUntil(code, index + grammar.blockCommentOpen.length,
                                              grammar.blockCommentClose, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (SPDFLexMatches(code, index, grammar.lineComment) ||
                   SPDFLexMatches(code, index, grammar.alternateLineComment)) {
            NSUInteger end = SPDFScanLineComment(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenComment);
            index = end;
        } else if (SPDFLexContainsCharacter(grammar.quoteCharacters, character)) {
            NSUInteger end = SPDFScanQuoted(code, index, character, grammar.tripleQuotes, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenString);
            index = end;
        } else if (SPDFIsDigit(character)) {
            NSUInteger end = SPDFScanNumber(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenNumber);
            index = end;
        } else if (SPDFLexContainsCharacter(grammar.variableSigils, character) &&
                   index + 1 < code.length &&
                   (SPDFIsIdentifierStart([code characterAtIndex:index + 1]) ||
                    [code characterAtIndex:index + 1] == '{')) {
            NSUInteger end = SPDFLexScanSigilVariable(code, index);
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKey);
            index = end;
        } else if (SPDFLexContainsCharacter(grammar.keywordSigils, character) &&
                   index + 1 < code.length &&
                   SPDFIsIdentifierStart([code characterAtIndex:index + 1])) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            SPDFAddToken(tokens, index, end, SPDFMarkdownSyntaxTokenKeyword);
            index = end;
        } else if (SPDFIsIdentifierStart(character)) {
            NSUInteger end = SPDFScanIdentifier(code, index, cancellationToken);
            if (end == NSNotFound) return @[];
            NSString* word = [code substringWithRange:NSMakeRange(index, end - index)];
            if (grammar.caseInsensitiveKeywords) word = word.lowercaseString;
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
