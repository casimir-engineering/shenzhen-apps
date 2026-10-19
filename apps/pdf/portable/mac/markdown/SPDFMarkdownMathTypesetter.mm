#import "SPDFMarkdownMathTypesetter.h"

// Native LaTeX-subset math typesetting (see the header for the contract).
// Everything stays in the attributed-string world: Unicode symbols, smaller
// raised/lowered script runs, italic single-letter variables. No drawing
// layer, no WebKit, no network. Whatever visible text this file emits IS the
// canonical searchable text, so no zero-width or structural markers are ever
// produced.

NSAttributedStringKey const SPDFMarkdownMathLayoutAttribute = @"SPDFMarkdownMathLayout";

namespace {

struct MathStyle {
    CGFloat size;
    CGFloat baseline;
    unsigned scriptDepth;
    BOOL upright;
    BOOL bold;
};

struct MathScanner {
    NSString* input;
    NSUInteger index;
    NSFont* baseFont;
    NSFont* codeFont;
    NSColor* color;
};

}  // namespace

// Commands with a direct Unicode translation. Symbols render upright in the
// body font; the reading palette's body color applies to all of them.
static NSDictionary<NSString*, NSString*>* SPDFMathSymbols(void) {
    static NSDictionary* symbols;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      symbols = @{
          // Greek lowercase and uppercase (\alpha ... \Omega).
          @"alpha": @"α", @"beta": @"β", @"gamma": @"γ", @"delta": @"δ",
          @"epsilon": @"ε", @"varepsilon": @"ε", @"zeta": @"ζ", @"eta": @"η",
          @"theta": @"θ", @"vartheta": @"ϑ", @"iota": @"ι", @"kappa": @"κ",
          @"lambda": @"λ", @"mu": @"μ", @"nu": @"ν", @"xi": @"ξ",
          @"omicron": @"ο", @"pi": @"π", @"varpi": @"ϖ", @"rho": @"ρ",
          @"sigma": @"σ", @"varsigma": @"ς", @"tau": @"τ", @"upsilon": @"υ",
          @"phi": @"φ", @"varphi": @"ϕ", @"chi": @"χ", @"psi": @"ψ",
          @"omega": @"ω", @"Gamma": @"Γ", @"Delta": @"Δ", @"Theta": @"Θ",
          @"Lambda": @"Λ", @"Xi": @"Ξ", @"Pi": @"Π", @"Sigma": @"Σ",
          @"Upsilon": @"Υ", @"Phi": @"Φ", @"Psi": @"Ψ", @"Omega": @"Ω",
          // Binary operators.
          @"times": @"×", @"cdot": @"⋅", @"div": @"÷", @"pm": @"±",
          @"mp": @"∓", @"ast": @"∗", @"star": @"⋆", @"circ": @"∘",
          @"bullet": @"•", @"oplus": @"⊕", @"ominus": @"⊖", @"otimes": @"⊗",
          @"odot": @"⊙", @"wedge": @"∧", @"vee": @"∨", @"land": @"∧",
          @"lor": @"∨", @"neg": @"¬", @"lnot": @"¬", @"setminus": @"∖",
          // Relations.
          @"le": @"≤", @"leq": @"≤", @"ge": @"≥", @"geq": @"≥",
          @"ne": @"≠", @"neq": @"≠", @"approx": @"≈", @"equiv": @"≡",
          @"sim": @"∼", @"simeq": @"≃", @"cong": @"≅", @"propto": @"∝",
          @"ll": @"≪", @"gg": @"≫", @"prec": @"≺", @"succ": @"≻",
          @"mid": @"∣", @"perp": @"⊥", @"parallel": @"∥", @"asymp": @"≍",
          // Sets and logic.
          @"in": @"∈", @"notin": @"∉", @"ni": @"∋", @"subset": @"⊂",
          @"supset": @"⊃", @"subseteq": @"⊆", @"supseteq": @"⊇", @"cup": @"∪",
          @"cap": @"∩", @"emptyset": @"∅", @"varnothing": @"∅",
          @"forall": @"∀", @"exists": @"∃", @"nexists": @"∄",
          // Big operators and calculus.
          @"sum": @"∑", @"prod": @"∏", @"int": @"∫", @"iint": @"∬",
          @"iiint": @"∭", @"oint": @"∮", @"partial": @"∂", @"nabla": @"∇",
          @"infty": @"∞", @"coprod": @"∐", @"bigcup": @"⋃", @"bigcap": @"⋂",
          @"bigoplus": @"⨁", @"bigotimes": @"⨂",
          // Arrows.
          @"to": @"→", @"rightarrow": @"→", @"leftarrow": @"←", @"gets": @"←",
          @"Rightarrow": @"⇒", @"Leftarrow": @"⇐", @"leftrightarrow": @"↔",
          @"Leftrightarrow": @"⇔", @"mapsto": @"↦", @"uparrow": @"↑",
          @"downarrow": @"↓", @"implies": @"⇒", @"iff": @"⇔",
          @"longrightarrow": @"⟶", @"longleftarrow": @"⟵", @"hookrightarrow": @"↪",
          // Dots and misc.
          @"dots": @"…", @"ldots": @"…", @"cdots": @"⋯", @"vdots": @"⋮",
          @"ddots": @"⋱", @"prime": @"′", @"angle": @"∠", @"triangle": @"△",
          @"degree": @"°", @"hbar": @"ℏ", @"ell": @"ℓ", @"Re": @"ℜ",
          @"Im": @"ℑ", @"aleph": @"ℵ", @"wp": @"℘", @"therefore": @"∴",
          @"because": @"∵", @"langle": @"⟨", @"rangle": @"⟩",
          @"lfloor": @"⌊", @"rfloor": @"⌋", @"lceil": @"⌈", @"rceil": @"⌉",
          @"top": @"⊤", @"bot": @"⊥", @"vdash": @"⊢", @"models": @"⊨",
          @"checkmark": @"✓", @"dagger": @"†", @"S": @"§",
      };
    });
    return symbols;
}

// Operator names (\sin, \log, ...) set upright, LaTeX-style.
static NSSet<NSString*>* SPDFMathFunctionNames(void) {
    static NSSet* names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      names = [NSSet setWithArray:@[
          @"sin", @"cos", @"tan", @"cot", @"sec", @"csc", @"arcsin", @"arccos", @"arctan",
          @"sinh", @"cosh", @"tanh", @"coth", @"log", @"ln", @"lg", @"exp", @"lim", @"liminf",
          @"limsup", @"max", @"min", @"sup", @"inf", @"det", @"dim", @"ker", @"gcd", @"deg",
          @"arg", @"hom", @"Pr", @"mod", @"bmod"
      ]];
    });
    return names;
}

// \frac{1}{2} and friends collapse to the real Unicode vulgar fraction.
static NSDictionary<NSString*, NSString*>* SPDFMathVulgarFractions(void) {
    static NSDictionary* fractions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      fractions = @{
          @"1/2": @"½", @"1/3": @"⅓", @"2/3": @"⅔", @"1/4": @"¼",
          @"3/4": @"¾", @"1/5": @"⅕", @"2/5": @"⅖", @"3/5": @"⅗",
          @"4/5": @"⅘", @"1/6": @"⅙", @"5/6": @"⅚", @"1/7": @"⅐",
          @"1/8": @"⅛", @"3/8": @"⅜", @"5/8": @"⅝", @"7/8": @"⅞",
          @"1/9": @"⅑", @"1/10": @"⅒",
      };
    });
    return fractions;
}

// \mathbb{R} and the other common blackboard-bold letters.
static NSDictionary<NSString*, NSString*>* SPDFMathBlackboard(void) {
    static NSDictionary* letters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      letters = @{@"C": @"ℂ", @"H": @"ℍ", @"N": @"ℕ", @"P": @"ℙ",
                  @"Q": @"ℚ", @"R": @"ℝ", @"Z": @"ℤ"};
    });
    return letters;
}

static BOOL SPDFMathIsLetter(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

static unichar SPDFMathPeek(const MathScanner& s) {
    return s.index < s.input.length ? [s.input characterAtIndex:s.index] : 0;
}

static void SPDFMathEmit(const MathScanner& s, NSMutableAttributedString* out, NSString* text,
                         const MathStyle& style, BOOL italic, BOOL code) {
    if (!text.length) return;
    NSFontManager* manager = NSFontManager.sharedFontManager;
    NSFont* font = [manager convertFont:code ? s.codeFont : s.baseFont toSize:style.size]
                       ?: (code ? s.codeFont : s.baseFont);
    if (!code) {
        NSFontTraitMask traits = 0;
        if (italic) traits |= NSItalicFontMask;
        if (style.bold) traits |= NSBoldFontMask;
        if (traits) font = SPDFMarkdownFontWithTraits(font, traits);
    }
    NSMutableDictionary* attributes = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: s.color,
    } mutableCopy];
    if (style.baseline != 0) attributes[NSBaselineOffsetAttributeName] = @(style.baseline);
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:attributes]];
}

static void SPDFMathSequence(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style);

static void SPDFMathCommand(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style);

// One atom: a braced group, a command, or a single character. Used for script
// bases, \frac parts and \sqrt radicands.
static void SPDFMathAtom(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style) {
    while (s.index < s.input.length &&
           [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:SPDFMathPeek(s)])
        ++s.index;
    unichar c = SPDFMathPeek(s);
    if (!c) return;
    if (c == '{') {
        ++s.index;
        SPDFMathSequence(s, out, style);
        if (SPDFMathPeek(s) == '}') ++s.index;
    } else if (c == '\\') {
        SPDFMathCommand(s, out, style);
    } else {
        ++s.index;
        SPDFMathEmit(s, out, [NSString stringWithCharacters:&c length:1], style,
                     SPDFMathIsLetter(c) && !style.upright, NO);
    }
}

static NSMutableAttributedString* SPDFMathFragment(MathScanner& s, const MathStyle& style) {
    NSMutableAttributedString* fragment = [NSMutableAttributedString new];
    SPDFMathAtom(s, fragment, style);
    return fragment;
}

// Scripts shrink one visible step and shift off the baseline; nesting beyond
// one level keeps the depth-1 size so deep towers stay legible.
static MathStyle SPDFMathScriptStyle(const MathStyle& style, BOOL superscript) {
    MathStyle script = style;
    if (style.scriptDepth < 2) script.size = MAX(6.0, style.size * 0.7);
    script.baseline = style.baseline + (superscript ? 0.35 : -0.18) * style.size;
    script.scriptDepth = style.scriptDepth + 1;
    return script;
}

static void SPDFMathFrac(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style) {
    NSMutableAttributedString* numerator = SPDFMathFragment(s, style);
    NSMutableAttributedString* denominator = SPDFMathFragment(s, style);
    NSString* key = [NSString stringWithFormat:@"%@/%@", numerator.string, denominator.string];
    NSString* vulgar = SPDFMathVulgarFractions()[key];
    if (vulgar) {
        SPDFMathEmit(s, out, vulgar, style, NO, NO);
        return;
    }
    [out appendAttributedString:numerator];
    // FRACTION SLASH between thin spaces; parts keep their own styling.
    SPDFMathEmit(s, out, @" ⁄ ", style, NO, NO);
    [out appendAttributedString:denominator];
}

static void SPDFMathSqrt(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style) {
    if (SPDFMathPeek(s) == '[') {  // \sqrt[3]{x}: the index becomes a superscript prefix.
        ++s.index;
        NSUInteger start = s.index;
        while (s.index < s.input.length && SPDFMathPeek(s) != ']') ++s.index;
        NSString* degree = [s.input substringWithRange:NSMakeRange(start, s.index - start)];
        if (SPDFMathPeek(s) == ']') ++s.index;
        SPDFMathEmit(s, out, degree, SPDFMathScriptStyle(style, YES), NO, NO);
    }
    SPDFMathEmit(s, out, @"√", style, NO, NO);
    NSMutableAttributedString* radicand = SPDFMathFragment(s, style);
    // No overline without a drawing layer, so a multi-character radicand gets
    // explicit parentheses to keep its extent unambiguous (and searchable).
    BOOL wrap = radicand.string.length > 1;
    if (wrap) SPDFMathEmit(s, out, @"(", style, NO, NO);
    [out appendAttributedString:radicand];
    if (wrap) SPDFMathEmit(s, out, @")", style, NO, NO);
}

static void SPDFMathBlackboardGroup(MathScanner& s, NSMutableAttributedString* out,
                                    const MathStyle& style) {
    MathStyle upright = style;
    upright.upright = YES;
    NSMutableAttributedString* fragment = [NSMutableAttributedString new];
    SPDFMathAtom(s, fragment, upright);
    NSMutableString* mapped = [NSMutableString string];
    for (NSUInteger i = 0; i < fragment.string.length; ++i) {
        NSString* letter = [fragment.string substringWithRange:NSMakeRange(i, 1)];
        [mapped appendString:SPDFMathBlackboard()[letter] ?: letter];
    }
    SPDFMathEmit(s, out, mapped, upright, NO, NO);
}

// A single non-letter escape: spacing shorthands and escaped literals.
static void SPDFMathShortCommand(MathScanner& s, NSMutableAttributedString* out,
                                 const MathStyle& style, unichar c) {
    switch (c) {
        case ',': SPDFMathEmit(s, out, @" ", style, NO, NO); return;   // thin space
        case ':': SPDFMathEmit(s, out, @" ", style, NO, NO); return;   // medium space
        case ';': SPDFMathEmit(s, out, @" ", style, NO, NO); return;   // thick space
        case '!': return;                                                   // negative space
        case ' ': SPDFMathEmit(s, out, @" ", style, NO, NO); return;
        case '\\': SPDFMathEmit(s, out, @" ", style, NO, NO); return;  // line break
        case '|': SPDFMathEmit(s, out, @"‖", style, NO, NO); return;
        default:  // Escaped literals: \{ \} \$ \% \& \# \_ ...
            SPDFMathEmit(s, out, [NSString stringWithCharacters:&c length:1], style, NO, NO);
            return;
    }
}

static void SPDFMathCommand(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style) {
    ++s.index;  // The backslash.
    unichar c = SPDFMathPeek(s);
    if (!c) {
        SPDFMathEmit(s, out, @"\\", style, NO, YES);
        return;
    }
    if (!SPDFMathIsLetter(c)) {
        ++s.index;
        SPDFMathShortCommand(s, out, style, c);
        return;
    }
    NSUInteger start = s.index;
    while (s.index < s.input.length && SPDFMathIsLetter(SPDFMathPeek(s))) ++s.index;
    NSString* name = [s.input substringWithRange:NSMakeRange(start, s.index - start)];
    if (SPDFMathPeek(s) == '*') ++s.index;  // Starred variants behave like the base command.

    if ([name isEqualToString:@"quad"]) return SPDFMathEmit(s, out, @" ", style, NO, NO);
    if ([name isEqualToString:@"qquad"]) return SPDFMathEmit(s, out, @"  ", style, NO, NO);
    if ([name isEqualToString:@"frac"] || [name isEqualToString:@"dfrac"] ||
        [name isEqualToString:@"tfrac"])
        return SPDFMathFrac(s, out, style);
    if ([name isEqualToString:@"sqrt"]) return SPDFMathSqrt(s, out, style);
    if ([name isEqualToString:@"text"] || [name isEqualToString:@"textrm"] ||
        [name isEqualToString:@"mathrm"] || [name isEqualToString:@"operatorname"] ||
        [name isEqualToString:@"mathsf"] || [name isEqualToString:@"textnormal"]) {
        MathStyle upright = style;
        upright.upright = YES;
        return SPDFMathAtom(s, out, upright);
    }
    if ([name isEqualToString:@"mathbf"] || [name isEqualToString:@"boldsymbol"] ||
        [name isEqualToString:@"bm"] || [name isEqualToString:@"textbf"]) {
        MathStyle bold = style;
        bold.bold = YES;
        bold.upright = YES;
        return SPDFMathAtom(s, out, bold);
    }
    if ([name isEqualToString:@"mathit"] || [name isEqualToString:@"textit"] ||
        [name isEqualToString:@"mathcal"] || [name isEqualToString:@"mathscr"] ||
        [name isEqualToString:@"mathfrak"]) {
        MathStyle italic = style;
        italic.upright = NO;
        return SPDFMathAtom(s, out, italic);
    }
    if ([name isEqualToString:@"mathbb"]) return SPDFMathBlackboardGroup(s, out, style);
    if ([name isEqualToString:@"left"] || [name isEqualToString:@"right"]) {
        if (SPDFMathPeek(s) == '.') ++s.index;  // \left. / \right. draw nothing.
        return;  // The delimiter character itself flows through the sequence.
    }
    if ([name isEqualToString:@"begin"] || [name isEqualToString:@"end"]) {
        if (SPDFMathPeek(s) == '{') {  // Consume the environment name silently.
            while (s.index < s.input.length && SPDFMathPeek(s) != '}') ++s.index;
            if (SPDFMathPeek(s) == '}') ++s.index;
        }
        return;
    }
    if ([name isEqualToString:@"limits"] || [name isEqualToString:@"nolimits"] ||
        [name isEqualToString:@"displaystyle"] || [name isEqualToString:@"textstyle"] ||
        [name isEqualToString:@"scriptstyle"])
        return;
    NSString* symbol = SPDFMathSymbols()[name];
    if (symbol) return SPDFMathEmit(s, out, symbol, style, NO, NO);
    if ([SPDFMathFunctionNames() containsObject:name])
        return SPDFMathEmit(s, out, name, style, NO, NO);
    // Unknown command: degrade to the visible command name in the code font.
    // Content is never dropped and the name stays searchable as written.
    SPDFMathEmit(s, out, [@"\\" stringByAppendingString:name], style, NO, YES);
}

static void SPDFMathSequence(MathScanner& s, NSMutableAttributedString* out, const MathStyle& style) {
    NSCharacterSet* whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    while (s.index < s.input.length) {
        unichar c = [s.input characterAtIndex:s.index];
        if (c == '}') return;  // The group opener consumes the brace.
        if (c == '{') {
            ++s.index;
            SPDFMathSequence(s, out, style);
            if (SPDFMathPeek(s) == '}') ++s.index;
            continue;
        }
        if (c == '\\') {
            SPDFMathCommand(s, out, style);
            continue;
        }
        if (c == '^' || c == '_') {
            ++s.index;
            SPDFMathAtom(s, out, SPDFMathScriptStyle(style, c == '^'));
            continue;
        }
        if (c == '&') {  // Alignment point (aligned environments): a wide gap.
            ++s.index;
            SPDFMathEmit(s, out, @" ", style, NO, NO);
            continue;
        }
        if ([whitespace characterIsMember:c]) {  // Collapse runs to one space.
            while (s.index < s.input.length &&
                   [whitespace characterIsMember:[s.input characterAtIndex:s.index]])
                ++s.index;
            SPDFMathEmit(s, out, @" ", style, NO, NO);
            continue;
        }
        // Batch consecutive plain characters sharing one italic class:
        // single-letter variables set in math italic, digits and punctuation
        // upright.
        BOOL italic = SPDFMathIsLetter(c) && !style.upright;
        NSUInteger start = s.index;
        while (s.index < s.input.length) {
            unichar v = [s.input characterAtIndex:s.index];
            if (v == '}' || v == '{' || v == '\\' || v == '^' || v == '_' || v == '&' ||
                [whitespace characterIsMember:v])
                break;
            if ((SPDFMathIsLetter(v) && !style.upright) != italic) break;
            ++s.index;
        }
        SPDFMathEmit(s, out, [s.input substringWithRange:NSMakeRange(start, s.index - start)],
                     style, italic, NO);
    }
}

NSAttributedString* SPDFMarkdownMathTypeset(NSString* latex, NSFont* baseFont, NSFont* codeFont,
                                            NSColor* textColor) {
    MathScanner s;
    s.input = latex ?: @"";
    s.index = 0;
    s.baseFont = baseFont;
    s.codeFont = codeFont;
    s.color = textColor;
    MathStyle style = {baseFont.pointSize, 0, 0, NO, NO};
    NSMutableAttributedString* out = [NSMutableAttributedString new];
    while (s.index < s.input.length) {
        if (SPDFMathPeek(s) == '}') {  // Stray closer: skip it, never drop the rest.
            ++s.index;
            continue;
        }
        SPDFMathSequence(s, out, style);
    }
    return out;
}

void SPDFMarkdownRenderMathRun(SPDFMarkdownRenderContext* context, SPDFMarkdownInlineRun* run) {
    BOOL display = (run.traits & SPDFMarkdownInlineTraitDisplayMath) != 0;
    NSString* latex =
        [run.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSFont* baseFont = context.bodyFont;
    NSFont* codeFont = context.codeFont;
    if (display) {  // GitHub sets display math slightly larger than body text.
        NSFontManager* manager = NSFontManager.sharedFontManager;
        baseFont = [manager convertFont:baseFont toSize:baseFont.pointSize * 1.15] ?: baseFont;
        codeFont = [manager convertFont:codeFont toSize:codeFont.pointSize * 1.15] ?: codeFont;
    }
    NSAttributedString* math =
        SPDFMarkdownMathTypeset(latex, baseFont, codeFont, context.options.textColor);
    if (!display) {  // Inline math flows baseline-aligned within the paragraph.
        [context.output appendAttributedString:math];
        return;
    }
    // Display math renders centered on its own line: break out of any running
    // text, mark the range (trailing newline included, so the paragraph range
    // is derivable even for empty math), and let
    // SPDFMarkdownApplyMathBlockStyles re-derive the centered style after the
    // leaf renderer applies the block's base style.
    if (context.output.length && ![context.output.string hasSuffix:@"\n"])
        SPDFMarkdownAppend(context, @"\n", @{});
    NSUInteger start = context.output.length;
    [context.output appendAttributedString:math];
    SPDFMarkdownAppend(context, @"\n",
                       @{
                           NSFontAttributeName: baseFont,
                           NSForegroundColorAttributeName: context.options.textColor,
                       });
    [context.output addAttribute:SPDFMarkdownMathLayoutAttribute
                           value:@(SPDFMarkdownMathLayoutRoleDisplay)
                           range:NSMakeRange(start, context.output.length - start)];
}

void SPDFMarkdownApplyMathBlockStyles(SPDFMarkdownRenderContext* context, NSRange range,
                                      NSParagraphStyle* baseStyle) {
    CGFloat scale = SPDFMarkdownRenderScale(context);
    [context.output
        enumerateAttribute:SPDFMarkdownMathLayoutAttribute
                   inRange:range
                   options:0
                usingBlock:^(NSNumber* role, NSRange markedRange, BOOL* stop) {
                  (void)stop;
                  if (!role) return;
                  NSMutableParagraphStyle* style = [baseStyle mutableCopy];
                  style.alignment = NSTextAlignmentCenter;
                  style.paragraphSpacingBefore = MAX(baseStyle.paragraphSpacingBefore, 10 * scale);
                  style.paragraphSpacing = MAX(baseStyle.paragraphSpacing, 10 * scale);
                  NSRange paragraphRange = [context.output.string paragraphRangeForRange:markedRange];
                  [context.output addAttribute:NSParagraphStyleAttributeName
                                         value:style
                                         range:NSIntersectionRange(paragraphRange, range)];
                }];
}
