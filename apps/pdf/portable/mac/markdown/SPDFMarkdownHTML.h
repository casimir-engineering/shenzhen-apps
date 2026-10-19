#pragma once

#import "SPDFMarkdownParserInternal.h"

NS_ASSUME_NONNULL_BEGIN

// Native rendering of raw HTML islands in GitHub-style Markdown through a
// strict sanitizing whitelist (Gumbo-parsed, never evaluated — see the
// directory README). Raw tag text never reaches the canonical string: islands
// either translate into ordinary model blocks/runs or disappear entirely.

// Decodes one HTML entity string (`&amp;`, `&#65;`, `&#x41;`). Unknown named
// entities pass through unchanged. Used for md4c MD_TEXT_ENTITY callbacks;
// Gumbo decodes entities inside HTML islands itself.
NSString* SPDFMarkdownDecodeEntity(NSString* entity);

// Per-parse HTML state: the block-format container stack (a `<div
// align="center">` island pushes an alignment that applies to the markdown
// blocks that follow, until the island holding the matching close tag pops
// it), the inline overlay from open whitelisted inline tags, and the
// suppression state that swallows the visible content of dropped elements
// (`<script>…</script>` and friends).
@interface SPDFMarkdownHTMLState : NSObject
@property(nonatomic, readonly) SPDFMarkdownTableAlignment currentAlignment;
@property(nonatomic, readonly) BOOL suppressing;
@property(nonatomic, readonly) SPDFMarkdownInlineTraits overlayTraits;
@property(nonatomic, readonly, copy, nullable) NSString* overlayDestination;
@property(nonatomic, readonly, copy, nullable) NSString* overlayTitle;
// Clears inline tag frames and suppression at block boundaries so unbalanced
// inline tags can never leak styling (or swallow text) across blocks. The
// block-format container stack survives — that is its whole point.
- (void)resetInlineState;
@end

// Handles one MD_TEXT_HTML segment inside a normal (non-island) block: toggles
// overlay/suppression state and/or appends runs (an `<img>` image run, a
// `<br>` line break) to `block`, merging `baseTraits` in.
void SPDFMarkdownHTMLHandleInlineSegment(SPDFMarkdownHTMLState* state, NSString* segment,
                                         SPDFMarkdownBlockBuilder* block,
                                         SPDFMarkdownInlineTraits baseTraits);

// Processes one complete block-level HTML island: pushes/pops block-format
// contexts for container-only islands and returns the replacement builders
// (possibly empty) translated through the sanitizing whitelist. `nextIndex`
// and `nodeCount` are the parser's running block-index and node-budget
// counters; the caller re-checks its budget afterwards.
NSArray<SPDFMarkdownBlockBuilder*>* SPDFMarkdownHTMLProcessBlockIsland(
    SPDFMarkdownHTMLState* state, NSString* island, NSUInteger* nextIndex, NSUInteger* nodeCount);

NS_ASSUME_NONNULL_END
