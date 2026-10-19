#pragma once

// Shared internals of the HTML-island whitelist, split between
// SPDFMarkdownHTML.mm (state, inline segments, tag/attribute helpers) and
// SPDFMarkdownHTMLBlocks.mm (block-island classification and DOM translation).

#import "SPDFMarkdownHTML.h"

#include "../../../ext/gumbo-parser/src/gumbo.h"

NS_ASSUME_NONNULL_BEGIN

// Container-stack access for the block-island processor. `Default` alignment
// inherits the current alignment, so nested plain `<div>`s keep the center.
@interface SPDFMarkdownHTMLState (Containers)
- (void)pushContainerWithAlignment:(SPDFMarkdownTableAlignment)alignment;
- (void)popContainer;
@end

// The sanitizer's disposition for one element tag.
typedef NS_ENUM(NSInteger, SPDFMarkdownHTMLTagClass) {
    // Dropped together with all of its content: script, style, iframe, ...
    SPDFMarkdownHTMLTagClassDropWithContent,
    // Dropped void metadata tags with no content: link, meta, input, ...
    SPDFMarkdownHTMLTagClassDropVoid,
    // Whitelisted inline styling (b/strong, i/em, code, sub, sup, kbd, ...).
    SPDFMarkdownHTMLTagClassInlineTrait,
    SPDFMarkdownHTMLTagClassAnchor,
    SPDFMarkdownHTMLTagClassImage,
    SPDFMarkdownHTMLTagClassLineBreak,
    // Unknown-but-harmless: children pass through unstyled (span, font, ...).
    SPDFMarkdownHTMLTagClassPassThrough,
};

SPDFMarkdownHTMLTagClass SPDFMarkdownHTMLClassifyTag(NSString* lowercaseName);
SPDFMarkdownInlineTraits SPDFMarkdownHTMLTraitForTag(NSString* lowercaseName);

// Lowercase tag name of an element node, robust to GUMBO_TAG_UNKNOWN.
NSString* SPDFMarkdownHTMLElementName(const GumboElement* element);
// First element named `name` anywhere in the parsed fragment (Gumbo hoists
// metadata tags into <head>, so the search spans the whole document).
const GumboElement* _Nullable SPDFMarkdownHTMLFindElement(const GumboNode* _Nullable node,
                                                          NSString* name);
// Attribute value (nil when absent). Gumbo has already entity-decoded it.
NSString* _Nullable SPDFMarkdownHTMLAttribute(const GumboElement* element, const char* name);
// `align` attribute (plus the legacy `<center>` tag) mapped to an alignment;
// `inherited` when the element states none.
SPDFMarkdownTableAlignment SPDFMarkdownHTMLElementAlignment(const GumboElement* element,
                                                            NSString* name,
                                                            SPDFMarkdownTableAlignment inherited);
// href filtered to http/https/mailto/#anchor destinations; nil otherwise.
NSString* _Nullable SPDFMarkdownHTMLSanitizedLinkDestination(NSString* _Nullable href);
// Positive `width`/`height` pixel hint, 0 when absent or non-numeric.
CGFloat SPDFMarkdownHTMLDimension(NSString* _Nullable value);

// Appends an <img> element as an image run (alt text, src destination, title
// tooltip, width/height display hints) if it has a source.
void SPDFMarkdownHTMLAppendImageRun(SPDFMarkdownBlockBuilder* block, const GumboElement* element,
                                    SPDFMarkdownInlineTraits traits);

NS_ASSUME_NONNULL_END
