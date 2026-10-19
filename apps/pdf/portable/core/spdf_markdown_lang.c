/* spdf_markdown_lang.c -- the 31-language catalog, its fence aliases, and the
 * one parameterised scanner most of them share.
 *
 * Ported from portable/mac/markdown/SPDFMarkdownLanguage.mm,
 * SPDFMarkdownLexerSupport.mm, SPDFMarkdownLexersCFamily.mm and
 * SPDFMarkdownLexersScripting.mm, keyword sets verbatim. The architecture is
 * the Mac's: rules run in precedence order -- block comment, line comment,
 * string, number, sigil variable, sigil keyword, identifier -- and each accepted
 * token is consumed whole before scanning resumes, so tokens are emitted in
 * order and can never overlap (a keyword inside a string is a string).
 *
 * Scanning is over UTF-8 BYTES. Any byte >= 0x80 counts as an identifier
 * character, which is the byte-level shape of "letterCharacterSet": a Greek or
 * CJK identifier is one token, and no multi-byte sequence is ever split.
 */
#include "spdf_markdown.h"

#include <ctype.h>
#include <string.h>

/* --- catalog ------------------------------------------------------------------ */

static const spdf_markdown_language k_languages[] = {
    {"c", "C", "h"},
    {"csharp", "C#", "cs c#"},
    {"cpp", "C++", "c++ cc cxx hpp hxx hh"},
    {"css", "CSS", "scss less"},
    {"dart", "Dart", ""},
    {"go", "Go", "golang"},
    {"haskell", "Haskell", "hs"},
    {"html", "HTML", "htm xhtml"},
    {"java", "Java", ""},
    {"javascript", "JavaScript", "js jsx mjs"},
    {"json", "JSON", "jsonc"},
    {"kotlin", "Kotlin", "kt kts"},
    {"latex", "LaTeX", "tex sty"},
    {"lua", "Lua", ""},
    {"markdown", "Markdown", "md"},
    {"objc", "Objective-C", "objective-c objectivec m mm"},
    {"perl", "Perl", "pl pm"},
    {"php", "PHP", ""},
    /* Plain Text is the explicit "no highlighting" choice. */
    {"plain", "Plain Text", "text txt plaintext plain-text none"},
    {"python", "Python", "py"},
    {"r", "R", "rscript"},
    {"ruby", "Ruby", "rb"},
    {"rust", "Rust", "rs"},
    {"scala", "Scala", "sbt"},
    {"shell", "Shell", "sh bash zsh ksh console shellsession"},
    {"sql", "SQL", "mysql postgres postgresql sqlite tsql plsql"},
    {"swift", "Swift", ""},
    {"toml", "TOML", "ini"},
    {"typescript", "TypeScript", "ts tsx mts cts"},
    {"xml", "XML", "svg plist xsl xsd rss"},
    {"yaml", "YAML", "yml"},
};

int spdf_markdown_language_count(void) {
    return (int)(sizeof(k_languages) / sizeof(k_languages[0]));
}

const spdf_markdown_language* spdf_markdown_language_at(int index) {
    return index >= 0 && index < spdf_markdown_language_count() ? &k_languages[index] : NULL;
}

/* Is `word` (len bytes, compared case-insensitively) one of the space-separated
 * entries of `list`? Shared by alias lookup and keyword tests. */
static int word_in_list(const char* word, size_t len, const char* list, int fold) {
    while (*list) {
        const char* end = strchr(list, ' ');
        size_t n = end ? (size_t)(end - list) : strlen(list);
        if (n == len) {
            size_t i;
            for (i = 0; i < n; ++i) {
                int a = fold ? tolower((unsigned char)word[i]) : (unsigned char)word[i];
                if (a != (unsigned char)list[i]) break;
            }
            if (i == n) return 1;
        }
        list += n;
        while (*list == ' ') ++list;
    }
    return 0;
}

static size_t first_token(const char* info, size_t len, const char** start) {
    size_t i = 0, j;
    while (i < len && isspace((unsigned char)info[i])) ++i;
    j = i;
    while (j < len && !isspace((unsigned char)info[j])) ++j;
    *start = info + i;
    return j - i;
}

const spdf_markdown_language* spdf_markdown_language_for_fence(const char* info, size_t len) {
    const char* tok;
    size_t n;
    int i;

    if (!info) return NULL;
    n = first_token(info, len, &tok);
    if (!n) return NULL;
    for (i = 0; i < spdf_markdown_language_count(); ++i) {
        if (word_in_list(tok, n, k_languages[i].id, 1) || word_in_list(tok, n, k_languages[i].aliases, 1))
            return &k_languages[i];
    }
    return NULL;
}

/* Case-insensitive substring, ASCII-folded -- the language names and ids are
 * all ASCII, and a query is a person typing at a picker. */
static int contains_fold(const char* hay, const char* needle) {
    size_t n = strlen(needle);
    size_t h = strlen(hay);
    size_t i, j;
    if (n == 0) return 1;
    if (h < n) return 0;
    for (i = 0; i + n <= h; ++i) {
        for (j = 0; j < n; ++j)
            if (tolower((unsigned char)hay[i + j]) != tolower((unsigned char)needle[j])) break;
        if (j == n) return 1;
    }
    return 0;
}

int spdf_markdown_language_matches(int index, const char* query) {
    const spdf_markdown_language* l = spdf_markdown_language_at(index);
    const char* q = query ? query : "";
    while (*q == ' ' || *q == '\t') ++q;
    if (!l) return 0;
    if (!*q) return 1; /* an empty query shows the whole catalog */
    return contains_fold(l->id, q) || contains_fold(l->name, q) || contains_fold(l->aliases, q);
}

int spdf_markdown_is_diagram_fence(const char* info, size_t len) {
    const char* tok = NULL;
    size_t n = info ? first_token(info, len, &tok) : 0;
    return n && word_in_list(tok, n, "mermaid sequence flow", 1);
}

/* --- grammar-driven scanner --------------------------------------------------- */

typedef struct grammar {
    const char* id;
    const char* keywords;
    const char* line_comment;
    const char* alt_line_comment;
    const char* block_open;
    const char* block_close;
    const char* quotes;
    const char* variable_sigils;
    const char* keyword_sigils;
    int triple_quotes;
    int fold_keywords;
} grammar;

#define C_KEYWORDS                                                                                               \
    "auto break case char const continue default do double else enum extern float for goto if inline int long " \
    "register restrict return short signed sizeof static struct switch typedef union unsigned void volatile "    \
    "while _Atomic _Bool _Complex _Generic _Noreturn _Static_assert _Thread_local bool true false NULL size_t "  \
    "ssize_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t uintptr_t intptr_t"
#define CPP_EXTRA                                                                                                  \
    " alignas alignof and and_eq asm bitand bitor catch class compl concept consteval constexpr constinit "      \
    "const_cast co_await co_return co_yield decltype delete dynamic_cast explicit export final friend mutable "  \
    "namespace new noexcept not not_eq nullptr operator or or_eq override private protected public "             \
    "reinterpret_cast requires static_assert static_cast template this thread_local throw try typeid typename " \
    "using virtual xor xor_eq wchar_t char8_t char16_t char32_t"
#define OBJC_EXTRA                                                                                                  \
    " id instancetype self super nil Nil YES NO BOOL SEL IMP Class in out inout bycopy byref oneway nonatomic " \
    "atomic strong weak copy assign readonly readwrite retain nullable nonnull NSInteger NSUInteger CGFloat "    \
    "unichar"

static const grammar k_grammars[] = {
    {"c", C_KEYWORDS, "//", NULL, "/*", "*/", "\"'", NULL, "#", 0, 0},
    {"cpp", C_KEYWORDS CPP_EXTRA, "//", NULL, "/*", "*/", "\"'", NULL, "#", 0, 0},
    {"objc", C_KEYWORDS OBJC_EXTRA, "//", NULL, "/*", "*/", "\"'", NULL, "#@", 0, 0},
    {"csharp",
     "abstract as async await base bool break byte case catch char checked class const continue decimal default "
     "delegate do double dynamic else enum event explicit extern false finally fixed float for foreach get goto if "
     "implicit in init int interface internal is lock long namespace new null object operator out override params "
     "private protected public readonly record ref required return sbyte sealed set short sizeof stackalloc static "
     "string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using value var virtual "
     "void volatile when where while yield",
     "//", NULL, "/*", "*/", "\"'", NULL, NULL, 0, 0},
    {"java",
     "abstract assert boolean break byte case catch char class const continue default do double else enum extends "
     "false final finally float for goto if implements import instanceof int interface long native new null "
     "package permits private protected public record return sealed short static strictfp super switch "
     "synchronized this throw throws transient true try var void volatile while yield",
     "//", NULL, "/*", "*/", "\"'", NULL, NULL, 0, 0},
    {"kotlin",
     "abstract actual annotation as break by catch class companion const constructor continue crossinline data do "
     "dynamic else enum expect external false final finally for fun get if import in infix init inline inner "
     "interface internal is lateinit noinline null object open operator out override package private protected "
     "public reified return sealed set super suspend tailrec this throw true try typealias val var vararg when "
     "where while",
     "//", NULL, "/*", "*/", "\"'", NULL, NULL, 1, 0},
    {"go",
     "append bool break byte cap case chan complex64 complex128 const continue copy default defer delete else "
     "error fallthrough false float32 float64 for func go goto if import int int8 int16 int32 int64 interface "
     "iota len make map new nil package panic range recover return rune select string struct switch true type "
     "uint uint8 uint16 uint32 uint64 uintptr var",
     "//", NULL, "/*", "*/", "\"'`", NULL, NULL, 0, 0},
    {"rust",
     "as async await bool box break char const continue crate dyn else enum extern f32 f64 false fn for i8 i16 "
     "i32 i64 i128 if impl in isize let loop match mod move mut pub ref return self Self static str struct super "
     "trait true type u8 u16 u32 u64 u128 union unsafe use usize where while Some None Ok Err Vec String Box "
     "Option Result",
     "//", NULL, "/*", "*/", "\"", NULL, NULL, 0, 0},
    {"dart",
     "abstract as assert async await base bool break case catch class const continue covariant default deferred "
     "do double dynamic else enum export extends extension external factory false final finally for get hide if "
     "implements import in int interface is late library mixin new null num on operator part required rethrow "
     "return sealed set show static super switch sync this throw true try typedef var void when while with yield "
     "String List Map Set",
     "//", NULL, "/*", "*/", "\"'", NULL, NULL, 1, 0},
    {"scala",
     "abstract case catch class def do else enum extends false final finally for forSome given if implicit "
     "import lazy match new null object override package private protected return sealed super then this throw "
     "trait true try type using val var while with yield",
     "//", NULL, "/*", "*/", "\"'", NULL, NULL, 1, 0},
    {"ruby",
     "alias and attr_accessor attr_reader attr_writer begin break case class def do else elsif end ensure extend "
     "false for if in include lambda module new next nil not or private protected public puts raise redo require "
     "require_relative rescue retry return self super then true undef unless until when while yield",
     "#", NULL, NULL, NULL, "\"'", "@$", NULL, 0, 0},
    {"php",
     "abstract and array as bool break callable case catch class clone const continue declare default do echo "
     "else elseif empty enum extends false final finally float fn for foreach function global goto if implements "
     "include include_once instanceof insteadof int interface isset list match mixed namespace never new null or "
     "print private protected public readonly require require_once return static string switch this throw trait "
     "true try unset use var void while xor yield",
     "//", "#", "/*", "*/", "\"'", "$", NULL, 0, 0},
    {"shell",
     "alias break case cd continue coproc declare do done echo elif else esac eval exec exit export false fi for "
     "function if in local printf read readonly return select set shift source test then time trap true typeset "
     "unalias unset until wait while",
     "#", NULL, NULL, NULL, "\"'`", "$", NULL, 0, 0},
    {"perl",
     "and bless chomp chop cmp defined delete die do each else elsif eq exists for foreach ge goto grep gt if "
     "index join keys last lc le length local lt map my ne next no not or our package pop print printf push redo "
     "ref require return reverse say scalar shift sort splice split sub substr uc undef unless unshift until use "
     "values wantarray warn while",
     "#", NULL, NULL, NULL, "\"'", "$@%", NULL, 0, 0},
    {"lua",
     "and break do else elseif end error false for function goto if in ipairs local nil not or pairs pcall print "
     "repeat require return self then tonumber tostring true type until while",
     "--", NULL, "--[[", "]]", "\"'", NULL, NULL, 0, 0},
    {"r",
     "break else FALSE for function if in Inf library NA NA_character_ NA_integer_ NA_real_ NaN next NULL repeat "
     "require return TRUE while",
     "#", NULL, NULL, NULL, "\"'", NULL, NULL, 0, 0},
    {"haskell",
     "as case class data default deriving do else family forall foreign hiding if import in infix infixl infixr "
     "instance let mdo module newtype of pattern qualified role then type where",
     "--", NULL, "{-", "-}", "\"", NULL, NULL, 0, 0},
    {"sql",
     "add all alter and as asc begin between bigint boolean by case char check column commit constraint create "
     "cross database date decimal default delete desc distinct double drop else end except exists foreign from "
     "full grant group having if in index inner insert int integer intersect into is join key left like limit not "
     "null numeric offset on or order outer primary recursive references replace returning revoke right rollback "
     "select serial set smallint table text then timestamp transaction truncate union unique update values "
     "varchar view when where with",
     "--", NULL, "/*", "*/", "\"'`", NULL, NULL, 0, 1},
};

/* --- lexer primitives (shared with spdf_markdown_lex.c) ------------------------ */

int spdf_md_lex_ident_start(unsigned char c) {
    return c >= 0x80 || isalpha(c) || c == '_' || c == '$';
}

int spdf_md_lex_ident_continue(unsigned char c) {
    return spdf_md_lex_ident_start(c) || isdigit(c);
}

int spdf_md_lex_matches(const char* code, size_t len, size_t i, const char* needle) {
    size_t n = needle ? strlen(needle) : 0;
    return n && i + n <= len && memcmp(code + i, needle, n) == 0;
}

size_t spdf_md_lex_until(const char* code, size_t len, size_t i, const char* close) {
    size_t n = strlen(close);
    for (; i < len; ++i)
        if (spdf_md_lex_matches(code, len, i, close)) return i + n;
    return len;
}

size_t spdf_md_lex_line(const char* code, size_t len, size_t i) {
    while (i < len && code[i] != '\n') ++i;
    return i;
}

size_t spdf_md_lex_quoted(const char* code, size_t len, size_t i, char quote, int allow_triple) {
    int triple = allow_triple && i + 2 < len && code[i + 1] == quote && code[i + 2] == quote;
    i += triple ? 3 : 1;
    while (i < len) {
        if (code[i] == '\\') {
            i = i + 2 < len ? i + 2 : len;
            continue;
        }
        if (triple) {
            if (i + 2 < len && code[i] == quote && code[i + 1] == quote && code[i + 2] == quote) return i + 3;
        } else if (code[i] == quote) {
            return i + 1;
        }
        ++i;
    }
    return len;
}

size_t spdf_md_lex_number(const char* code, size_t len, size_t i) {
    size_t start = i;
    if (i + 1 < len && code[i] == '0' && (code[i + 1] == 'x' || code[i + 1] == 'X')) {
        i += 2;
        while (i < len && (isxdigit((unsigned char)code[i]) || code[i] == '_')) ++i;
        return i;
    }
    if (i + 1 < len && code[i] == '0' && (code[i + 1] == 'b' || code[i + 1] == 'B')) {
        i += 2;
        while (i < len && (code[i] == '0' || code[i] == '1' || code[i] == '_')) ++i;
        return i;
    }
    while (i < len && (isdigit((unsigned char)code[i]) || code[i] == '_')) ++i;
    if (i + 1 < len && code[i] == '.' && isdigit((unsigned char)code[i + 1])) {
        ++i;
        while (i < len && (isdigit((unsigned char)code[i]) || code[i] == '_')) ++i;
    }
    if (i < len && (code[i] == 'e' || code[i] == 'E')) {
        size_t exponent = i++;
        size_t digits;
        if (i < len && (code[i] == '+' || code[i] == '-')) ++i;
        digits = i;
        while (i < len && (isdigit((unsigned char)code[i]) || code[i] == '_')) ++i;
        if (digits == i) i = exponent;
    }
    if (i < len && code[i] == 'n') ++i;
    return i > start ? i : start + 1;
}

size_t spdf_md_lex_ident(const char* code, size_t len, size_t i) {
    ++i;
    while (i < len && spdf_md_lex_ident_continue((unsigned char)code[i])) ++i;
    return i;
}

static size_t scan_sigil_variable(const char* code, size_t len, size_t i) {
    size_t cursor = i + 1;
    if (cursor < len && code[cursor] == '{') {
        ++cursor;
        while (cursor < len && code[cursor] != '}' && code[cursor] != '\n') ++cursor;
        if (cursor < len && code[cursor] == '}') ++cursor;
        return cursor;
    }
    while (cursor < len && spdf_md_lex_ident_continue((unsigned char)code[cursor])) ++cursor;
    return cursor;
}

static int scan_grammar(const grammar* g, const char* code, size_t len, spdf_md_tokens* out) {
    size_t i = 0;

    while (i < len) {
        unsigned char c = (unsigned char)code[i];
        size_t end;
        if (spdf_md_lex_matches(code, len, i, g->block_open)) {
            end = spdf_md_lex_until(code, len, i + strlen(g->block_open), g->block_close);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (spdf_md_lex_matches(code, len, i, g->line_comment) ||
                   spdf_md_lex_matches(code, len, i, g->alt_line_comment)) {
            end = spdf_md_lex_line(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_COMMENT);
        } else if (g->quotes && strchr(g->quotes, (char)c)) {
            end = spdf_md_lex_quoted(code, len, i, (char)c, g->triple_quotes);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_STRING);
        } else if (isdigit(c)) {
            end = spdf_md_lex_number(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_NUMBER);
        } else if (g->variable_sigils && strchr(g->variable_sigils, (char)c) && i + 1 < len &&
                   (spdf_md_lex_ident_start((unsigned char)code[i + 1]) || code[i + 1] == '{')) {
            end = scan_sigil_variable(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEY);
        } else if (g->keyword_sigils && strchr(g->keyword_sigils, (char)c) && i + 1 < len &&
                   spdf_md_lex_ident_start((unsigned char)code[i + 1])) {
            end = spdf_md_lex_ident(code, len, i);
            spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
        } else if (spdf_md_lex_ident_start(c)) {
            end = spdf_md_lex_ident(code, len, i);
            if (word_in_list(code + i, end - i, g->keywords, g->fold_keywords))
                spdf_md_tokens_add(out, i, end, SPDF_MD_TOKEN_KEYWORD);
        } else {
            end = i + 1;
        }
        i = end > i ? end : i + 1;
    }
    return 1;
}

int spdf_md_lex_grammar(const char* id, const char* code, size_t len, spdf_md_tokens* out) {
    size_t i;
    for (i = 0; i < sizeof(k_grammars) / sizeof(k_grammars[0]); ++i)
        if (strcmp(k_grammars[i].id, id) == 0) return scan_grammar(&k_grammars[i], code, len, out);
    return 0;
}
