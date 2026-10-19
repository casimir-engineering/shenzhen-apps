#pragma once
#import <Cocoa/Cocoa.h>

// Reader/Collection chrome only. Opaque colors avoid stacking AppKit's disabled
// tint with another opacity reduction; document rendering never uses these.
static inline NSColor* SPDFChromeIconColor(BOOL enabled) {
    static NSColor* active; static NSColor* unavailable; static dispatch_once_t once;
    dispatch_once(&once, ^{
        active = [NSColor colorWithName:@"Reader.Icon" dynamicProvider:^NSColor*(NSAppearance* appearance) {
            BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
            unsigned hex = dark ? 0xeceef1 : 0x26282b;
            return [NSColor colorWithSRGBRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:1];
        }];
        unavailable = [NSColor colorWithName:@"Reader.UnavailableIcon" dynamicProvider:^NSColor*(NSAppearance* appearance) {
            BOOL dark = [[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqual:NSAppearanceNameDarkAqua];
            unsigned hex = dark ? 0x9298a2 : 0x7a808a;
            return [NSColor colorWithSRGBRed:((hex>>16)&255)/255. green:((hex>>8)&255)/255. blue:(hex&255)/255. alpha:1];
        }];
    });
    return enabled ? active : unavailable;
}
