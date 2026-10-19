#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Dark-theme recolor for the images a Markdown document embeds.
//
// A PDF page reaches the screen as one RGBA buffer and is recolored in the
// core's render tail, so its images ride along for free. A Markdown page is
// drawn natively by AppKit and never passes through that tail, so its images
// arrived at full brightness on dark paper -- a white screenshot glaring out of
// a #1E1E1E page. This applies the SAME luma remap (spdf_recolor.h) to an
// embedded image so the two readers agree.
//
// Screen only. Export and print build their plans as Light, so they never ask
// for this and a saved PDF keeps the document's own colors.
FOUNDATION_EXPORT CGImageRef SPDFMarkdownCreateDarkRecoloredImage(CGImageRef source) CF_RETURNS_RETAINED;

// The recolored twin of `attachment`'s image, created once and cached on the
// attachment itself so a scroll redraw never repeats the work. Returns NULL if
// the image cannot be recolored, in which case the caller draws the original.
FOUNDATION_EXPORT CGImageRef SPDFMarkdownDarkRecoloredImageForAttachment(NSTextAttachment* attachment,
                                                                        CGImageRef source);

NS_ASSUME_NONNULL_END
