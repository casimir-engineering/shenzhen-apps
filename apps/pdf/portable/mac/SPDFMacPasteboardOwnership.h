#pragma once
#import <Cocoa/Cocoa.h>

// Whether the general pasteboard may still hold data this process promised (an NSImage's converted types, say): this
// process wrote it last and nothing wrote since. Only then must a quit go through AppKit's terminate, which resolves
// promises and waits about 300 ms in CFPasteboardResolveAllPromisedData even when nothing was promised. The reader's
// quit (SPDFMacQuitFinishing.mm) and the Collection companion's both exit at once otherwise.
BOOL spdf_mac_general_pasteboard_may_hold_our_data(void);
