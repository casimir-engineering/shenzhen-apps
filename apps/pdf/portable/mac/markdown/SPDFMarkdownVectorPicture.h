#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// Draws a vector picture -- an SVG the reader made into a one-page PDF
// (SPDFMarkdownResources.h), or a PDF -- into `destination` of `context`, from
// its page, so it is sharp at any zoom and prints and exports as vectors. The
// dark theme (`dark`) draws the copy the installed recolourer made.
//
// A picture whose page takes long to draw (tens of thousands of paths) is
// drawn on screen from a bitmap of the page made at the pixels the destination
// covers, made again when a zoom needs more; print and export always get the
// vectors.
//
// NO when `image` is not a vector picture, or (dark) when it has no recoloured
// copy; the caller then draws it as a bitmap.
FOUNDATION_EXPORT BOOL SPDFMarkdownDrawVectorPicture(NSImage* image, CGContextRef context, CGRect destination,
                                                     BOOL dark);

NS_ASSUME_NONNULL_END
