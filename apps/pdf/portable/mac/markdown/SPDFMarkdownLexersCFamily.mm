#import "SPDFMarkdownLexers.h"

// Grammar instances for the braces-and-keywords compiled languages. Built
// once; the sets stay alive for the process like the other keyword tables.

static NSString* const SPDFCKeywords =
    @"auto break case char const continue default do double else enum extern float for goto if "
    @"inline int long register restrict return short signed sizeof static struct switch typedef "
    @"union unsigned void volatile while _Atomic _Bool _Complex _Generic _Noreturn _Static_assert "
    @"_Thread_local bool true false NULL size_t ssize_t int8_t int16_t int32_t int64_t uint8_t "
    @"uint16_t uint32_t uint64_t uintptr_t intptr_t";

static NSString* const SPDFCppExtraKeywords =
    @" alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr "
    @"constinit const_cast co_await co_return co_yield decltype delete dynamic_cast explicit "
    @"export final friend mutable namespace new noexcept not not_eq nullptr operator or or_eq "
    @"override private protected public reinterpret_cast requires static_assert static_cast "
    @"template this thread_local throw try typeid typename using virtual xor xor_eq wchar_t "
    @"char8_t char16_t char32_t";

static NSString* const SPDFObjCExtraKeywords =
    @" id instancetype self super nil Nil YES NO BOOL SEL IMP Class in out inout bycopy byref "
    @"oneway nonatomic atomic strong weak copy assign readonly readwrite retain nullable nonnull "
    @"instancetype NSInteger NSUInteger CGFloat unichar";

static NSDictionary<NSString*, SPDFMarkdownLexerGrammar*>* SPDFCFamilyGrammars(void) {
    static NSDictionary<NSString*, SPDFMarkdownLexerGrammar*>* grammars;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary* map = [NSMutableDictionary dictionary];

        SPDFMarkdownLexerGrammar* c = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:SPDFCKeywords];
        c.keywordSigils = @"#";  // preprocessor directives
        map[@"c"] = c;

        SPDFMarkdownLexerGrammar* cpp = [SPDFMarkdownLexerGrammar
            cFamilyGrammarWithKeywords:[SPDFCKeywords stringByAppendingString:SPDFCppExtraKeywords]];
        cpp.keywordSigils = @"#";
        map[@"cpp"] = cpp;

        SPDFMarkdownLexerGrammar* objc = [SPDFMarkdownLexerGrammar
            cFamilyGrammarWithKeywords:[SPDFCKeywords stringByAppendingString:SPDFObjCExtraKeywords]];
        objc.keywordSigils = @"#@";  // preprocessor plus @directives; @"…" still lexes as a string
        map[@"objc"] = objc;

        map[@"csharp"] = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"abstract as async await base bool break byte case catch char checked class const "
            @"continue decimal default delegate do double dynamic else enum event explicit extern "
            @"false finally fixed float for foreach get goto if implicit in init int interface "
            @"internal is lock long namespace new null object operator out override params private "
            @"protected public readonly record ref required return sbyte sealed set short sizeof "
            @"stackalloc static string struct switch this throw true try typeof uint ulong "
            @"unchecked unsafe ushort using value var virtual void volatile when where while yield"];

        map[@"java"] = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"abstract assert boolean break byte case catch char class const continue default do "
            @"double else enum extends false final finally float for goto if implements import "
            @"instanceof int interface long native new null package permits private protected "
            @"public record return sealed short static strictfp super switch synchronized this "
            @"throw throws transient true try var void volatile while yield"];

        SPDFMarkdownLexerGrammar* kotlin = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"abstract actual annotation as break by catch class companion const constructor "
            @"continue crossinline data do dynamic else enum expect external false final finally "
            @"for fun get if import in infix init inline inner interface internal is lateinit "
            @"noinline null object open operator out override package private protected public "
            @"reified return sealed set super suspend tailrec this throw true try typealias val "
            @"var vararg when where while"];
        kotlin.tripleQuotes = YES;
        map[@"kotlin"] = kotlin;

        SPDFMarkdownLexerGrammar* go = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"append bool break byte cap case chan complex64 complex128 const continue copy "
            @"default defer delete else error fallthrough false float32 float64 for func go goto "
            @"if import int int8 int16 int32 int64 interface iota len make map new nil package "
            @"panic range recover return rune select string struct switch true type uint uint8 "
            @"uint16 uint32 uint64 uintptr var"];
        go.quoteCharacters = @"\"'`";  // backtick raw strings
        map[@"go"] = go;

        SPDFMarkdownLexerGrammar* rust = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"as async await bool box break char const continue crate dyn else enum extern f32 "
            @"f64 false fn for i8 i16 i32 i64 i128 if impl in isize let loop match mod move mut "
            @"pub ref return self Self static str struct super trait true type u8 u16 u32 u64 "
            @"u128 union unsafe use usize where while Some None Ok Err Vec String Box Option Result"];
        rust.quoteCharacters = @"\"";  // lifetimes ('a) make lone quotes ambiguous
        map[@"rust"] = rust;

        SPDFMarkdownLexerGrammar* dart = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"abstract as assert async await base bool break case catch class const continue "
            @"covariant default deferred do double dynamic else enum export extends extension "
            @"external factory false final finally for get hide if implements import in int "
            @"interface is late library mixin new null num on operator part required rethrow "
            @"return sealed set show static super switch sync this throw true try typedef var "
            @"void when while with yield String List Map Set"];
        dart.tripleQuotes = YES;
        map[@"dart"] = dart;

        SPDFMarkdownLexerGrammar* scala = [SPDFMarkdownLexerGrammar cFamilyGrammarWithKeywords:
            @"abstract case catch class def do else enum extends false final finally for forSome "
            @"given if implicit import lazy match new null object override package private "
            @"protected return sealed super then this throw trait true try type using val var "
            @"while with yield"];
        scala.tripleQuotes = YES;
        map[@"scala"] = scala;

        grammars = [map copy];
    });
    return grammars;
}

NSArray<SPDFMarkdownSyntaxToken*>* SPDFMarkdownScanCFamily(
    NSString* identifier, NSString* code, SPDFMarkdownCancellationToken* cancellationToken) {
    SPDFMarkdownLexerGrammar* grammar = SPDFCFamilyGrammars()[identifier];
    return grammar ? SPDFMarkdownScanWithGrammar(grammar, code, cancellationToken) : nil;
}
