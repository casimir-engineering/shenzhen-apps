#pragma once
#import <AppKit/AppKit.h>

// Dividers are flipped. Paint their full height, but leave the bottom window
// resize zone passive so native window resizing cannot compete with pane drag.
static inline NSRect SPDFPaneDividerResizeRect(NSRect bounds) {
    bounds.size.height = MAX(0, bounds.size.height - 6);
    return bounds;
}
