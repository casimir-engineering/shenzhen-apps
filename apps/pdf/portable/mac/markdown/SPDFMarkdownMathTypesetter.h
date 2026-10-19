#pragma once

#import "SPDFMarkdownRenderInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Native LaTeX-subset typesetter for Markdown math spans ($...$ and $$...$$).
// It maps the common README subset (Greek letters, operator/relation/arrow
// symbols, super/subscripts, \frac, \sqrt, \text and friends, spacing
// commands) onto a plain NSAttributedString: Unicode symbol substitution,
// smaller raised/lowered script runs, italic single-letter variables. There is
// no drawing layer, so whatever visible text it emits IS the canonical
// searchable text and print/export parity is automatic. Unknown commands
// degrade gracefully to the command name in the code font — never dropped,
// never a crash.

// Typesets one math span. `baseFont`/`codeFont` are already at the final
// (fontScale-adjusted) size; `display` math is typically passed a slightly
// larger base font by the caller.
NSAttributedString* SPDFMarkdownMathTypeset(NSString* latex, NSFont* baseFont, NSFont* codeFont,
                                            NSColor* textColor);

// Marks the characters of a display-math ($$...$$) paragraph so the leaf
// renderer can re-derive the centered paragraph style after applying the
// block's base style across its whole range (same pattern as
// SPDFMarkdownImageLayoutAttribute).
typedef NS_ENUM(NSInteger, SPDFMarkdownMathLayoutRole) {
    SPDFMarkdownMathLayoutRoleDisplay = 1,
};
FOUNDATION_EXPORT NSAttributedStringKey const SPDFMarkdownMathLayoutAttribute;

// Renders one math inline run into the render context: inline math flows
// baseline-aligned within its paragraph; display math renders on its own line,
// slightly larger, marked with SPDFMarkdownMathLayoutAttribute for centering.
void SPDFMarkdownRenderMathRun(SPDFMarkdownRenderContext* context, SPDFMarkdownInlineRun* run);

// Re-derives the centered display-math paragraph style (with a bit of vertical
// margin) after the leaf renderer applied the block's base style.
void SPDFMarkdownApplyMathBlockStyles(SPDFMarkdownRenderContext* context, NSRange range,
                                      NSParagraphStyle* baseStyle);

NS_ASSUME_NONNULL_END
