#pragma once

#import <Foundation/Foundation.h>

#import "SPDFMarkdownAsync.h"
#import "SPDFMarkdownHighlighter.h"

NS_ASSUME_NONNULL_BEGIN

// Shared scanning primitives implemented in SPDFMarkdownHighlighter.mm. Every
// scanner returns the index one past the consumed token, or NSNotFound when
// the cancellation token fired mid-scan (callers then return @[]).
BOOL SPDFCancelled(SPDFMarkdownCancellationToken* _Nullable token, NSUInteger offset);
BOOL SPDFScanCancelled(SPDFMarkdownCancellationToken* _Nullable token, NSUInteger start, NSUInteger offset);
BOOL SPDFIsIdentifierStart(unichar character);
BOOL SPDFIsIdentifierContinue(unichar character);
BOOL SPDFIsDigit(unichar character);
BOOL SPDFIsWhitespace(unichar character);
void SPDFAddToken(NSMutableArray<SPDFMarkdownSyntaxToken*>* tokens, NSUInteger start, NSUInteger end,
                  SPDFMarkdownSyntaxTokenKind kind);
NSUInteger SPDFScanLineComment(NSString* code, NSUInteger start,
                               SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSUInteger SPDFScanQuoted(NSString* code, NSUInteger start, unichar quote, BOOL allowTriple,
                          SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSUInteger SPDFScanNumber(NSString* code, NSUInteger start,
                          SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSUInteger SPDFScanIdentifier(NSString* code, NSUInteger start,
                              SPDFMarkdownCancellationToken* _Nullable cancellationToken);

// Helpers implemented in SPDFMarkdownLexerSupport.mm.
BOOL SPDFLexMatches(NSString* code, NSUInteger index, NSString* _Nullable needle);
BOOL SPDFLexContainsCharacter(NSString* _Nullable set, unichar character);
NSUInteger SPDFLexScanUntil(NSString* code, NSUInteger start, NSString* close,
                            SPDFMarkdownCancellationToken* _Nullable cancellationToken);

// One parameterized rule set drives every braces-and-keywords language. Rules
// run in precedence order (block comment, line comment, string, number,
// sigil, keyword) and each rule consumes forward, so accepted token ranges can
// never overlap — the same guarantee the dedicated lexers provide.
@interface SPDFMarkdownLexerGrammar : NSObject
@property(nonatomic, copy, nullable) NSString* lineComment;          // e.g. "//", "#", "--", "%"
@property(nonatomic, copy, nullable) NSString* alternateLineComment; // e.g. PHP's "#" next to "//"
@property(nonatomic, copy, nullable) NSString* blockCommentOpen;     // e.g. "/*", "{-", "--[["
@property(nonatomic, copy, nullable) NSString* blockCommentClose;    // e.g. "*/", "-}", "]]"
@property(nonatomic, copy) NSString* quoteCharacters;                // string-opening quotes
@property(nonatomic) BOOL tripleQuotes;                              // """ and ''' long strings
@property(nonatomic) BOOL caseInsensitiveKeywords;                   // keywords stored lowercase
@property(nonatomic, copy, nullable) NSString* variableSigils;       // "$@" — sigil+name is a key
@property(nonatomic, copy, nullable) NSString* keywordSigils;        // "#@" — sigil+name is a keyword
@property(nonatomic, copy) NSSet<NSString*>* keywords;

// Space-separated keyword list; quotes default to double and single.
+ (instancetype)grammarWithKeywords:(NSString*)spaceSeparatedKeywords;
// Same, plus "//" line and "/* */" block comments.
+ (instancetype)cFamilyGrammarWithKeywords:(NSString*)spaceSeparatedKeywords;
@end

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanWithGrammar(
    SPDFMarkdownLexerGrammar* grammar, NSString* code,
    SPDFMarkdownCancellationToken* _Nullable cancellationToken);

// Family dispatchers. Each returns nil when the identifier is not one of its
// languages, and @[] when the scan was cancelled.
NSArray<SPDFMarkdownSyntaxToken*>* _Nullable SPDFMarkdownScanCFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSArray<SPDFMarkdownSyntaxToken*>* _Nullable SPDFMarkdownScanScripting(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSArray<SPDFMarkdownSyntaxToken*>* _Nullable SPDFMarkdownScanMarkupFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* _Nullable cancellationToken);
NSArray<SPDFMarkdownSyntaxToken*>* _Nullable SPDFMarkdownScanDataFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* _Nullable cancellationToken);

NS_ASSUME_NONNULL_END
