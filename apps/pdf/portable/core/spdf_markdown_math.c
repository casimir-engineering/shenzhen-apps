/* spdf_markdown_math.c -- the LaTeX subset, typeset as HTML.
 *
 * Ported from portable/mac/markdown/SPDFMarkdownMathTypesetter.mm with the
 * same contract: whatever visible text comes out IS the searchable text
 * (x^2 is findable as "x2"), no content is ever dropped, and an unknown
 * command degrades to its visible \name in the code font. The Mac emits
 * attributed runs; here the same decisions become <i>, <b>, <sup>, <sub> and
 * <code>, which MuPDF's engine sizes and shifts exactly as the stylesheet
 * says (sub/sup at 0.75em on the default vertical-align).
 *
 * Deliberate limits, shared with macOS: no overline on a radical (a
 * multi-character radicand is parenthesised), fractions collapse to a vulgar
 * fraction when Unicode has one and to numerator ⁄ denominator otherwise, and
 * nesting beyond one script level keeps the depth-1 size.
 */
#include "spdf_markdown.h"

#include <ctype.h>
#include <string.h>

typedef struct symbol {
    const char* name;
    const char* text;
} symbol;

static const symbol k_symbols[] = {
    {"alpha", "α"}, {"beta", "β"}, {"gamma", "γ"}, {"delta", "δ"}, {"epsilon", "ε"}, {"varepsilon", "ε"},
    {"zeta", "ζ"}, {"eta", "η"}, {"theta", "θ"}, {"vartheta", "ϑ"}, {"iota", "ι"}, {"kappa", "κ"},
    {"lambda", "λ"}, {"mu", "μ"}, {"nu", "ν"}, {"xi", "ξ"}, {"omicron", "ο"}, {"pi", "π"}, {"varpi", "ϖ"},
    {"rho", "ρ"}, {"sigma", "σ"}, {"varsigma", "ς"}, {"tau", "τ"}, {"upsilon", "υ"}, {"phi", "φ"},
    {"varphi", "ϕ"}, {"chi", "χ"}, {"psi", "ψ"}, {"omega", "ω"}, {"Gamma", "Γ"}, {"Delta", "Δ"},
    {"Theta", "Θ"}, {"Lambda", "Λ"}, {"Xi", "Ξ"}, {"Pi", "Π"}, {"Sigma", "Σ"}, {"Upsilon", "Υ"}, {"Phi", "Φ"},
    {"Psi", "Ψ"}, {"Omega", "Ω"},
    {"times", "×"}, {"cdot", "⋅"}, {"div", "÷"}, {"pm", "±"}, {"mp", "∓"}, {"ast", "∗"}, {"star", "⋆"},
    {"circ", "∘"}, {"bullet", "•"}, {"oplus", "⊕"}, {"ominus", "⊖"}, {"otimes", "⊗"}, {"odot", "⊙"},
    {"wedge", "∧"}, {"vee", "∨"}, {"land", "∧"}, {"lor", "∨"}, {"neg", "¬"}, {"lnot", "¬"}, {"setminus", "∖"},
    {"le", "≤"}, {"leq", "≤"}, {"ge", "≥"}, {"geq", "≥"}, {"ne", "≠"}, {"neq", "≠"}, {"approx", "≈"},
    {"equiv", "≡"}, {"sim", "∼"}, {"simeq", "≃"}, {"cong", "≅"}, {"propto", "∝"}, {"ll", "≪"}, {"gg", "≫"},
    {"prec", "≺"}, {"succ", "≻"}, {"mid", "∣"}, {"perp", "⊥"}, {"parallel", "∥"}, {"asymp", "≍"},
    {"in", "∈"}, {"notin", "∉"}, {"ni", "∋"}, {"subset", "⊂"}, {"supset", "⊃"}, {"subseteq", "⊆"},
    {"supseteq", "⊇"}, {"cup", "∪"}, {"cap", "∩"}, {"emptyset", "∅"}, {"varnothing", "∅"}, {"forall", "∀"},
    {"exists", "∃"}, {"nexists", "∄"},
    {"sum", "∑"}, {"prod", "∏"}, {"int", "∫"}, {"iint", "∬"}, {"iiint", "∭"}, {"oint", "∮"}, {"partial", "∂"},
    {"nabla", "∇"}, {"infty", "∞"}, {"coprod", "∐"}, {"bigcup", "⋃"}, {"bigcap", "⋂"}, {"bigoplus", "⨁"},
    {"bigotimes", "⨂"},
    {"to", "→"}, {"rightarrow", "→"}, {"leftarrow", "←"}, {"gets", "←"}, {"Rightarrow", "⇒"}, {"Leftarrow", "⇐"},
    {"leftrightarrow", "↔"}, {"Leftrightarrow", "⇔"}, {"mapsto", "↦"}, {"uparrow", "↑"}, {"downarrow", "↓"},
    {"implies", "⇒"}, {"iff", "⇔"}, {"longrightarrow", "⟶"}, {"longleftarrow", "⟵"}, {"hookrightarrow", "↪"},
    {"dots", "…"}, {"ldots", "…"}, {"cdots", "⋯"}, {"vdots", "⋮"}, {"ddots", "⋱"}, {"prime", "′"}, {"angle", "∠"},
    {"triangle", "△"}, {"degree", "°"}, {"hbar", "ℏ"}, {"ell", "ℓ"}, {"Re", "ℜ"}, {"Im", "ℑ"}, {"aleph", "ℵ"},
    {"wp", "℘"}, {"therefore", "∴"}, {"because", "∵"}, {"langle", "⟨"}, {"rangle", "⟩"}, {"lfloor", "⌊"},
    {"rfloor", "⌋"}, {"lceil", "⌈"}, {"rceil", "⌉"}, {"top", "⊤"}, {"bot", "⊥"}, {"vdash", "⊢"}, {"models", "⊨"},
    {"checkmark", "✓"}, {"dagger", "†"}, {"S", "§"},
};

static const char* const k_functions =
    "sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh coth log ln lg exp lim liminf limsup max min sup "
    "inf det dim ker gcd deg arg hom Pr mod bmod";

static const symbol k_fractions[] = {
    {"1/2", "½"}, {"1/3", "⅓"}, {"2/3", "⅔"}, {"1/4", "¼"}, {"3/4", "¾"}, {"1/5", "⅕"}, {"2/5", "⅖"},
    {"3/5", "⅗"}, {"4/5", "⅘"}, {"1/6", "⅙"}, {"5/6", "⅚"}, {"1/7", "⅐"}, {"1/8", "⅛"}, {"3/8", "⅜"},
    {"5/8", "⅝"}, {"7/8", "⅞"}, {"1/9", "⅑"}, {"1/10", "⅒"},
};

static const symbol k_blackboard[] = {{"C", "ℂ"}, {"H", "ℍ"}, {"N", "ℕ"}, {"P", "ℙ"}, {"Q", "ℚ"}, {"R", "ℝ"}, {"Z", "ℤ"}};

typedef struct style {
    unsigned depth; /* script nesting */
    int upright;
    int bold;
} style;

typedef struct scanner {
    const char* in;
    size_t len;
    size_t i;
} scanner;

static const char* lookup(const symbol* table, size_t count, const char* name, size_t n) {
    size_t i;
    for (i = 0; i < count; ++i)
        if (strlen(table[i].name) == n && memcmp(table[i].name, name, n) == 0) return table[i].text;
    return NULL;
}

static int in_word_list(const char* list, const char* name, size_t n) {
    while (*list) {
        const char* sp = strchr(list, ' ');
        size_t m = sp ? (size_t)(sp - list) : strlen(list);
        if (m == n && memcmp(list, name, n) == 0) return 1;
        list += m;
        while (*list == ' ') ++list;
    }
    return 0;
}

static char peek(const scanner* s) {
    return s->i < s->len ? s->in[s->i] : '\0';
}

static int is_letter(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static void emit(spdf_md_buf* out, const char* text, size_t n, const style* st, int italic, int code) {
    if (!n) return;
    if (code) spdf_md_buf_puts(out, "<code>");
    if (!code && st->bold) spdf_md_buf_puts(out, "<b>");
    if (!code && italic) spdf_md_buf_puts(out, "<i>");
    spdf_md_buf_escape(out, text, n);
    if (!code && italic) spdf_md_buf_puts(out, "</i>");
    if (!code && st->bold) spdf_md_buf_puts(out, "</b>");
    if (code) spdf_md_buf_puts(out, "</code>");
}

static void emit_s(spdf_md_buf* out, const char* text, const style* st) {
    /* Spacing commands and collapsed whitespace both produce " "; two in a row
     * (\text{if } n) would otherwise print a double space. */
    if (text[0] == ' ' && text[1] == '\0' && out->len && out->data[out->len - 1] == ' ') return;
    emit(out, text, strlen(text), st, 0, 0);
}

static void sequence(scanner* s, spdf_md_buf* out, const style* st);
static void command(scanner* s, spdf_md_buf* out, const style* st);

/* One atom: a braced group, a command, or a single character. */
static void atom(scanner* s, spdf_md_buf* out, const style* st) {
    char c;
    while (s->i < s->len && isspace((unsigned char)peek(s))) ++s->i;
    c = peek(s);
    if (!c) return;
    if (c == '{') {
        ++s->i;
        sequence(s, out, st);
        if (peek(s) == '}') ++s->i;
    } else if (c == '\\') {
        command(s, out, st);
    } else {
        /* One UTF-8 character. */
        size_t start = s->i++;
        while (s->i < s->len && ((unsigned char)s->in[s->i] & 0xC0) == 0x80) ++s->i;
        emit(out, s->in + start, s->i - start, st, is_letter(c) && !st->upright, 0);
    }
}

/* Typeset one atom into a scratch buffer (for \frac parts and radicands). */
static void fragment(scanner* s, const style* st, spdf_md_buf* frag) {
    spdf_md_buf_init(frag);
    atom(s, frag, st);
}

/* Visible text of a fragment with its tags stripped: the key for the vulgar
 * fraction table and the "is it one character" test. */
static size_t plain_text(const spdf_md_buf* frag, char* out, size_t cap) {
    size_t i, o = 0;
    int in_tag = 0;
    for (i = 0; i < frag->len && o + 1 < cap; ++i) {
        char c = frag->data[i];
        if (c == '<') in_tag = 1;
        else if (c == '>') in_tag = 0;
        else if (!in_tag) out[o++] = c;
    }
    out[o] = '\0';
    return o;
}

static void script(scanner* s, spdf_md_buf* out, const style* st, int superscript) {
    style inner = *st;
    inner.depth = st->depth + 1;
    spdf_md_buf_puts(out, superscript ? "<sup>" : "<sub>");
    atom(s, out, &inner);
    spdf_md_buf_puts(out, superscript ? "</sup>" : "</sub>");
}

static void frac(scanner* s, spdf_md_buf* out, const style* st) {
    spdf_md_buf num, den;
    char a[64], b[64], key[130];
    const char* vulgar;

    fragment(s, st, &num);
    fragment(s, st, &den);
    plain_text(&num, a, sizeof(a));
    plain_text(&den, b, sizeof(b));
    if (strlen(a) + strlen(b) + 2 <= sizeof(key)) {
        strcpy(key, a);
        strcat(key, "/");
        strcat(key, b);
        vulgar = lookup(k_fractions, sizeof(k_fractions) / sizeof(k_fractions[0]), key, strlen(key));
        if (vulgar) {
            emit_s(out, vulgar, st);
            spdf_md_buf_free(&num);
            spdf_md_buf_free(&den);
            return;
        }
    }
    spdf_md_buf_append(out, num.data, num.len);
    emit_s(out, " ⁄ ", st); /* FRACTION SLASH between thin spaces */
    spdf_md_buf_append(out, den.data, den.len);
    spdf_md_buf_free(&num);
    spdf_md_buf_free(&den);
}

/* Characters, not bytes: one radicand glyph needs no parentheses. */
static size_t utf8_count(const char* text) {
    size_t n = 0;
    for (; *text; ++text)
        if (((unsigned char)*text & 0xC0) != 0x80) ++n;
    return n;
}

static void sqrt_cmd(scanner* s, spdf_md_buf* out, const style* st) {
    spdf_md_buf rad;
    char text[64];

    if (peek(s) == '[') { /* \sqrt[3]{x}: the index becomes a superscript prefix */
        size_t start = ++s->i;
        while (s->i < s->len && peek(s) != ']') ++s->i;
        spdf_md_buf_puts(out, "<sup>");
        emit(out, s->in + start, s->i - start, st, 0, 0);
        spdf_md_buf_puts(out, "</sup>");
        if (peek(s) == ']') ++s->i;
    }
    emit_s(out, "√", st);
    fragment(s, st, &rad);
    plain_text(&rad, text, sizeof(text));
    if (utf8_count(text) > 1) {
        emit_s(out, "(", st);
        spdf_md_buf_append(out, rad.data, rad.len);
        emit_s(out, ")", st);
    } else {
        spdf_md_buf_append(out, rad.data, rad.len);
    }
    spdf_md_buf_free(&rad);
}

static void blackboard(scanner* s, spdf_md_buf* out, const style* st) {
    style upright = *st;
    spdf_md_buf frag;
    char text[64];
    size_t i;

    upright.upright = 1;
    fragment(s, &upright, &frag);
    plain_text(&frag, text, sizeof(text));
    for (i = 0; text[i]; ++i) {
        const char* mapped = lookup(k_blackboard, sizeof(k_blackboard) / sizeof(k_blackboard[0]), text + i, 1);
        if (mapped) emit_s(out, mapped, &upright);
        else emit(out, text + i, 1, &upright, 0, 0);
    }
    spdf_md_buf_free(&frag);
}

static void short_command(spdf_md_buf* out, const style* st, char c) {
    switch (c) {
        case ',': case ':': case ';': case ' ': case '\\': emit_s(out, " ", st); return;
        case '!': return; /* negative space */
        case '|': emit_s(out, "‖", st); return;
        default: emit(out, &c, 1, st, 0, 0); return; /* escaped literal: \{ \} \$ \% \& \# \_ */
    }
}

static int name_is(const char* name, size_t n, const char* want) {
    return strlen(want) == n && memcmp(name, want, n) == 0;
}

static void command(scanner* s, spdf_md_buf* out, const style* st) {
    size_t start;
    size_t n;
    const char* name;
    const char* sym;
    char c;

    ++s->i; /* the backslash */
    c = peek(s);
    if (!c) {
        emit(out, "\\", 1, st, 0, 1);
        return;
    }
    if (!is_letter(c)) {
        ++s->i;
        short_command(out, st, c);
        return;
    }
    start = s->i;
    while (s->i < s->len && is_letter(peek(s))) ++s->i;
    name = s->in + start;
    n = s->i - start;
    if (peek(s) == '*') ++s->i; /* starred variants behave like the base command */

    if (name_is(name, n, "quad")) { emit_s(out, " ", st); return; }
    if (name_is(name, n, "qquad")) { emit_s(out, "  ", st); return; }
    if (name_is(name, n, "frac") || name_is(name, n, "dfrac") || name_is(name, n, "tfrac")) { frac(s, out, st); return; }
    if (name_is(name, n, "sqrt")) { sqrt_cmd(s, out, st); return; }
    if (name_is(name, n, "text") || name_is(name, n, "textrm") || name_is(name, n, "mathrm") ||
        name_is(name, n, "operatorname") || name_is(name, n, "mathsf") || name_is(name, n, "textnormal")) {
        style upright = *st;
        upright.upright = 1;
        { atom(s, out, &upright); return; }
    }
    if (name_is(name, n, "mathbf") || name_is(name, n, "boldsymbol") || name_is(name, n, "bm") ||
        name_is(name, n, "textbf")) {
        style bold = *st;
        bold.bold = 1;
        bold.upright = 1;
        { atom(s, out, &bold); return; }
    }
    if (name_is(name, n, "mathit") || name_is(name, n, "textit") || name_is(name, n, "mathcal") ||
        name_is(name, n, "mathscr") || name_is(name, n, "mathfrak")) {
        style italic = *st;
        italic.upright = 0;
        { atom(s, out, &italic); return; }
    }
    if (name_is(name, n, "mathbb")) { blackboard(s, out, st); return; }
    if (name_is(name, n, "left") || name_is(name, n, "right")) {
        if (peek(s) == '.') ++s->i; /* \left. and \right. draw nothing */
        return;                     /* the delimiter itself flows through the sequence */
    }
    if (name_is(name, n, "begin") || name_is(name, n, "end")) {
        if (peek(s) == '{') { /* consume the environment name silently */
            while (s->i < s->len && peek(s) != '}') ++s->i;
            if (peek(s) == '}') ++s->i;
        }
        return;
    }
    if (name_is(name, n, "limits") || name_is(name, n, "nolimits") || name_is(name, n, "displaystyle") ||
        name_is(name, n, "textstyle") || name_is(name, n, "scriptstyle"))
        return;
    sym = lookup(k_symbols, sizeof(k_symbols) / sizeof(k_symbols[0]), name, n);
    if (sym) { emit_s(out, sym, st); return; }
    if (in_word_list(k_functions, name, n)) { emit(out, name, n, st, 0, 0); return; }
    /* Unknown: the visible command name in the code font, never dropped. */
    emit(out, name - 1, n + 1, st, 0, 1);
}

static void sequence(scanner* s, spdf_md_buf* out, const style* st) {
    while (s->i < s->len) {
        char c = s->in[s->i];
        size_t start;
        int italic;
        if (c == '}') return; /* the group opener consumes the brace */
        if (c == '{') {
            ++s->i;
            sequence(s, out, st);
            if (peek(s) == '}') ++s->i;
            continue;
        }
        if (c == '\\') {
            command(s, out, st);
            continue;
        }
        if (c == '^' || c == '_') {
            ++s->i;
            script(s, out, st, c == '^');
            continue;
        }
        if (c == '&') { /* alignment point: a wide gap */
            ++s->i;
            emit_s(out, " ", st);
            continue;
        }
        if (isspace((unsigned char)c)) { /* collapse runs to one space */
            while (s->i < s->len && isspace((unsigned char)s->in[s->i])) ++s->i;
            emit_s(out, " ", st);
            continue;
        }
        /* Batch consecutive plain characters sharing one italic class. */
        italic = is_letter(c) && !st->upright;
        start = s->i;
        while (s->i < s->len) {
            char v = s->in[s->i];
            if (v == '}' || v == '{' || v == '\\' || v == '^' || v == '_' || v == '&' || isspace((unsigned char)v))
                break;
            if ((is_letter(v) && !st->upright) != italic) break;
            ++s->i;
        }
        emit(out, s->in + start, s->i - start, st, italic, 0);
    }
}

void spdf_markdown_math_html(const char* latex, size_t len, int display, spdf_md_buf* out) {
    scanner s;
    style st;

    /* Trim the delimiters' surrounding whitespace as the Mac does. */
    while (len && isspace((unsigned char)latex[0])) ++latex, --len;
    while (len && isspace((unsigned char)latex[len - 1])) --len;
    s.in = latex;
    s.len = len;
    s.i = 0;
    memset(&st, 0, sizeof(st));
    spdf_md_buf_puts(out, display ? "<span class=\"mdisplay\">" : "<span class=\"math\">");
    while (s.i < s.len) {
        if (peek(&s) == '}') { /* stray closer: skip it, never drop the rest */
            ++s.i;
            continue;
        }
        sequence(&s, out, &st);
    }
    spdf_md_buf_puts(out, "</span>");
}
