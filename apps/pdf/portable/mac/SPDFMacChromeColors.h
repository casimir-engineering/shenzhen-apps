#pragma once
#import <Cocoa/Cocoa.h>
#import "SPDFMacCollectionStyle.h"

// Reader/Collection chrome only: the "icon" and "iconOff" tokens of the chrome palette (SPDFMacCollectionStyle.mm).
// Opaque colors avoid stacking AppKit's disabled tint with another opacity reduction; document rendering never uses
// these.
static inline NSColor* SPDFChromeIconColor(BOOL enabled) {
    return SPDFCollectionColor(enabled ? @"icon" : @"iconOff");
}
